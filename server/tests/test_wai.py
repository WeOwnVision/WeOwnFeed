"""
Offline tests for the WAI assistant (routers/wai.py): no network, no DB.

Run:  python tests/test_wai.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("AI_API_KEY", "test-key")

from fastapi import HTTPException

import routers.wai as wai

USER = "11111111-1111-4111-8111-111111111111"
STORIES = [
    {"id": "a", "title": "Banks block AI agents", "source": "Bloomberg", "tldr": "Schwab and JPMorgan block agents."},
    {"id": "b", "title": "Fintech funding triples", "source": "Crowdfund", "tldr": "Funding hit $2.3B."},
]


class FakeClient:
    """Scripted replies: a string (full reply), a list of strings (streamed chunks) or an exception."""

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
        if kwargs.get("stream"):
            delta = lambda t: type("C", (), {"choices": [type("Ch", (), {"delta": type("D", (), {"content": t})})]})
            return iter([delta(t) for t in reply])
        message = type("M", (), {"content": reply})
        return type("R", (), {"choices": [type("C", (), {"message": message})]})


def _use(replies):
    fake = FakeClient(replies)
    wai.ai_client = fake
    return fake


def _fake_scope(mode="latest"):
    def build(scope, source_ids=None):
        return {"scope": "Scope line.", "material": wai._stories_material(STORIES), "stories": STORIES,
                "title": "Banks curb AI agents", "subtitle": "Your latest developments · 2 stories",
                "reader": "Reader's topics: Finance.", "citations": mode != "story", "area_label": "Fintech"}
    wai.build_scope = build


def test_resolve_area():
    assert wai.resolve_area("ai")[:2] == ("macro", "AI")
    kind, key, label = wai.resolve_area("fintech")
    assert (kind, key) == ("micro", "fintech") and label
    try:
        wai.resolve_area("Politics")
        raise AssertionError("expected 400")
    except HTTPException as e:
        assert e.status_code == 400
    print("✓ test_resolve_area PASSED")


def test_material_numbers_stories():
    text = wai._stories_material(STORIES, "Intro:\n")
    assert text.startswith("Intro:\n[1] Banks block AI agents (Bloomberg): Schwab")
    assert "\n[2] Fintech funding triples (Crowdfund): Funding hit $2.3B." in text
    print("✓ test_material_numbers_stories PASSED")


def test_opening_written_by_model_with_fallback():
    _fake_scope()
    fake = _use([TimeoutError("deepseek down"), "I've gone through your latest developments. Want a summary?"])
    out = wai.open_chat(wai.WaiScope(user_id=USER, mode="latest"), me=USER)
    assert out["opening"].startswith("I've gone through") and out["title"] == "Banks curb AI agents"
    assert [c["model"] for c in fake.calls] == [wai.WAI_MODEL, wai.FAST_MODEL]
    system, instruction = fake.calls[1]["messages"]
    assert "[1] Banks block AI agents" in system["content"] and "[2]" in system["content"]
    assert "square brackets" in system["content"]                     # citation rule in latest/area
    assert "summarize the most striking aspects" in instruction["content"]
    assert fake.calls[0]["extra_body"]["chat_template_kwargs"]["thinking"] is False
    print("✓ test_opening_written_by_model_with_fallback PASSED")


def test_empty_area_gets_a_fixed_opening():
    def build(scope, source_ids=None):
        return {"scope": "", "material": "", "stories": [], "title": "Exoplanets", "subtitle": "",
                "reader": "", "citations": True, "area_label": "Exoplanets"}
    wai.build_scope = build
    fake = _use([])
    out = wai.open_chat(wai.WaiScope(user_id=USER, mode="area", area="exoplanet"), me=USER)
    assert "couldn't find recent stories in Exoplanets" in out["opening"] and not fake.calls
    print("✓ test_empty_area_gets_a_fixed_opening PASSED")


def _sse(response):
    import asyncio

    async def collect():
        return [c if isinstance(c, str) else c.decode() async for c in response.body_iterator]

    events = [line[5:].strip() for chunk in asyncio.run(collect()) for line in chunk.split("\n") if line.startswith("data:")]
    return [e if e == "[DONE]" else json.loads(e) for e in events]


def test_chat_streams_with_history_and_fallback():
    _fake_scope()
    fake = _use([RuntimeError("deepseek down"), ["Here is ", "the summary [1]."]])
    req = wai.WaiChatRequest(user_id=USER, mode="latest", source_ids=["a", "b"], question=" Yes please. ",
                             history=[{"role": "assistant", "content": "Want a summary?"}] * 9)
    events = _sse(wai.chat(req, me=USER))
    assert "".join(e["token"] for e in events if isinstance(e, dict)) == "Here is the summary [1]."
    assert events[-1] == "[DONE]"
    msgs = fake.calls[1]["messages"]
    assert msgs[0]["role"] == "system" and msgs[-1] == {"role": "user", "content": "Yes please."}
    assert len(msgs) == 2 + wai.HISTORY_TURNS                         # history trimmed to the last turns
    _fake_scope()
    _use([RuntimeError("a"), RuntimeError("b")])
    events = _sse(wai.chat(req, me=USER))
    assert "error" in events[-1]
    print("✓ test_chat_streams_with_history_and_fallback PASSED")


def test_wai_prompt_rules():
    _fake_scope()
    fake = _use([["Tamam, ", "Türkçe özet [1]."]])
    req = wai.WaiChatRequest(user_id=USER, mode="latest", source_ids=["a", "b"], question="Translate this into Turkish",
                             history=[{"role": "assistant", "content": "I've gone through your latest developments."}])
    events = _sse(wai.chat(req, me=USER))
    sys_content = fake.calls[0]["messages"][0]["content"]
    assert "conversational continuity" in sys_content.lower()
    assert "translate" in sys_content.lower()
    assert "summaries" in sys_content.lower()
    assert "".join(e["token"] for e in events if isinstance(e, dict)) == "Tamam, Türkçe özet [1]."
    print("✓ test_wai_prompt_rules PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   WAI ASSISTANT TEST SUITE")
    print("=" * 65)
    test_resolve_area()
    test_material_numbers_stories()
    test_opening_written_by_model_with_fallback()
    test_empty_area_gets_a_fixed_opening()
    test_chat_streams_with_history_and_fallback()
    test_wai_prompt_rules()
    print("=" * 65)
    print("ALL 6 WAI TESTS PASSED!")
    print("=" * 65)

