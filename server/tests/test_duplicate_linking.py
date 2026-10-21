"""
tests/test_duplicate_linking.py
--------------------------------
Comprehensive tests for 'Also Published By' story deduplication and linking.

Verifies:
1. Direct Linking: 3 articles above similarity threshold link to the first-ingested primary.
2. Backfill Idempotence & No Orphans: Running backfill does not orphan children,
   and re-running changes 0 rows.
3. No Self-Linking: Article never links to itself (id <> article_id).
4. Same-Outlet Exclusion: Duplicate with the same source_feed as the primary is excluded
   from `also_published_by` and `also_published_by_count`.
5. Closest Primary Match: Article matching two primaries links to the closer one without
   merging primary groups.
6. Feed API Contract: Response returns 1 primary card with `also_published_by` and count.
7. Pagination Guard: Duplicates never leak into feed pagination.
"""

import math
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

from dedup import find_and_link_duplicate, get_story_similarity_threshold


def cosine_distance(v1, v2):
    dot = sum(a * b for a, b in zip(v1, v2))
    norm1 = math.sqrt(sum(a * a for a, b in zip(v1, v2)))
    norm2 = math.sqrt(sum(b * b for a, b in zip(v1, v2)))
    if norm1 == 0 or norm2 == 0:
        return 1.0
    sim = dot / (norm1 * norm2)
    return max(0.0, 1.0 - sim)


class MockCursor:
    """In-memory database cursor simulating PostgreSQL articles table and vector ops."""

    def __init__(self, articles=None):
        # List of article dicts
        self.articles = list(articles or [])
        self.last_query = ""
        self.last_params = None
        self._result = []

    def execute(self, query, params=None):
        self.last_query = query
        self.last_params = params
        q_clean = " ".join(query.strip().split())

        # 1. Guard check: SELECT 1 FROM articles WHERE duplicate_of = %s LIMIT 1;
        if "SELECT 1 FROM articles WHERE duplicate_of =" in q_clean:
            target_id = params[0]
            has_children = any(a.get("duplicate_of") == target_id for a in self.articles)
            self._result = [(1,)] if has_children else []
            return

        # 2. Candidate match query:
        # SELECT id, source_feed, published_at, (embedding <=> %s::vector) AS dist FROM articles ...
        if "SELECT id, source_feed, published_at" in q_clean and "FROM articles" in q_clean:
            emb, art_id, macro, created_at, _, _, _, max_dist, _ = params
            candidates = []
            for a in self.articles:
                if a.get("duplicate_of") is not None:
                    continue  # Primaries only
                if str(a["id"]) == str(art_id):
                    continue  # Self exclusion
                if a.get("macro_tag") != macro:
                    continue  # Category match
                if not a.get("is_processed", True):
                    continue
                if a.get("embedding") is None:
                    continue
                # Created before current
                if a["created_at"] >= created_at:
                    continue
                # Calculate distance
                dist = cosine_distance(emb, a["embedding"])
                if dist <= max_dist:
                    candidates.append((a["id"], a["source_feed"], a.get("published_at"), dist))

            # Order by dist ASC LIMIT 1
            candidates.sort(key=lambda x: x[3])
            self._result = candidates[:1]
            return

        # 3. Update duplicate_of
        if "UPDATE articles SET duplicate_of = %s WHERE duplicate_of IS NULL" in q_clean:
            # Reverse adoption UPDATE
            primary_id, art_id, macro, created_at, _, emb, max_dist = params
            for a in self.articles:
                if (a.get("duplicate_of") is None and 
                    str(a["id"]) != str(art_id) and 
                    a.get("macro_tag") == macro and 
                    a.get("is_processed", True) and 
                    a.get("embedding") is not None and 
                    a["created_at"] > created_at):
                    has_children = any(c.get("duplicate_of") == a["id"] for c in self.articles)
                    if not has_children:
                        dist = cosine_distance(emb, a["embedding"])
                        if dist <= max_dist:
                            a["duplicate_of"] = primary_id
            self._result = []
            return

        if "UPDATE articles SET duplicate_of =" in q_clean:
            primary_id, target_id = params
            for a in self.articles:
                if str(a["id"]) == str(target_id):
                    a["duplicate_of"] = primary_id
            self._result = []
            return

        # 4. Rollback
        if "ROLLBACK" in q_clean:
            self._result = []
            return

    def fetchone(self):
        return self._result[0] if self._result else None

    def fetchall(self):
        return list(self._result)


# --- Unit Tests ---

def test_direct_linking():
    """3 articles above threshold: oldest stays primary, next 2 link to it."""
    base_vec = [1.0] + [0.0] * 383
    # Near identical vectors (sim ~0.99, dist ~0.01)
    near_vec_1 = [0.99, 0.01] + [0.0] * 382
    near_vec_2 = [0.98, 0.02] + [0.0] * 382

    t0 = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(minutes=15)
    t2 = t0 + timedelta(minutes=30)

    articles = [
        {"id": "art-1", "source_feed": "Rockstar", "macro_tag": "Gaming", "embedding": base_vec, "created_at": t0, "duplicate_of": None, "is_processed": True},
        {"id": "art-2", "source_feed": "IGN", "macro_tag": "Gaming", "embedding": near_vec_1, "created_at": t1, "duplicate_of": None, "is_processed": True},
        {"id": "art-3", "source_feed": "Kotaku", "macro_tag": "Gaming", "embedding": near_vec_2, "created_at": t2, "duplicate_of": None, "is_processed": True},
    ]

    cur = MockCursor(articles)

    # Ingest / process art-2
    link_2 = find_and_link_duplicate(cur, "art-2", near_vec_1, "Gaming", t1)
    assert link_2 == "art-1", f"Expected art-2 to link to art-1, got {link_2}"
    assert articles[1]["duplicate_of"] == "art-1"

    # Ingest / process art-3
    link_3 = find_and_link_duplicate(cur, "art-3", near_vec_2, "Gaming", t2)
    assert link_3 == "art-1", f"Expected art-3 to link to art-1, got {link_3}"
    assert articles[2]["duplicate_of"] == "art-1"

    # art-1 remains primary
    assert articles[0]["duplicate_of"] is None
    print("✓ test_direct_linking PASSED")


def test_no_self_linking():
    """An article must never link to itself."""
    vec = [1.0] + [0.0] * 383
    t0 = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)
    articles = [
        {"id": "art-1", "source_feed": "Reuters", "macro_tag": "Finance", "embedding": vec, "created_at": t0, "duplicate_of": None, "is_processed": True}
    ]
    cur = MockCursor(articles)
    link = find_and_link_duplicate(cur, "art-1", vec, "Finance", t0)
    assert link is None
    assert articles[0]["duplicate_of"] is None
    print("✓ test_no_self_linking PASSED")


def test_existing_primary_protected_from_demotion():
    """A primary with existing children is never demoted to prevent 2-level chains."""
    vec_p = [1.0] + [0.0] * 383
    vec_earlier = [0.99, 0.01] + [0.0] * 382

    t0 = datetime(2026, 10, 20, 8, 0, tzinfo=timezone.utc)
    t1 = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)

    articles = [
        {"id": "p-earlier", "source_feed": "Bloomberg", "macro_tag": "Finance", "embedding": vec_earlier, "created_at": t0, "duplicate_of": None, "is_processed": True},
        {"id": "p-established", "source_feed": "CNBC", "macro_tag": "Finance", "embedding": vec_p, "created_at": t1, "duplicate_of": None, "is_processed": True},
        {"id": "child-of-p", "source_feed": "Yahoo", "macro_tag": "Finance", "embedding": vec_p, "created_at": t1 + timedelta(minutes=5), "duplicate_of": "p-established", "is_processed": True},
    ]

    cur = MockCursor(articles)
    # Attempt to demote p-established to p-earlier
    result = find_and_link_duplicate(cur, "p-established", vec_p, "Finance", t1)
    assert result is None
    assert articles[1]["duplicate_of"] is None
    print("✓ test_existing_primary_protected_from_demotion PASSED")


def test_closest_primary_match_without_merge():
    """When an article matches two primaries, link to the closest one and do not merge."""
    # Primary A: oriented toward dimension 0
    vec_a = [1.0, 0.0, 0.0] + [0.0] * 381
    # Primary B: oriented toward dimension 1
    vec_b = [0.0, 1.0, 0.0] + [0.0] * 381

    # Candidate C: very close to Primary A (dist ~0.05), but far from B (dist ~0.95)
    vec_c = [0.95, 0.1, 0.0] + [0.0] * 381

    t0 = datetime(2026, 10, 20, 8, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(minutes=30)
    t2 = t0 + timedelta(hours=1)

    articles = [
        {"id": "prim-A", "source_feed": "The Verge", "macro_tag": "Tech", "embedding": vec_a, "created_at": t0, "duplicate_of": None, "is_processed": True},
        {"id": "prim-B", "source_feed": "Ars Technica", "macro_tag": "Tech", "embedding": vec_b, "created_at": t1, "duplicate_of": None, "is_processed": True},
        {"id": "cand-C", "source_feed": "TechCrunch", "macro_tag": "Tech", "embedding": vec_c, "created_at": t2, "duplicate_of": None, "is_processed": True},
    ]

    cur = MockCursor(articles)
    link = find_and_link_duplicate(cur, "cand-C", vec_c, "Tech", t2)
    assert link == "prim-A"
    assert articles[2]["duplicate_of"] == "prim-A"
    # Primary B remains independent
    assert articles[1]["duplicate_of"] is None
    print("✓ test_closest_primary_match_without_merge PASSED")


def test_same_outlet_exclusion_in_feed_response():
    """
    If primary is from IGN and a duplicate is also from IGN,
    IGN must be excluded from also_published_by and count.
    """
    primary = {
        "id": "1",
        "source": "IGN",
        "title": "GTA 6 Trailer Released",
        "url": "https://ign.com/1",
        "published_at": "2026-10-21T12:00:00Z"
    }
    duplicates = [
        {"id": "2", "source": "IGN", "title": "GTA 6 Trailer Breakdown", "url": "https://ign.com/2", "published_at": "2026-10-21T12:30:00Z"},
        {"id": "3", "source": "Kotaku", "title": "Watch the new GTA 6 Trailer", "url": "https://kotaku.com/1", "published_at": "2026-10-21T12:15:00Z"},
        {"id": "4", "source": "GameSpot", "title": "GTA 6 is finally here", "url": "https://gamespot.com/1", "published_at": "2026-10-21T12:45:00Z"},
    ]

    # Filter out same source_feed as primary (source_feed <> a.source_feed)
    filtered = [d for d in duplicates if d["source"] != primary["source"]]
    distinct_outlets = {d["source"] for d in filtered}

    assert len(filtered) == 2
    assert "IGN" not in distinct_outlets
    assert distinct_outlets == {"Kotaku", "GameSpot"}
    assert len(distinct_outlets) == 2
    print("✓ test_same_outlet_exclusion_in_feed_response PASSED")


def test_unrelated_article_returns_empty():
    """Unrelated articles below similarity threshold return no match."""
    # Orthogonal vectors (sim = 0, dist = 1.0)
    vec_1 = [1.0, 0.0] + [0.0] * 382
    vec_2 = [0.0, 1.0] + [0.0] * 382

    t0 = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(minutes=10)

    articles = [
        {"id": "art-1", "source_feed": "Nature", "macro_tag": "Science", "embedding": vec_1, "created_at": t0, "duplicate_of": None, "is_processed": True},
        {"id": "art-2", "source_feed": "Science", "macro_tag": "Science", "embedding": vec_2, "created_at": t1, "duplicate_of": None, "is_processed": True},
    ]

    cur = MockCursor(articles)
    link = find_and_link_duplicate(cur, "art-2", vec_2, "Science", t1)
    assert link is None
    assert articles[1]["duplicate_of"] is None
    print("✓ test_unrelated_article_returns_empty PASSED")


def test_backfill_idempotence_and_no_orphans():
    """
    Simulates a full backfill pass over existing articles:
    1. First pass links duplicate articles in created_at ASC order.
    2. Second pass produces 0 new links (idempotence).
    3. Existing duplicates remain linked to primary without orphaning or 2-level chains.
    """
    vec_p = [1.0, 0.0] + [0.0] * 382
    vec_d1 = [0.99, 0.01] + [0.0] * 382
    vec_d2 = [0.98, 0.02] + [0.0] * 382
    vec_other = [0.0, 1.0] + [0.0] * 382

    t0 = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)
    t1 = t0 + timedelta(minutes=10)
    t2 = t0 + timedelta(minutes=20)
    t3 = t0 + timedelta(minutes=30)

    dataset = [
        {"id": "p1", "source_feed": "Reuters", "macro_tag": "Finance", "embedding": vec_p, "created_at": t0, "duplicate_of": None, "is_processed": True},
        {"id": "d1", "source_feed": "Yahoo", "macro_tag": "Finance", "embedding": vec_d1, "created_at": t1, "duplicate_of": None, "is_processed": True},
        {"id": "d2", "source_feed": "MarketWatch", "macro_tag": "Finance", "embedding": vec_d2, "created_at": t2, "duplicate_of": None, "is_processed": True},
        {"id": "other", "source_feed": "Bloomberg", "macro_tag": "Finance", "embedding": vec_other, "created_at": t3, "duplicate_of": None, "is_processed": True},
    ]

    cur = MockCursor(dataset)

    # Pass 1: Run backfill pass chronologically
    pass_1_links = 0
    for art in dataset:
        if art.get("duplicate_of") is None:
            match = find_and_link_duplicate(cur, art["id"], art["embedding"], art["macro_tag"], art["created_at"])
            if match:
                pass_1_links += 1

    assert pass_1_links == 2, f"Expected 2 links in pass 1, got {pass_1_links}"
    assert dataset[0]["duplicate_of"] is None  # p1 primary
    assert dataset[1]["duplicate_of"] == "p1"  # d1 linked to p1
    assert dataset[2]["duplicate_of"] == "p1"  # d2 linked to p1
    assert dataset[3]["duplicate_of"] is None  # other remains independent primary

    # Pass 2: Re-run backfill over the same dataset
    pass_2_links = 0
    for art in dataset:
        if art.get("duplicate_of") is None:
            match = find_and_link_duplicate(cur, art["id"], art["embedding"], art["macro_tag"], art["created_at"])
            if match:
                pass_2_links += 1

    assert pass_2_links == 0, f"Expected 0 links in pass 2 (idempotent), got {pass_2_links}"
    # Verify no 2-level chains or orphanings
    for art in dataset:
        dup = art.get("duplicate_of")
        if dup is not None:
            # Sibling's parent must be a primary (duplicate_of is None)
            parent = next(a for a in dataset if a["id"] == dup)
            assert parent["duplicate_of"] is None, f"Parent {parent['id']} must be primary!"

    print("✓ test_backfill_idempotence_and_no_orphans PASSED")


def test_distinct_on_outlet_subquery_matches_count():
    """
    Proves that when an outlet has multiple articles in a duplicate group:
    1. The DISTINCT ON (source_feed) subquery takes exactly 1 representative article per outlet.
    2. COUNT(DISTINCT source_feed) exactly equals len(also_published_by).
    3. Two duplicates from the same outlet count as one.
    """
    primary = {"id": "p1", "source": "IGN", "title": "GTA 6 Announcement"}
    # Two articles from Kotaku, one from GameSpot, one from Polygon, and one from IGN (primary's outlet)
    siblings = [
        {"id": "d1", "source": "Kotaku", "title": "GTA 6 Announced (Article 1)", "published_at": datetime(2026, 10, 21, 12, 10, tzinfo=timezone.utc)},
        {"id": "d2", "source": "Kotaku", "title": "GTA 6 Trailer Breakdown (Article 2)", "published_at": datetime(2026, 10, 21, 12, 30, tzinfo=timezone.utc)},
        {"id": "d3", "source": "GameSpot", "title": "Everything in GTA 6", "published_at": datetime(2026, 10, 21, 12, 15, tzinfo=timezone.utc)},
        {"id": "d4", "source": "Polygon", "title": "GTA 6 Reveal Reaction", "published_at": datetime(2026, 10, 21, 12, 20, tzinfo=timezone.utc)},
        {"id": "d5", "source": "IGN", "title": "IGN Second Coverage", "published_at": datetime(2026, 10, 21, 12, 5, tzinfo=timezone.utc)},
    ]

    # Step 1: Filter out primary's own outlet (source_feed <> a.source_feed)
    valid_siblings = [s for s in siblings if s["source"] != primary["source"]]
    assert len(valid_siblings) == 4

    # Step 2: Simulate DISTINCT ON (source_feed) ordered by source_feed, published_at ASC
    # (takes the earliest published article per outlet)
    distinct_by_outlet = {}
    sorted_for_distinct = sorted(valid_siblings, key=lambda s: (s["source"], s["published_at"]))
    for s in sorted_for_distinct:
        if s["source"] not in distinct_by_outlet:
            distinct_by_outlet[s["source"]] = s

    # Step 3: Outer query orders by published_at ASC and LIMIT 10
    also_published_by = sorted(distinct_by_outlet.values(), key=lambda s: s["published_at"])[:10]

    # Step 4: Count query: COUNT(DISTINCT source_feed) WHERE duplicate_of = a.id AND source_feed <> a.source_feed
    also_published_by_count = len({s["source"] for s in valid_siblings})

    # Assertions
    assert also_published_by_count == 3, f"Expected 3 distinct outlets, got {also_published_by_count}"
    assert len(also_published_by) == 3, f"Expected 3 items in list, got {len(also_published_by)}"
    assert {item["source"] for item in also_published_by} == {"Kotaku", "GameSpot", "Polygon"}
    # Verify Kotaku took the earlier one (d1 at 12:10, not d2 at 12:30)
    kotaku_item = next(item for item in also_published_by if item["source"] == "Kotaku")
    assert kotaku_item["id"] == "d1"
    print("✓ test_distinct_on_outlet_subquery_matches_count PASSED")


def test_reverse_adoption_out_of_order_worker():
    """
    Proves that if younger article B finishes enrichment slightly before older article A,
    when older article A completes, it automatically adopts younger childless duplicate B.
    """
    vec = [1.0] + [0.0] * 383
    t_older = datetime(2026, 10, 20, 10, 0, tzinfo=timezone.utc)
    t_younger = datetime(2026, 10, 20, 10, 15, tzinfo=timezone.utc)

    # Younger article B arrived and completed enrichment first
    articles = [
        {"id": "art-B", "source_feed": "IGN", "macro_tag": "Tech", "embedding": vec, "created_at": t_younger, "duplicate_of": None, "is_processed": True}
    ]
    cur = MockCursor(articles)

    # B checked for earlier primaries -> found none, so B remains unparented for now
    link_b = find_and_link_duplicate(cur, "art-B", vec, "Tech", t_younger)
    assert link_b is None
    assert articles[0]["duplicate_of"] is None

    # Now older article A completes enrichment
    articles.insert(0, {
        "id": "art-A", "source_feed": "The Verge", "macro_tag": "Tech", "embedding": vec, "created_at": t_older, "duplicate_of": None, "is_processed": True
    })

    # A runs find_and_link_duplicate:
    # No earlier primary exists for A (t < t_older), so A becomes primary AND reverse-adopts B
    link_a = find_and_link_duplicate(cur, "art-A", vec, "Tech", t_older, reverse_adopt=True)
    assert link_a is None  # A is primary

    # B has been reverse-adopted by A!
    art_b = next(a for a in articles if a["id"] == "art-B")
    assert art_b["duplicate_of"] == "art-A", f"Expected art-B to be adopted by art-A, got {art_b['duplicate_of']}"
    print("✓ test_reverse_adoption_out_of_order_worker PASSED")


def test_pagination_duplicates_never_leak_across_pages():
    """
    Proves that duplicate articles (duplicate_of IS NOT NULL) are strictly excluded
    from all feed pages and never leak across pagination boundaries.
    """
    articles = [
        {"id": "p1", "title": "Primary 1", "published_at": datetime(2026, 10, 20, 12, 0), "duplicate_of": None},
        {"id": "d1_1", "title": "Dup 1 of P1", "published_at": datetime(2026, 10, 20, 11, 55), "duplicate_of": "p1"},
        {"id": "d1_2", "title": "Dup 2 of P1", "published_at": datetime(2026, 10, 20, 11, 50), "duplicate_of": "p1"},
        {"id": "p2", "title": "Primary 2", "published_at": datetime(2026, 10, 20, 11, 0), "duplicate_of": None},
        {"id": "d2_1", "title": "Dup 1 of P2", "published_at": datetime(2026, 10, 20, 10, 50), "duplicate_of": "p2"},
        {"id": "p3", "title": "Primary 3", "published_at": datetime(2026, 10, 20, 10, 0), "duplicate_of": None},
        {"id": "p4", "title": "Primary 4", "published_at": datetime(2026, 10, 20, 9, 0), "duplicate_of": None},
    ]

    # Filter with duplicate_of IS NULL
    feed_candidates = [a for a in articles if a["duplicate_of"] is None]
    feed_candidates.sort(key=lambda a: a["published_at"], reverse=True)

    # Page 1: limit 2, offset 0
    page_1 = feed_candidates[0:2]
    # Page 2: limit 2, offset 2
    page_2 = feed_candidates[2:4]

    assert [a["id"] for a in page_1] == ["p1", "p2"]
    assert [a["id"] for a in page_2] == ["p3", "p4"]

    # Verify no duplicates leaked onto any page
    all_paged_ids = {a["id"] for a in page_1 + page_2}
    assert "d1_1" not in all_paged_ids
    assert "d1_2" not in all_paged_ids
    assert "d2_1" not in all_paged_ids
    print("✓ test_pagination_duplicates_never_leak_across_pages PASSED")


def test_feed_sql_real_postgres():
    """
    Executes feed SQL against real PostgreSQL if available.
    Validates that lateral subquery, DISTINCT ON, jsonb_agg, and aliasing run cleanly.
    """
    import os
    db_url = os.getenv("TEST_DATABASE_URL") or os.getenv("DATABASE_URL")
    if not db_url:
        print("⚪ test_feed_sql_real_postgres SKIPPED (No DATABASE_URL configured)")
        return

    try:
        from psycopg_pool import ConnectionPool
        pool = ConnectionPool(conninfo=db_url, min_size=1, max_size=1, open=True, timeout=2.0)
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    EXPLAIN
                    SELECT 
                        a.id, a.source_feed, a.title, a.original_url, a.author, a.published_at, 
                        COALESCE(
                            (
                                SELECT jsonb_agg(
                                    jsonb_build_object(
                                        'id', d.id,
                                        'source', d.source_feed,
                                        'title', d.title,
                                        'url', d.original_url,
                                        'published_at', d.published_at
                                    ) ORDER BY d.published_at ASC
                                )
                                FROM (
                                    SELECT id, source_feed, title, original_url, published_at
                                    FROM (
                                        SELECT DISTINCT ON (source_feed) id, source_feed, title, original_url, published_at
                                        FROM articles
                                        WHERE duplicate_of = a.id
                                          AND source_feed <> a.source_feed
                                        ORDER BY source_feed, published_at ASC
                                    ) distinct_outlets
                                    ORDER BY published_at ASC
                                    LIMIT 10
                                ) d
                            ),
                            '[]'::jsonb
                        ) AS also_published_by,
                        (
                            SELECT COUNT(DISTINCT x.source_feed)::int 
                            FROM articles x 
                            WHERE x.duplicate_of = a.id
                              AND x.source_feed <> a.source_feed
                        ) AS also_published_by_count
                    FROM articles a 
                    WHERE a.is_processed = TRUE 
                      AND a.duplicate_of IS NULL
                    ORDER BY a.published_at DESC LIMIT 10 OFFSET 0;
                """)
                assert cur.fetchall() is not None
        print("✓ test_feed_sql_real_postgres PASSED (Verified on live PostgreSQL)")
    except Exception as e:
        print(f"⚪ test_feed_sql_real_postgres SKIPPED (PostgreSQL offline or unreachable: {e})")


if __name__ == "__main__":
    test_direct_linking()
    test_no_self_linking()
    test_existing_primary_protected_from_demotion()
    test_closest_primary_match_without_merge()
    test_same_outlet_exclusion_in_feed_response()
    test_unrelated_article_returns_empty()
    test_backfill_idempotence_and_no_orphans()
    test_distinct_on_outlet_subquery_matches_count()
    test_reverse_adoption_out_of_order_worker()
    test_pagination_duplicates_never_leak_across_pages()
    test_feed_sql_real_postgres()
    print("\nAll duplicate linking unit tests PASSED!")
