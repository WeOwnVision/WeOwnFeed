"""
Offline tests for the Nebius-only enrichment (llm_enrichment.py): no network, no DB.

Run:  python tests/test_llm_enrichment.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("AI_API_KEY", "test-key")

import llm_enrichment as le


class FakeClient:
    """Answers chat calls from a script: one reply (or exception) per call, in order."""

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
        choice = type("C", (), {"message": message})
        return type("R", (), {"choices": [choice]})


def _use(replies):
    fake = FakeClient(replies)
    le.ai_client = fake
    return fake


def test_normalize_labels():
    e = le.normalize_labels({
        "macro_tag": "Finance",
        "macro_tags": ["AI", "Finance", "Politics"],
        "micro_tags": ["fintech", "transistors", "llm_agents", "fintech", "not_a_tag"],
    })
    assert e.macro_tag == "Finance"
    assert e.macro_tags == ["Finance", "AI"]               # main first, unknown dropped
    assert e.micro_tags == ["fintech", "llm_agents"]       # Hardware's tag and unknown dropped
    try:
        le.normalize_labels({"macro_tag": "Politics", "macro_tags": [], "micro_tags": []})
        raise AssertionError("expected ValueError")
    except ValueError:
        pass
    print("✓ test_normalize_labels PASSED")


def test_summary_cleanup_and_shortening():
    assert le._clean_summary("Two  sentences here.\n (44 words)") == "Two sentences here."
    long = " ".join(["word"] * 60)
    fake = _use([long, "Short version of the story."])
    assert le.summarize("T", "body") == "Short version of the story."
    assert fake.calls[0]["model"] == le.SUMMARY_MODEL
    assert fake.calls[1]["model"] == le.FAST_MODEL         # Nano cannot shorten without thinking
    assert "60 words" in fake.calls[1]["messages"][0]["content"]
    # Short enough: no second call.
    fake = _use(["A short summary. Second sentence."])
    le.summarize("T", "body")
    assert len(fake.calls) == 1
    print("✓ test_summary_cleanup_and_shortening PASSED")


def test_topic_gate():
    _use(['{"on_topic": false, "reason": "job ad"}'])
    assert le.is_on_topic("Hiring", "body") is False
    _use([TimeoutError("down")])
    assert le.is_on_topic("Anything", "body") is True      # failure keeps the article
    fake = _use(["A company is hiring engineers.", '{"on_topic": false}'])
    assert le.enrich("Hiring", "body") is None              # off-topic: no label call
    assert len(fake.calls) == 2
    assert "Summary: A company is hiring engineers." in fake.calls[1]["messages"][1]["content"]
    print("✓ test_topic_gate PASSED")


def test_strip_site_chrome():
    menu = "\n".join(f"* [Section {i}](https://site.com/s{i})" for i in range(8))
    text = (f"{menu}\n\n![](https://cdn/logo.svg)\n\nWindows Central Insider\n\n"
            "Thermaltake went retro and embraced the beige case look\n\n"
            "Thermaltake announced a [beige case](https://x.com/case) on Friday.")
    out = le.strip_site_chrome("Thermaltake went retro and embraced the beige case look - Windows Central", text)
    assert out.startswith("Thermaltake went retro")
    assert "Section" not in out and "cdn/logo" not in out
    assert "a beige case on Friday" in out                  # links keep their text
    print("✓ test_strip_site_chrome PASSED")


def test_classify_retries_once():
    good = json.dumps({"macro_tag": "AI", "macro_tags": ["AI"], "micro_tags": ["llm_agents"]})
    fake = _use(["", good])
    assert le.classify("T", "S", "body").micro_tags == ["llm_agents"]
    assert len(fake.calls) == 2
    nano_call = fake.calls[0]
    assert nano_call["extra_body"] == {"chat_template_kwargs": {"enable_thinking": True}}
    assert nano_call["response_format"]["type"] == "json_schema"
    _use(["", ""])
    try:
        le.classify("T", "S", "body")
        raise AssertionError("expected failure after 2 attempts")
    except ValueError:
        pass
    print("✓ test_classify_retries_once PASSED")


def test_enrich_happy_path():
    labels = json.dumps({"macro_tag": "AI", "macro_tags": ["AI", "Finance"], "micro_tags": ["llm_agents", "markets"]})
    _use(["Anthropic raised money. Investors are keen.", '{"on_topic": true}', labels])
    e = le.enrich("Anthropic IPO", "body")
    assert e.tldr == "Anthropic raised money. Investors are keen."
    assert e.macro_tags == ["AI", "Finance"] and e.micro_tags == ["llm_agents", "markets"]
    print("✓ test_enrich_happy_path PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   NANO ENRICHMENT TEST SUITE")
    print("=" * 65)
    test_normalize_labels()
    test_summary_cleanup_and_shortening()
    test_topic_gate()
    test_strip_site_chrome()
    test_classify_retries_once()
    test_enrich_happy_path()
    print("=" * 65)
    print("ALL 6 NANO ENRICHMENT TESTS PASSED!")
    print("=" * 65)
