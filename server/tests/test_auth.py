"""
Offline tests for accounts and route protection (no network, no DB):
password hashing, input rules, rate limits, bearer-token checks, and that every
user-scoped or credit-spending route requires sign-in.

Run:  python tests/test_auth.py   (or: pytest tests/test_auth.py)
"""
import os
import sys
from contextlib import contextmanager

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("INGESTION_SECRET", "test-secret")
os.environ.setdefault("AI_API_KEY", "test-key")
os.environ.setdefault("DATABASE_URL", "postgresql://test:test@127.0.0.1:1/test")

from fastapi import Depends, FastAPI, HTTPException
from fastapi.testclient import TestClient

import routers
import routers.auth as auth
import main  # noqa: F401  (the app must import with the guards in place)

# Routes straight from the routers main.py includes (newer FastAPI wraps
# included routers lazily, so app.routes does not list them).
ROUTES = [r for name in routers.__all__ for r in getattr(routers, name).routes]


def _raises(status_code, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except HTTPException as e:
        assert e.status_code == status_code, f"expected {status_code}, got {e.status_code}"
        return
    raise AssertionError(f"expected HTTP {status_code}")


def test_password_hash_roundtrip():
    """A stored hash verifies the right password only and never contains it."""
    stored = auth.hash_password("correct horse battery")
    assert stored.startswith("scrypt$") and "correct horse" not in stored
    assert auth.verify_password("correct horse battery", stored)
    assert not auth.verify_password("correct horse batterY", stored)
    assert auth.hash_password("same") != auth.hash_password("same"), "salt must differ"
    print("✓ test_password_hash_roundtrip PASSED")


def test_missing_or_broken_hash_never_verifies():
    """Old passwordless users (NULL) and garbage hashes cannot sign in."""
    for stored in (None, "", "plain-text", "md5$abc", "scrypt$1$2$3$!!$!!"):
        assert not auth.verify_password("anything", stored), stored
    print("✓ test_missing_or_broken_hash_never_verifies PASSED")


def test_username_and_password_rules():
    ok = auth.Credentials(username=" judge_01 ", password="12345678")
    assert auth._validate(ok) == ("judge_01", "12345678")
    for name, pw in (("ab", "12345678"), ("has space", "12345678"), ("x" * 33, "12345678"),
                     ("judge", "short"), ("judge", "x" * 129)):
        _raises(400, auth._validate, auth.Credentials(username=name, password=pw))
    print("✓ test_username_and_password_rules PASSED")


def test_rate_limit_window():
    """The (limit+1)-th call inside the window is refused with 429."""
    for _ in range(3):
        auth.rate_limit("user-a", "test_bucket", limit=3, window_seconds=60)
    _raises(429, auth.rate_limit, "user-a", "test_bucket", limit=3, window_seconds=60)
    auth.rate_limit("user-b", "test_bucket", limit=3, window_seconds=60)  # other users unaffected
    print("✓ test_rate_limit_window PASSED")


def test_ensure_self():
    uid = "0f8fad5b-d9cb-469f-a165-70867728950e"
    auth.ensure_self(uid.upper(), uid)
    auth.ensure_self("{" + uid + "}", uid)
    _raises(403, auth.ensure_self, "7c9e6679-7425-40de-944b-e07fc1f90ae7", uid)
    print("✓ test_ensure_self PASSED")


class _FakeCursor:
    """Answers the session lookup of optional_user from a dict of token hashes."""

    def __init__(self, sessions):
        self.sessions, self.row = sessions, None

    def execute(self, sql, params=()):
        self.row = (self.sessions[params[0]],) if params and params[0] in self.sessions else None

    def fetchone(self):
        return self.row


def test_bearer_token_checks():
    """No token -> 401, unknown/expired token -> 401, valid token -> the user id."""
    uid = "0f8fad5b-d9cb-469f-a165-70867728950e"
    sessions = {auth._token_hash("good-token"): uid}

    @contextmanager
    def fake_db():
        yield _FakeCursor(sessions)

    mini = FastAPI()

    @mini.get("/whoami")
    def whoami(me: str = Depends(auth.current_user)):
        return {"me": me}

    original, auth.get_db = auth.get_db, fake_db
    try:
        client = TestClient(mini)
        assert client.get("/whoami").status_code == 401
        assert client.get("/whoami", headers={"Authorization": "Bearer bad-token"}).status_code == 401
        assert client.get("/whoami", headers={"Authorization": "Basic good-token"}).status_code == 401
        r = client.get("/whoami", headers={"Authorization": "Bearer good-token"})
        assert r.status_code == 200 and r.json() == {"me": uid}
    finally:
        auth.get_db = original
    print("✓ test_bearer_token_checks PASSED")


def _route_dependencies(path, method):
    for route in ROUTES:
        if route.path == path and method in route.methods:
            seen, stack = set(), [route.dependant]
            while stack:
                dep = stack.pop()
                if dep.call is not None:
                    seen.add(dep.call)
                stack.extend(dep.dependencies)
            return seen
    raise AssertionError(f"route not found: {method} {path}")


SIGNED_IN = [
    ("GET", "/api/feed/personalized"),
    ("POST", "/api/articles/{article_id}/interactions"),
    ("PUT", "/api/users/{user_id}/preferences"),
    ("GET", "/api/users/{user_id}/preferences"),
    ("GET", "/api/users/{user_id}/sites"),
    ("POST", "/api/users/{user_id}/sites"),
    ("DELETE", "/api/users/{user_id}/sites/{site_id}"),
    ("GET", "/api/users/{user_id}/follows"),
    ("POST", "/api/users/{user_id}/follows"),
    ("DELETE", "/api/users/{user_id}/follows/{follow_id}"),
    ("GET", "/api/users/{user_id}/latest-developments"),
    ("POST", "/api/articles/{article_id}/comments"),
    ("POST", "/api/wai/open"),
    ("POST", "/api/wai/chat"),
    ("POST", "/api/articles/{article_id}/chat"),
    ("POST", "/api/articles/{article_id}/ask"),
    ("POST", "/api/articles/{article_id}/deep-inspect"),
    ("POST", "/api/articles/{article_id}/deep-inspect/research"),
    ("POST", "/api/intelligence/synthesize"),
    ("GET", "/api/intelligence/daily-digest"),
    ("POST", "/api/intelligence/verify-evidence"),
    ("GET", "/api/clusters/{cluster_id}/evidence"),
    ("GET", "/api/auth/me"),
]
OPERATOR_ONLY = [
    ("POST", "/api/tavily/site-watch"),
    ("POST", "/api/tavily/research"),
    ("GET", "/api/tavily/research/{request_id}"),
]


def test_routes_require_sign_in():
    """Every user-scoped or credit-spending route depends on current_user."""
    from routers.deps import require_ingestion_secret
    missing = [f"{m} {p}" for m, p in SIGNED_IN if auth.current_user not in _route_dependencies(p, m)]
    assert not missing, f"Routes without sign-in: {missing}"
    missing = [f"{m} {p}" for m, p in OPERATOR_ONLY if require_ingestion_secret not in _route_dependencies(p, m)]
    assert not missing, f"Operator routes without the secret: {missing}"
    print("✓ test_routes_require_sign_in PASSED")


def test_old_open_routes_are_gone():
    """The username-only login and the user list no longer exist."""
    paths = {(m, r.path) for r in ROUTES for m in r.methods}
    assert ("POST", "/api/users/login") not in paths
    assert ("GET", "/api/users") not in paths
    print("✓ test_old_open_routes_are_gone PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   ACCOUNTS & ROUTE PROTECTION TEST SUITE")
    print("=" * 65)
    test_password_hash_roundtrip()
    test_missing_or_broken_hash_never_verifies()
    test_username_and_password_rules()
    test_rate_limit_window()
    test_ensure_self()
    test_bearer_token_checks()
    test_routes_require_sign_in()
    test_old_open_routes_are_gone()
    print("=" * 65)
    print("ALL 8 AUTH TESTS PASSED!")
    print("=" * 65)
