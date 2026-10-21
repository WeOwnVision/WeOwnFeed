"""
Offline tests for the onboarding context sentence (no network, no DB).

Run:  python tests/test_interest_context.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("AI_API_KEY", "test-key")

from fastapi import HTTPException

import routers.users as users


def test_standard_sentence():
    assert users._standard_interest_text(["Finance", "AI"], []) == "Technical news and updates in Finance, AI."
    assert users._standard_interest_text(["AI"], ["llm_agents", "fintech"]) == (
        "Technical news and updates in AI, specifically focused on Llm Agents, Fintech."
    )
    print("✓ test_standard_sentence PASSED")


def test_clean_context():
    assert users._clean_context("  I   invest  ") == "I invest"
    assert users._clean_context("   ") is None
    assert users._clean_context("a" * users.INTEREST_CONTEXT_MAX_CHARS) is not None
    try:
        users._clean_context("a" * (users.INTEREST_CONTEXT_MAX_CHARS + 1))
        raise AssertionError("expected HTTPException")
    except HTTPException as e:
        assert e.status_code == 400
    print("✓ test_clean_context PASSED")


def test_translation_failure_falls_back():
    class Broken:
        class chat:
            class completions:
                @staticmethod
                def create(**kwargs):
                    raise TimeoutError("LLM down")

    real = users.ai_client
    users.ai_client = Broken()
    try:
        assert users._context_to_english("Yatırım yapıyorum") is None
    finally:
        users.ai_client = real
    print("✓ test_translation_failure_falls_back PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   INTEREST CONTEXT SENTENCE TEST SUITE")
    print("=" * 65)
    test_standard_sentence()
    test_clean_context()
    test_translation_failure_falls_back()
    print("=" * 65)
    print("ALL 3 INTEREST CONTEXT TESTS PASSED!")
    print("=" * 65)
