"""
Offline tests for Tavily key rotation and credit accounting (no network, no DB).

Run:  python tests/test_tavily_keys.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ["TAVILY_MOCK"] = "0"

from tavily import UsageLimitExceededError

import query_scheduler as qs
import tavily_service as ts


class FakeClient:
    def __init__(self, name, out_of_credits=False):
        self.name = name
        self.out_of_credits = out_of_credits
        self.calls = 0

    def search(self, **kwargs):
        self.calls += 1
        if self.out_of_credits:
            raise UsageLimitExceededError("This request exceeds your plan's set usage limit.")
        return {"results": [{"title": f"from {self.name}"}]}


def _use_keys(clients):
    """Point tavily_service at fake keys/clients and reset rotation state."""
    os.environ["TAVILY_API_KEYS"] = ",".join(clients)
    ts._exhausted_keys.clear()
    ts._active_key_id = None
    by_id = {ts.key_id(k): c for k, c in clients.items()}
    ts._client_for = lambda key: by_id[ts.key_id(key)]


def test_keys_from_env():
    os.environ["TAVILY_API_KEYS"] = " tvly-a , tvly-b,tvly-a, tvly-YOUR_KEY_HERE "
    assert ts.configured_keys() == ["tvly-a", "tvly-b"]
    os.environ.pop("TAVILY_API_KEYS")
    os.environ["TAVILY_API_KEY"] = "tvly-single"
    assert ts.configured_keys() == ["tvly-single"]
    assert len(ts.key_id("tvly-single")) == 10 and "tvly" not in ts.key_id("tvly-single")
    print("✓ test_keys_from_env PASSED")


def test_rotates_to_next_key_when_credits_run_out():
    first, second = FakeClient("first", out_of_credits=True), FakeClient("second")
    _use_keys({"tvly-first": first, "tvly-second": second})

    client = ts.get_tavily_client()
    res = client.search(query="fintech")
    assert res["results"][0]["title"] == "from second"
    assert ts.is_key_exhausted(ts.key_id("tvly-first"))
    assert ts.active_key_id() == ts.key_id("tvly-second")

    # The exhausted key is not tried again this month.
    client.search(query="crypto")
    assert first.calls == 1 and second.calls == 2
    print("✓ test_rotates_to_next_key_when_credits_run_out PASSED")


def test_no_client_when_every_key_is_exhausted():
    _use_keys({"tvly-x": FakeClient("x", out_of_credits=True)})
    client = ts.get_tavily_client()
    try:
        client.search(query="ai")
        raise AssertionError("expected RuntimeError")
    except RuntimeError:
        pass
    # Callers then get None and degrade gracefully (search_news returns []).
    assert ts.get_tavily_client() is None
    assert ts.search_news("anything", purpose="test") == []
    print("✓ test_no_client_when_every_key_is_exhausted PASSED")


def test_credit_estimate_and_total():
    # Tavily counter frozen at 146 while we logged 91 more -> 237 used.
    assert qs.estimate_used(146, 91.0) == 237
    assert qs.estimate_used(146, -5) == 146
    # Counter catches up only part of the way (146 -> 173) while our previous
    # estimate was 237 and we logged 3 more since: never go back down.
    assert qs.estimate_used(173, 0.0, previous_estimate=237, local_since_previous=3) == 240
    # Counter fully catches up and overtakes our estimate: trust it.
    assert qs.estimate_used(260, 0.0, previous_estimate=237, local_since_previous=3) == 260

    live = {"remaining": 763, "exhausted": False}
    dead = {"remaining": 0, "exhausted": True}
    unknown = {"remaining": None, "exhausted": False}
    assert qs.total_remaining([live]) == 763
    assert qs.total_remaining([dead, live]) == 763
    assert qs.total_remaining([dead]) == 0
    assert qs.total_remaining([unknown]) is None
    assert qs.total_remaining([unknown, live]) == 763     # unknown counts as 0
    print("✓ test_credit_estimate_and_total PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   TAVILY KEY ROTATION & CREDIT ACCOUNTING TEST SUITE")
    print("=" * 65)
    test_keys_from_env()
    test_rotates_to_next_key_when_credits_run_out()
    test_no_client_when_every_key_is_exhausted()
    test_credit_estimate_and_total()
    print("=" * 65)
    print("ALL 4 KEY & CREDIT TESTS PASSED!")
    print("=" * 65)
