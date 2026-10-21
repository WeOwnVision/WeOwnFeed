"""
Offline tests for the "Latest developments" card writer (routers/latest.py): no network, no DB.

Run:  python tests/test_latest.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("AI_API_KEY", "test-key")

import routers.latest as latest


class FakeClient:
    """Replies from a script, one per call; records the model and messages of each call."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []
        self.chat = self
        self.completions = self

    def create(self, **kwargs):
        self.calls.append(kwargs)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        message = type("M", (), {"content": reply})
        return type("R", (), {"choices": [type("C", (), {"message": message})]})


def card(headline, paragraph="Something happened. Then more."):
    return json.dumps({"headline": headline, "paragraph": paragraph})


def _use(replies):
    fake = FakeClient(replies)
    latest.ai_client = fake
    return fake


def test_fit_headline():
    assert latest.fit_headline("Short one") == "Short one"
    long = "Banks block AI agents from moving money while stablecoin payment rails keep expanding fast"
    out = latest.fit_headline(long)
    assert len(out) <= latest.HEADLINE_MAX_CHARS and long.startswith(out) and not out.endswith(" ")
    print("✓ test_fit_headline PASSED")


def test_long_headline_is_sent_back_once():
    too_long = "x " * 50
    fake = _use([card(too_long), card("Banks curb AI agents as fintech funding triples")])
    result, model = latest.write_card("prompt")
    assert result["headline"] == "Banks curb AI agents as fintech funding triples"
    assert model == latest.LATEST_MODEL and len(fake.calls) == 2
    feedback = fake.calls[1]["messages"][-1]["content"]
    assert f"at most {latest.HEADLINE_MAX_CHARS} characters" in feedback
    # Still too long after the retry: cut at a word boundary instead of failing.
    _use([card("word " * 30), card("word " * 30)])
    result, _ = latest.write_card("prompt")
    assert len(result["headline"]) <= latest.HEADLINE_MAX_CHARS
    print("✓ test_long_headline_is_sent_back_once PASSED")


def test_falls_back_to_fast_model():
    fake = _use([TimeoutError("down"), "not json", card("Qwen wrote this")])
    result, model = latest.write_card("prompt")
    assert result["headline"] == "Qwen wrote this" and model == latest.FAST_MODEL
    assert [c["model"] for c in fake.calls] == [latest.LATEST_MODEL, latest.LATEST_MODEL, latest.FAST_MODEL]
    assert fake.calls[0]["extra_body"]["chat_template_kwargs"]["thinking"] is False
    _use([ValueError("a"), ValueError("b"), ValueError("c"), ValueError("d")])
    try:
        latest.write_card("prompt")
        raise AssertionError("expected failure")
    except ValueError:
        pass
    print("✓ test_falls_back_to_fast_model PASSED")


def test_prompt_and_keys():
    stories = [{"id": "a", "title": "Anthropic IPO", "source": "Bloomberg", "tldr": "Anthropic files."}]
    p = latest._prompt(["AI"], ["llm_agents"], "I invest", stories)
    assert "Reader topics: AI, llm agents" in p and "Why they read: I invest" in p
    assert "1. Anthropic IPO (Bloomberg): Anthropic files." in p
    assert "Why they read" not in latest._prompt(["AI"], [], None, stories)
    assert latest._key(["AI"], [], None) != latest._key(["AI"], [], "I invest")
    assert latest._key(["a", "b"]) == latest._key(["a", "b"])
    print("✓ test_prompt_and_keys PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   LATEST DEVELOPMENTS CARD TEST SUITE")
    print("=" * 65)
    test_fit_headline()
    test_long_headline_is_sent_back_once()
    test_falls_back_to_fast_model()
    test_prompt_and_keys()
    print("=" * 65)
    print("ALL 4 LATEST DEVELOPMENTS TESTS PASSED!")
    print("=" * 65)
