"""
Accounts: username + password, bearer session tokens, per-user rate limits.

  POST /api/auth/register  {username, password} -> {user, token}
  POST /api/auth/login     {username, password} -> {user, token}
  POST /api/auth/logout    revokes the token
  GET  /api/auth/me        the signed-in user

Passwords are stored as scrypt hashes (standard library, no extra package).
A token is a random string the app sends as `Authorization: Bearer <token>`;
only its SHA-256 is stored (user_sessions), so a leaked database row cannot be
used to sign in. Routes that read or change a user's data depend on
`current_user` and call `ensure_self`; routes that spend Tavily credits also
call `rate_limit`.
"""
import base64
import binascii
import hashlib
import hmac
import re
import secrets
import threading
import time
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
from typing import Deque, Dict, Optional, Tuple

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel, Field

from db import get_db

router = APIRouter(tags=["Auth"])

SESSION_DAYS = 30
USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")
PASSWORD_MIN = 8
PASSWORD_MAX = 128

# scrypt cost: ~16 MB and ~50 ms per hash.
_SCRYPT_N, _SCRYPT_R, _SCRYPT_P = 2 ** 14, 8, 1

AUTH_DDL = """
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT;
CREATE TABLE IF NOT EXISTS user_sessions (
    token_hash CHAR(64) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_user_sessions_user ON user_sessions (user_id);
"""


class Credentials(BaseModel):
    username: str = Field(..., description="3-32 characters: letters, digits, '_', '.', '-'")
    password: str = Field(..., description=f"{PASSWORD_MIN}-{PASSWORD_MAX} characters")


# --- passwords ---------------------------------------------------------------

def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P)
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, stored: Optional[str]) -> bool:
    """Constant-time check. A missing or malformed hash still costs one scrypt
    call, so response time does not reveal whether a username exists."""
    try:
        scheme, n, r, p, salt, digest = (stored or "").split("$")
        if scheme != "scrypt":
            raise ValueError(scheme)
        digest_b = base64.b64decode(digest, validate=True)
        candidate = hashlib.scrypt(password.encode("utf-8"), salt=base64.b64decode(salt, validate=True),
                                   n=int(n), r=int(r), p=int(p))
        return bool(digest_b) and hmac.compare_digest(candidate, digest_b)
    except (ValueError, binascii.Error, MemoryError):
        hashlib.scrypt(password.encode("utf-8"), salt=b"\0" * 16, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P)
        return False


def _validate(creds: Credentials) -> Tuple[str, str]:
    username = creds.username.strip()
    if not USERNAME_RE.match(username):
        raise HTTPException(400, "Username must be 3-32 characters: letters, digits, '_', '.' or '-'.")
    if not PASSWORD_MIN <= len(creds.password) <= PASSWORD_MAX:
        raise HTTPException(400, f"Password must be {PASSWORD_MIN}-{PASSWORD_MAX} characters.")
    return username, creds.password


# --- sessions ----------------------------------------------------------------

def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_session(cur, user_id: str) -> str:
    token = secrets.token_urlsafe(32)
    expires = datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)
    cur.execute("DELETE FROM user_sessions WHERE user_id = %s AND expires_at < NOW();", (user_id,))
    cur.execute("INSERT INTO user_sessions (token_hash, user_id, expires_at) VALUES (%s, %s, %s);",
                (_token_hash(token), user_id, expires))
    return token


def _bearer(authorization: Optional[str]) -> Optional[str]:
    if not authorization:
        return None
    scheme, _, token = authorization.partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def optional_user(authorization: Optional[str] = Header(default=None)) -> Optional[str]:
    """User id of a valid bearer token, or None when there is no token."""
    token = _bearer(authorization)
    if token is None:
        return None
    with get_db() as cur:
        cur.execute("SELECT user_id FROM user_sessions WHERE token_hash = %s AND expires_at > NOW();",
                    (_token_hash(token),))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session expired. Please sign in again.",
                            headers={"WWW-Authenticate": "Bearer"})
    return str(row[0])


def current_user(user_id: Optional[str] = Depends(optional_user)) -> str:
    """User id of the signed-in user; 401 without a valid token."""
    if user_id is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Sign in required.",
                            headers={"WWW-Authenticate": "Bearer"})
    return user_id


def ensure_self(requested_user_id: str, signed_in_user_id: str) -> None:
    """403 when a request names another user's id."""
    if str(requested_user_id).strip("{} \t\r\n\"'").lower() != signed_in_user_id.lower():
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You can only access your own account.")


# --- rate limits -------------------------------------------------------------

_hits: Dict[Tuple[str, str], Deque[float]] = defaultdict(deque)
_hits_lock = threading.Lock()


def rate_limit(key: str, bucket: str, limit: int, window_seconds: int) -> None:
    """Sliding-window limit kept in memory (the API runs as one process). 429 when exceeded."""
    now = time.monotonic()
    with _hits_lock:
        hits = _hits[(bucket, key)]
        while hits and now - hits[0] > window_seconds:
            hits.popleft()
        if len(hits) >= limit:
            retry = int(window_seconds - (now - hits[0])) + 1
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS,
                                f"Too many requests. Try again in {retry} s.",
                                headers={"Retry-After": str(retry)})
        hits.append(now)


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


# --- routes ------------------------------------------------------------------

def _signed_in(cur, user_id: str) -> dict:
    from routers.users import USER_COLUMNS, _user_out
    cur.execute(f"SELECT {USER_COLUMNS} FROM users WHERE id = %s;", (user_id,))
    return {"user": _user_out(cur.fetchone()), "token": create_session(cur, user_id)}


@router.post("/api/auth/register", status_code=status.HTTP_201_CREATED)
def register(creds: Credentials, request: Request):
    rate_limit(_client_ip(request), "register", limit=20, window_seconds=3600)
    username, password = _validate(creds)
    avatar = f"https://avatar.iran.liara.run/public/boy?username={username}"
    with get_db() as cur:
        cur.execute("""
            INSERT INTO users (username, avatar_url, onboarding_completed, password_hash)
            VALUES (%s, %s, FALSE, %s)
            ON CONFLICT (username) DO NOTHING
            RETURNING id;
        """, (username, avatar, hash_password(password)))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status.HTTP_409_CONFLICT, "This username is taken.")
        return _signed_in(cur, str(row[0]))


@router.post("/api/auth/login")
def login(creds: Credentials, request: Request):
    username = creds.username.strip()
    rate_limit(f"{_client_ip(request)}|{username.lower()}", "login", limit=10, window_seconds=900)
    with get_db() as cur:
        cur.execute("SELECT id, password_hash FROM users WHERE username = %s;", (username,))
        row = cur.fetchone()
        if not verify_password(creds.password, row[1] if row else None):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong username or password.")
        return _signed_in(cur, str(row[0]))


@router.post("/api/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(authorization: Optional[str] = Header(default=None)):
    token = _bearer(authorization)
    if token:
        with get_db() as cur:
            cur.execute("DELETE FROM user_sessions WHERE token_hash = %s;", (_token_hash(token),))


@router.get("/api/auth/me")
def me(user_id: str = Depends(current_user)):
    from routers.users import USER_COLUMNS, _user_out
    with get_db() as cur:
        cur.execute(f"SELECT {USER_COLUMNS} FROM users WHERE id = %s;", (user_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Sign in required.")
    return _user_out(row)
