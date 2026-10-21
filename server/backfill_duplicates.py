"""
backfill_duplicates.py
----------------------
CLI tool to retroactively cluster existing database articles by setting `duplicate_of`.

Guarantees & Safeguards:
1. Ingestion-Time Ordering: Processes articles in `created_at ASC` (oldest first).
2. Primary Stability: Calls `find_and_link_duplicate()`, which never demotes an existing
   primary with children and matches only earlier-ingested primaries.
3. Idempotent: Re-running multiple times produces identical, stable links.
4. Dry-run Mode (`--dry-run`): Inspects candidate matches and displays a summary table
   of proposed links and largest groups without persisting changes.

Usage:
  python backfill_duplicates.py --dry-run
  python backfill_duplicates.py --days 14
  python backfill_duplicates.py
"""

import argparse
import logging
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Dict, List

from db import get_db
from dedup import find_and_link_duplicate, get_story_similarity_threshold

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("backfill_duplicates")


def run_backfill(days: int = 7, dry_run: bool = False) -> Dict[str, Any]:
    threshold = get_story_similarity_threshold()
    logger.info(
        "Starting duplicate linking backfill (window=%d days, similarity_threshold=%.3f, dry_run=%s)",
        days, threshold, dry_run
    )

    with get_db() as cur:
        # Fetch candidate articles in chronological ingestion order
        cur.execute("""
            SELECT id, title, source_feed, macro_tag, embedding, created_at, duplicate_of
            FROM articles
            WHERE is_processed = TRUE
              AND embedding IS NOT NULL
              AND macro_tag IS NOT NULL
              AND macro_tag != 'Off-Topic'
              AND created_at >= NOW() - (%s || ' days')::interval
            ORDER BY created_at ASC;
        """, (str(days),))
        articles = cur.fetchall()

        total_inspected = len(articles)
        logger.info("Found %d processed articles within the last %d days.", total_inspected, days)

        newly_linked = 0
        already_linked = 0
        groups = defaultdict(list)  # primary_id -> list of duplicate article dicts
        primary_info = {}

        for row in articles:
            art_id = str(row[0])
            title = row[1]
            source = row[2]
            macro = row[3]
            embedding = row[4]
            created_at = row[5] or datetime.now(timezone.utc)
            existing_dup = str(row[6]) if row[6] else None

            if existing_dup:
                already_linked += 1
                groups[existing_dup].append({"id": art_id, "title": title, "source": source})
                continue

            primary_info[art_id] = {"title": title, "source": source}

            # Evaluate match against earlier-ingested primaries
            primary_match = find_and_link_duplicate(
                cur=cur,
                article_id=art_id,
                embedding=embedding,
                macro_tag=macro,
                created_at=created_at,
                days=days
            )

            if primary_match:
                newly_linked += 1
                groups[primary_match].append({"id": art_id, "title": title, "source": source})

        if dry_run:
            cur.execute("ROLLBACK;")
            logger.info("[Dry Run] Database transaction rolled back. No changes were committed.")

    # Sort groups by size descending
    top_groups = sorted(groups.items(), key=lambda kv: len(kv[1]), reverse=True)

    print("\n" + "=" * 70)
    print(f" DUPLICATE LINKING SUMMARY ({'DRY RUN' if dry_run else 'APPLIED'})")
    print("=" * 70)
    print(f"Total articles inspected:   {total_inspected}")
    print(f"Previously linked:          {already_linked}")
    print(f"Newly linked duplicates:    {newly_linked}")
    print(f"Total primary story groups: {len(groups)}")
    print("-" * 70)

    if top_groups:
        print("\nTop Story Coverage Clusters:")
        for rank, (p_id, dupes) in enumerate(top_groups[:5], start=1):
            p_meta = primary_info.get(p_id, {"title": f"Primary {p_id}", "source": "Unknown"})
            outlets = sorted({d["source"] for d in dupes if d["source"] != p_meta["source"]})
            print(f"\n[{rank}] Primary: \"{p_meta['title'][:65]}\" ({p_meta['source']})")
            print(f"    Duplicates: {len(dupes)} articles | Other Outlets: {', '.join(outlets) if outlets else 'Same outlet updates'}")
            for d in dupes[:3]:
                print(f"     -> [{d['source']}] {d['title'][:60]}")
    else:
        print("No multi-article clusters found within threshold in this time window.")
    print("=" * 70 + "\n")

    return {
        "total_inspected": total_inspected,
        "already_linked": already_linked,
        "newly_linked": newly_linked,
        "groups_count": len(groups)
    }


def main():
    parser = argparse.ArgumentParser(description="Link duplicate articles to primary stories.")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without modifying database.")
    parser.add_argument("--days", type=int, default=7, help="Rolling window in days (default: 7).")
    args = parser.parse_args()

    try:
        run_backfill(days=args.days, dry_run=args.dry_run)
    except Exception as e:
        logger.error("Backfill failed: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
