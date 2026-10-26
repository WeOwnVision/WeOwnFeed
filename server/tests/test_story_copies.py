"""Copies of one story are recognized when fetched: only the best source is
processed, the others are listed with their origin (story_copies.py)."""

import ingest_tavily
import story_copies as sc
from evidence_verifier import assign_origins
from schemas import ScrapedArticleIn

WIRE_TEXT = (
    "SAN JOSE, Calif. (Reuters) - Nvidia said on Tuesday its next data center chip "
    "will ship in March, ahead of plan, as demand from cloud providers keeps rising. "
) * 6


def test_same_headline_with_site_suffix_is_one_story():
    assert sc.same_story(
        "Nvidia says next data center chip will ship in March - Reuters", "",
        "Nvidia says next data center chip will ship in March | Yahoo Finance", "",
    )


def test_different_stories_do_not_match():
    assert not sc.same_story(
        "Nvidia says next data center chip will ship in March", "",
        "AMD cuts prices of its gaming graphics cards in Europe", "",
    )


def test_short_generic_headlines_need_the_text():
    assert not sc.same_story("Related stories", "", "Related stories", "")
    assert sc.same_story("Nvidia chip news", WIRE_TEXT, "Nvidia chip update", WIRE_TEXT)


def test_reprinted_text_matches_even_with_new_headline():
    assert sc.same_story("Chip maker moves launch forward", WIRE_TEXT,
                         "Why Nvidia's March ship date matters", WIRE_TEXT)


def test_best_copy_is_the_most_authoritative_then_the_first():
    items = [
        {"title": "Nvidia says next data center chip will ship in March", "url": "https://someblog.net/a"},
        {"title": "Nvidia says next data center chip will ship in March", "url": "https://www.reuters.com/a"},
        {"title": "AMD cuts prices of its gaming graphics cards in Europe", "url": "https://alpha-news.com/b"},
        {"title": "AMD cuts prices of its gaming graphics cards in Europe", "url": "https://beta-news.com/b"},
    ]
    assert sc.group_copies(items) == [[1, 0], [2, 3]]


def test_origin_is_the_wire_in_the_byline_else_the_outlet():
    assert sc.origin_of(WIRE_TEXT, "https://finance.yahoo.com/a") == "Reuters"
    assert sc.origin_of("Our reporter visited the plant.", "https://www.techcrunch.com/a") == "techcrunch.com"


def test_fact_check_counts_listed_copies_by_their_origin():
    docs = [
        {"title": "Primary", "text": WIRE_TEXT, "url": "https://reuters.com/a"},
        {"title": "Copy", "text": "", "url": "https://yahoo.com/a", "origin": "Reuters"},
        {"title": "Copy", "text": "", "url": "https://marketwatch.com/a", "origin": "Reuters"},
        {"title": "Own", "text": "", "url": "https://techcrunch.com/a", "origin": "techcrunch.com"},
    ]
    res = assign_origins(docs)
    assert res["total_sources"] == 4
    assert res["independent_origins_count"] == 2


def test_old_ingest_payload_still_parses():
    item = ScrapedArticleIn(Site="cnbc.com", Baslik="T", Link="https://cnbc.com/a", TamMetin="body")
    assert item.Copies == []


def test_harvest_sends_one_story_with_its_copies(monkeypatch):
    title = "Nvidia says next data center chip will ship in March"
    results = [
        {"url": "https://someblog.net/2026/10/nvidia-march-chip", "title": f"{title} - Some Blog",
         "raw_content": WIRE_TEXT, "published_date": "2026-10-24T08:00:00Z"},
        {"url": "https://www.reuters.com/technology/nvidia-march-chip-2026-10-24", "title": f"{title} - Reuters",
         "raw_content": WIRE_TEXT, "published_date": "2026-10-24T07:00:00Z"},
        {"url": "https://www.cnbc.com/2026/10/24/amd-gpu-prices.html", "title": "AMD cuts prices of its gaming graphics cards in Europe",
         "raw_content": "AMD lowered prices across its Radeon line in Europe this week. " * 8,
         "published_date": "2026-10-24T06:00:00Z"},
    ]
    sent = {}

    class _Resp:
        status_code = 200

        def json(self):
            return {"inserted": len(sent["payload"])}

    def fake_post(url, json, headers, timeout):
        sent["payload"] = json
        return _Resp()

    monkeypatch.setattr(ingest_tavily, "search_news", lambda **_: results)
    monkeypatch.setattr(ingest_tavily, "resolve_article_image", lambda **_: (None, "gradient_fallback"))
    monkeypatch.setattr(ingest_tavily, "_parse_and_validate_date", lambda d: d)
    monkeypatch.setattr(ingest_tavily.requests, "post", fake_post)

    fetched, inserted, abort = ingest_tavily._harvest_query(
        "nvidia", "news", 5, "day", "test", ingest_tavily.HarvestDedup(), "secret")

    payload = sent["payload"]
    assert (fetched, inserted, abort) == (3, 2, False)
    assert [p["Site"] for p in payload] == ["reuters.com", "cnbc.com"]
    copies = payload[0]["Copies"]
    assert [(c["Site"], c["Origin"]) for c in copies] == [("someblog.net", "Reuters")]
    assert "TamMetin" not in copies[0]
    assert payload[1]["Copies"] == []


class _QueueCursor:
    def __init__(self, results):
        self.results = list(results)
        self.current = []

    def execute(self, *_):
        self.current = self.results.pop(0)

    def fetchall(self):
        return self.current

    def fetchone(self):
        return self.current[0] if self.current else None


def test_copy_of_a_stored_story_is_found():
    from routers.articles import _stored_story_copied_by
    cur = _QueueCursor([
        [("a1", "AMD cuts prices of its gaming graphics cards in Europe"),
         ("a2", "Nvidia says next data center chip will ship in March")],
        [(WIRE_TEXT,)],
    ])
    found = _stored_story_copied_by(
        cur, "Nvidia says next data center chip will ship in March - Yahoo", WIRE_TEXT, "https://yahoo.com/x")
    assert found == "a2"


def test_unrelated_story_is_not_a_copy():
    from routers.articles import _stored_story_copied_by
    cur = _QueueCursor([[("a1", "AMD cuts prices of its gaming graphics cards in Europe")]])
    assert _stored_story_copied_by(cur, "Tesla opens a new factory in Texas", "Text.", "https://x.org/y") is None
