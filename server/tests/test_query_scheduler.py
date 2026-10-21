"""
Offline tests for the demand-driven ingestion schedule (no network, no DB).

Run:  python tests/test_query_scheduler.py
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("INGESTION_SECRET", "test-secret")

import query_scheduler as qs
from taxonomy import get_taxonomy_hierarchy
from ingest_tavily import _looks_like_article_url

CONFIG = qs.load_config()
TEMPLATES = qs.build_templates(CONFIG)
BACKOFF = CONFIG["backoff"]


def test_every_onboarding_subtopic_has_a_template():
    """Every category and subtopic a user can pick in onboarding can be fetched."""
    missing = []
    for cat in get_taxonomy_hierarchy():
        if f"cat:{cat['macro']}" not in TEMPLATES:
            missing.append(cat["macro"])
        for m in cat["micro_tags"]:
            if f"sub:{cat['macro']}:{m['tag']}" not in TEMPLATES:
                missing.append(f"{cat['macro']}:{m['tag']}")
    assert not missing, f"Missing templates: {missing}"
    print("✓ test_every_onboarding_subtopic_has_a_template PASSED")


def test_template_tags_are_unique():
    """A subtopic tag maps to exactly one query (demand lookup is by tag)."""
    tags = [t.tag for t in TEMPLATES.values() if t.tag]
    dupes = sorted({t for t in tags if tags.count(t) > 1})
    assert not dupes, f"Duplicate subtopic tags: {dupes}"
    print("✓ test_template_tags_are_unique PASSED")


def test_query_style_rules():
    """Rules from the 2026-10-18 A/B test: short plain terms, news topic, no recency words."""
    banned = re.compile(r"\b(latest|news|developments?|breaking|today|this week)\b", re.I)
    for t in TEMPLATES.values():
        assert t.topic == "news", f"{t.query_id}: topic must be 'news' (finance mode returns quote pages)"
        assert not banned.search(t.query), f"{t.query_id}: '{t.query}' contains a recency/filler word"
        assert 1 <= len(t.query.split()) <= 6, f"{t.query_id}: '{t.query}' should be 1-6 words"
    print("✓ test_query_style_rules PASSED")


def test_cadence_by_kind():
    """Category feeds run most often; specific subtopics least often."""
    hours = {k: CONFIG["cadence"][k]["interval_hours"] for k in ("category", "core", "specific")}
    assert hours["category"] < hours["core"] < hours["specific"]
    assert TEMPLATES["cat:Finance"].interval_hours == hours["category"]
    assert TEMPLATES["sub:Finance:fintech"].kind == "core"
    assert TEMPLATES["sub:Finance:ecb"].kind == "specific"
    assert TEMPLATES["sub:Finance:ecb"].time_range == "week"
    print("✓ test_cadence_by_kind PASSED")


def test_demand_only_followed_queries_run():
    """Nobody follows it -> no query. Counts followers per query."""
    assert qs.compute_demand(TEMPLATES, []) == {}

    demand = qs.compute_demand(TEMPLATES, [
        (["Finance"], ["fintech", "crypto"]),
        (["finance", "AI"], ["fintech", "web_services"]),   # lower-case macro, unknown LLM tag
        ([], ["nvidia"]),                                   # subtopic without its category
    ])
    assert demand == {
        "cat:Finance": 2,
        "sub:Finance:fintech": 2,
        "sub:Finance:crypto": 1,
        "cat:AI": 1,
        "sub:AI:nvidia": 1,
    }, demand
    print("✓ test_demand_only_followed_queries_run PASSED")


def test_low_yield_backoff():
    base = 24
    # Productive run: back to base cadence.
    assert qs.next_interval(base, 96, 1, inserted=5, backoff=BACKOFF) == (24, 0)
    # First low run: same interval, streak grows.
    assert qs.next_interval(base, 24, 0, inserted=0, backoff=BACKOFF) == (24, 1)
    # Second low run in a row: interval doubles.
    assert qs.next_interval(base, 24, 1, inserted=1, backoff=BACKOFF) == (48, 0)
    # Never beyond the cap (168 h = one week).
    assert qs.next_interval(base, 144, 1, inserted=0, backoff=BACKOFF) == (168, 0)
    print("✓ test_low_yield_backoff PASSED")


def test_credit_reserve():
    usage = {"account": {"plan_limit": 1000, "plan_usage": 846}}
    assert qs.credits_remaining_from_usage(usage) == 154
    assert qs.credits_remaining_from_usage({}) is None
    # 154 left, reserve 150 -> 4 credits -> 2 queries at 2 credits each.
    assert qs.affordable_count(154, 150, 2) == 2
    assert qs.affordable_count(120, 150, 2) == 0
    assert qs.affordable_count(None, 150, 2) is None
    print("✓ test_credit_reserve PASSED")


def test_due_order_category_first():
    def due(qid, followers):
        return qs.DueQuery(TEMPLATES[qid], followers, TEMPLATES[qid].interval_hours, 0)

    ordered = qs.order_due([
        due("sub:Finance:ecb", 5),
        due("sub:Finance:fintech", 1),
        due("cat:Finance", 1),
        due("sub:Finance:crypto", 3),
    ])
    assert [d.template.query_id for d in ordered] == [
        "cat:Finance", "sub:Finance:crypto", "sub:Finance:fintech", "sub:Finance:ecb"
    ]
    print("✓ test_due_order_category_first PASSED")


def test_follow_templates_are_shared():
    """'+' follows: one shared query per (name, category), category word adds context."""
    assert qs.normalize_follow("  Steam   Deck ") == "steam deck"
    templates, demand = qs.build_follow_templates(CONFIG, [
        ("revolut", "Finance", "Revolut", 2),      # two users follow Revolut
        ("openai", "AI", "OpenAI", 1),
        ("ghost", "Sports", "Ghost", 1),           # unknown category -> skipped
        ("nobody", "Tech", "Nobody", 0),           # no followers -> skipped
    ])
    assert set(templates) == {"follow:Finance:revolut", "follow:AI:openai"}
    revolut = templates["follow:Finance:revolut"]
    assert revolut.query == "Revolut finance"
    assert revolut.kind == "follow"
    assert revolut.interval_hours == CONFIG["cadence"]["follow"]["interval_hours"]
    assert revolut.time_range == "week"
    assert templates["follow:AI:openai"].query == "OpenAI AI"
    assert demand == {"follow:Finance:revolut": 2, "follow:AI:openai": 1}
    # Follows run after taxonomy queries.
    assert qs.KIND_PRIORITY["follow"] > qs.KIND_PRIORITY["specific"]
    print("✓ test_follow_templates_are_shared PASSED")


def test_article_url_heuristic():
    keep = [
        "https://thedriven.io/2026/10/17/smart-reveals-micro-ev-with-290-km-of-range",
        "https://www.crowdfundinsider.com/2026/10/southeast-asia-fintech-funding-triples",
        "https://techcrunch.com/intuit-to-acquire-sequence",
        "https://example.com/news/2026/10/ai-agents-hack-systems",
        # Real story with the id in the query string (dropped before the fix)
        "https://aero-news.net/index.cfm?do=main.textpost&id=48ABBD5B-BBD1-4054-B679-08A0DA69FFF6",
    ]
    drop = [
        "https://www.gameinformer.com/",
        "https://finance.yahoo.com/news",
        "https://finance.yahoo.com/quote/PKK.NE",
        "https://www.fintechfutures.com/jobs/director-business-development",
        "https://example.com/tag/fintech",
        "https://example.com/fintech",
        "https://example.com/tech/news",
        "https://uk.finance.yahoo.com/quote/LCLN",
        "https://ca.finance.yahoo.com/quote/ARKIE-USD/community",
    ]
    for u in keep:
        assert _looks_like_article_url(u), f"should keep: {u}"
    for u in drop:
        assert not _looks_like_article_url(u), f"should drop: {u}"
    print("✓ test_article_url_heuristic PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   DEMAND-DRIVEN INGESTION SCHEDULE TEST SUITE")
    print("=" * 65)
    test_every_onboarding_subtopic_has_a_template()
    test_template_tags_are_unique()
    test_query_style_rules()
    test_cadence_by_kind()
    test_demand_only_followed_queries_run()
    test_low_yield_backoff()
    test_credit_reserve()
    test_due_order_category_first()
    test_follow_templates_are_shared()
    test_article_url_heuristic()
    print("=" * 65)
    print("ALL 10 SCHEDULE TESTS PASSED!")
    print("=" * 65)
