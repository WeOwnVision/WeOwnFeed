"""Database migration and backfill script to replace blurry favicons with high-res article photos.

Queries all articles currently assigned a Google Favicon or missing an image,
and extracts real OpenGraph / Twitter Card editorial photos from the original publisher.
If no real image is found, safely clears the favicon to 'gradient_fallback'.
"""

import sys
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from db import get_db
from image_extractor import extract_og_image_from_url, is_valid_article_image

sys.stdout.reconfigure(encoding="utf-8")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("backfill_images")


def process_article(row):
    aid, title, url, old_img, old_status = row
    
    # Fast OG image extraction from original article URL
    real_img = extract_og_image_from_url(url, timeout=3.5)
    
    if real_img and is_valid_article_image(real_img):
        return aid, real_img, "resolved", True
    else:
        # Clear out any Google favicon or invalid image
        return aid, None, "gradient_fallback", False


def run_backfill(max_articles: int = None, workers: int = 12):
    logger.info("Scanning database for articles with favicons or missing images...")
    
    with get_db() as cur:
        query = """
            SELECT id, title, original_url, image_url, image_status
            FROM articles
            WHERE image_status = 'favicon'
               OR image_url LIKE '%google.com/s2/favicons%'
               OR image_url IS NULL
               OR image_status IS NULL
            ORDER BY created_at DESC
        """
        if max_articles:
            query += f" LIMIT {max_articles}"
        cur.execute(query)
        rows = cur.fetchall()

    total = len(rows)
    logger.info("Found %d articles requiring photo evaluation.", total)
    if total == 0:
        logger.info("No articles need backfilling.")
        return

    resolved_count = 0
    fallback_count = 0
    completed = 0

    updates = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(process_article, r): r for r in rows}
        for future in as_completed(futures):
            try:
                aid, new_img, new_status, is_resolved = future.result()
                updates.append((new_img, new_status, aid))
                if is_resolved:
                    resolved_count += 1
                else:
                    fallback_count += 1
            except Exception as e:
                logger.warning("Error processing article: %s", e)
            
            completed += 1
            if completed % 50 == 0 or completed == total:
                logger.info("Progress: %d/%d (%.1f%%) | Resolved photos: %d | Gradient fallbacks: %d",
                            completed, total, (completed / total) * 100, resolved_count, fallback_count)

    # Batch update database
    logger.info("Writing updates to PostgreSQL database...")
    with get_db() as cur:
        for new_img, new_status, aid in updates:
            cur.execute("""
                UPDATE articles
                SET image_url = %s, image_status = %s
                WHERE id = %s;
            """, (new_img, new_status, aid))

    logger.info("=" * 60)
    logger.info("BACKFILL COMPLETED SUCCESSFULLY")
    logger.info("Total articles processed: %d", total)
    logger.info("Successfully resolved real photos: %d (%.1f%%)", resolved_count, (resolved_count / total) * 100 if total else 0)
    logger.info("Clean gradient fallbacks (favicons eliminated): %d", fallback_count)
    logger.info("=" * 60)


if __name__ == "__main__":
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else None
    run_backfill(max_articles=limit)
