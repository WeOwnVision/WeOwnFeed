"""
Backfill script to generate Executive Briefings ("Big TL;DR") for existing articles.

Extracts facts, numbers, dates, and significance using the enrichment LLM,
and stores the structured briefing into articles.executive_briefing and articles.clean_text.
"""

import sys
import argparse
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from db import get_db
from llm_enrichment import generate_briefing

sys.stdout.reconfigure(encoding="utf-8")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("backfill_briefings")


def process_row(row):
    aid, title, raw_text, clean_text, source = row
    text_to_use = raw_text or clean_text or ""
    if not text_to_use or len(text_to_use.strip()) < 100:
        return aid, None, "skipped_too_short"
    
    try:
        briefing = generate_briefing(title, text_to_use, source=source or "")
        return aid, briefing, "success"
    except Exception as e:
        logger.warning("Failed briefing for %s (%s): %s", aid, title[:30], e)
        return aid, None, "error"


def run_backfill(limit: int = 20, workers: int = 4):
    logger.info("Scanning for on-topic articles missing an executive briefing (limit=%s)...", limit)
    
    with get_db() as cur:
        query = """
            SELECT id, title, raw_scraped_text, clean_text, source_feed
            FROM articles
            WHERE is_processed = TRUE
              AND macro_tag IS NOT NULL
              AND macro_tag != 'Off-Topic'
              AND (executive_briefing IS NULL OR executive_briefing = '')
            ORDER BY published_at DESC
        """
        if limit and limit > 0:
            query += f" LIMIT {limit}"
        cur.execute(query)
        rows = cur.fetchall()

    total = len(rows)
    logger.info("Found %d articles to backfill with executive briefings.", total)
    if total == 0:
        logger.info("No articles require briefing backfill.")
        return

    success_count = 0
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(process_row, r): r for r in rows}
        for future in as_completed(futures):
            aid, briefing, status = future.result()
            if status == "success" and briefing:
                with get_db() as cur:
                    cur.execute("""
                        UPDATE articles 
                        SET executive_briefing = %s,
                            clean_text = %s
                        WHERE id = %s;
                    """, (briefing, briefing, aid))
                success_count += 1
                logger.info("[%d/%d] Briefing generated and saved for article %s", success_count, total, aid)

    logger.info("Backfill complete! Generated %d / %d briefings.", success_count, total)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Backfill executive briefings for articles.")
    parser.add_argument("--limit", type=int, default=20, help="Number of articles to backfill (default: 20, 0 for all)")
    parser.add_argument("--workers", type=int, default=4, help="Worker concurrency (default: 4)")
    args = parser.parse_args()
    
    limit_val = None if args.limit <= 0 else args.limit
    run_backfill(limit=limit_val, workers=args.workers)
