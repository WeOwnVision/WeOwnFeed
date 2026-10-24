"""
dedup.py
--------
Core deduplication and linking engine for story grouping.
Identifies whether an incoming/backfilled article is a duplicate of an earlier
primary article and sets `duplicate_of = primary_id`.

Key Safeguards:
1. First-Ingested Primaries: Only matches against primaries ingested EARLIER
   (created_at < article.created_at and duplicate_of IS NULL).
2. Existing Primaries Protected: If an article already has children pointing to it,
   it is never demoted to a duplicate (preventing 2-level chains).
3. Self-Exclusion: p.id <> article_id.
4. Closest Primary Match: If multiple primaries exceed similarity threshold,
   links to the single closest primary and never merges primary groups.
5. Category Consistency: Enforces macro_tag = macro_tag.
6. Rolling Window: Limits search to `days` window (default 7 days).
"""

import logging
from datetime import datetime
from typing import Any, Dict, List, Optional
from embedder import similarity_thresholds

logger = logging.getLogger("dedup")


def attach_also_published(items: List[Dict[str, Any]], max_outlets: int = 10) -> List[Dict[str, Any]]:
    """
    Adds `also_published_by` (other outlets' copies, oldest first, one per
    outlet) and `also_published_by_count` to stories that lack them, in one
    query for the whole list. The feed and article list build these in SQL;
    Site Watch and search use this.
    """
    from db import get_db

    ids = [str(i["id"]) for i in items if i.get("id") and "also_published_by" not in i]
    if not ids:
        return items
    with get_db() as cur:
        cur.execute("""
            SELECT d.duplicate_of, d.id, d.source_feed, d.title, d.original_url, d.published_at
            FROM articles d
            WHERE d.duplicate_of = ANY(%s::uuid[])
            ORDER BY d.published_at ASC NULLS LAST;
        """, (ids,))
        rows = cur.fetchall()
    copies: Dict[str, List[Dict[str, Any]]] = {}
    for primary_id, cid, source, title, url, published_at in rows:
        copies.setdefault(str(primary_id), []).append({
            "id": str(cid), "source": source, "title": title,
            "url": url, "published_at": published_at,
        })
    for item in items:
        if "also_published_by" in item or not item.get("id"):
            continue
        outlets: Dict[str, Dict[str, Any]] = {}
        for c in copies.get(str(item["id"]), []):
            if c["source"] and c["source"] != item.get("source"):
                outlets.setdefault(c["source"], c)
        item["also_published_by"] = list(outlets.values())[:max_outlets]
        item["also_published_by_count"] = len(outlets)
    return items


def get_story_similarity_threshold() -> float:
    """Returns the same_story cosine similarity threshold for the configured backend."""
    return float(similarity_thresholds()["same_story"])


def find_and_link_duplicate(
    cur,
    article_id: str,
    embedding: Any,
    macro_tag: str,
    created_at: datetime,
    days: int = 7,
    reverse_adopt: bool = False
) -> Optional[str]:
    """
    Checks if article_id is a duplicate of an earlier primary.
    If a match is found, updates `articles.duplicate_of = primary_id` and returns primary_id.
    If no match is found, leaves `duplicate_of` unchanged (NULL) and returns None.

    Args:
        cur: Database cursor within an active transaction.
        article_id: UUID string of the article being evaluated.
        embedding: Vector embedding (list or pgvector format).
        macro_tag: Primary category tag (e.g. 'Tech', 'Finance').
        created_at: Ingestion timestamp of the article being evaluated.
        days: Rolling search window in days (default 7).

    Returns:
        UUID string of the matched primary article, or None if standalone.
    """
    if not article_id or embedding is None or not macro_tag or macro_tag == "Off-Topic":
        return None

    # Safeguard 1: If this article already has children pointing to it,
    # it is already an established primary and must never be demoted.
    cur.execute(
        "SELECT 1 FROM articles WHERE duplicate_of = %s LIMIT 1;",
        (article_id,)
    )
    if cur.fetchone():
        logger.debug("[Dedup] Article %s already has child duplicates; skipping demotion.", article_id)
        return None

    threshold = get_story_similarity_threshold()
    max_distance = round(1.0 - threshold, 4)

    # Safeguard 2 & 3 & 4:
    # - Only earlier-ingested primaries (created_at < current created_at and duplicate_of IS NULL)
    # - Never link to self (id <> article_id)
    # - Enforce macro_tag equality
    # - Closest primary only (ORDER BY distance ASC LIMIT 1) without merging clusters
    cur.execute("""
        SELECT id, source_feed, published_at, (embedding <=> %s::vector) AS dist
        FROM articles
        WHERE duplicate_of IS NULL
          AND id <> %s
          AND macro_tag = %s
          AND is_processed = TRUE
          AND embedding IS NOT NULL
          AND created_at < %s
          AND created_at >= (%s::timestamp with time zone - (%s || ' days')::interval)
          AND (embedding <=> %s::vector) <= %s
        ORDER BY (embedding <=> %s::vector) ASC
        LIMIT 1;
    """, (
        embedding,
        article_id,
        macro_tag,
        created_at,
        created_at,
        str(days),
        embedding,
        max_distance,
        embedding
    ))

    match = cur.fetchone()
    if match:
        primary_id = str(match[0])
        dist = float(match[3])
        sim = round(1.0 - dist, 4)
        cur.execute(
            "UPDATE articles SET duplicate_of = %s WHERE id = %s;",
            (primary_id, article_id)
        )
        logger.info(
            "[Dedup] Linked article %s to primary %s (similarity=%.3f, threshold=%.3f)",
            article_id, primary_id, sim, threshold
        )
        return primary_id

    # Reverse adoption: If article_id is a new primary, adopt any younger
    # childless unparented articles that finished slightly ahead due to concurrent worker jitter.
    if reverse_adopt:
        try:
            cur.execute("""
                UPDATE articles
                SET duplicate_of = %s
                WHERE duplicate_of IS NULL
                  AND id <> %s
                  AND macro_tag = %s
                  AND is_processed = TRUE
                  AND embedding IS NOT NULL
                  AND created_at > %s
                  AND created_at <= (%s::timestamp with time zone + interval '2 hours')
                  AND (embedding <=> %s::vector) <= %s
                  AND NOT EXISTS (
                      SELECT 1 FROM articles child WHERE child.duplicate_of = articles.id
                  );
            """, (
                article_id,
                article_id,
                macro_tag,
                created_at,
                created_at,
                embedding,
                max_distance
            ))
        except Exception as re:
            logger.debug("[Dedup] Reverse adoption check skipped: %s", re)

    return None
