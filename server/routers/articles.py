import hmac
import hashlib
from datetime import datetime, timezone
from dateutil import parser as date_parser
from fastapi import APIRouter, HTTPException, Header

from db import get_db
from schemas import ScrapedArticleIn
from url_utils import canonicalize_url, extract_domain
from content_cleaner import clean_article_markdown
from image_extractor import is_valid_article_image, extract_og_image_from_url
from routers.deps import INGESTION_SECRET, validate_uuid
from routers.users import get_personalized_feed_data

router = APIRouter(tags=["Articles & Ingestion"])


@router.post("/api/internal/ingest")
def ingest_articles(items: list[ScrapedArticleIn], x_secret: str = Header(...)):
    if not hmac.compare_digest(x_secret.encode("utf-8"), INGESTION_SECRET.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Invalid ingestion secret")

    inserted = 0
    with get_db() as cur:
        for item in items:
            canonical_link = canonicalize_url(item.Link)
            url_hash = hashlib.sha256(canonical_link.encode("utf-8")).hexdigest()
            try:
                pub_date = date_parser.parse(item.Tarih) if item.Tarih else datetime.now(timezone.utc)
                if pub_date.tzinfo is None:
                    pub_date = pub_date.replace(tzinfo=timezone.utc)
            except Exception:
                pub_date = datetime.now(timezone.utc)

            cleaned_content = clean_article_markdown(item.Baslik, item.TamMetin)
            
            # Resolve real article photo: validate candidate or fallback to fast OG extraction
            img_url = item.image_url or item.Resim
            if img_url and is_valid_article_image(img_url):
                img_status = "resolved"
            else:
                og_candidate = extract_og_image_from_url(canonical_link, timeout=2.5)
                if og_candidate:
                    img_url = og_candidate
                    img_status = "resolved"
                else:
                    img_url = None
                    img_status = "gradient_fallback"

            cur.execute("""
                INSERT INTO articles (url_hash, source_feed, title, original_url, author, published_at, clean_text, raw_scraped_text, image_url, image_status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (url_hash) DO UPDATE SET
                    image_url = COALESCE(EXCLUDED.image_url, articles.image_url),
                    image_status = COALESCE(EXCLUDED.image_status, articles.image_status),
                    raw_scraped_text = COALESCE(articles.raw_scraped_text, EXCLUDED.raw_scraped_text)
                RETURNING id;
            """, (url_hash, item.Site, item.Baslik, canonical_link, item.Yazar, pub_date, cleaned_content, cleaned_content, img_url, img_status))
            if cur.fetchone():
                inserted += 1

    return {"received": len(items), "inserted": inserted}


# Static route declared BEFORE dynamic /api/articles/{article_id}
@router.get("/api/articles")
def get_articles(
    page: int = 1, 
    page_size: int = 20, 
    macro: str | None = None,
    user_id: str | None = None
):
    if user_id:
        pdata = get_personalized_feed_data(user_id=user_id, page=page, page_size=page_size)
        return pdata["articles"]

    offset = (page - 1) * page_size
    with get_db() as cur:
        if macro:
            macro_clean = macro.strip()
            cur.execute("""
                SELECT id, source_feed, title, original_url, author, published_at, macro_tag, macro_tags, micro_tags, tldr, image_url, image_status
                FROM articles WHERE is_processed = TRUE 
                  AND (macro_tag ILIKE %s OR EXISTS (
                      SELECT 1 FROM unnest(macro_tags) m WHERE m ILIKE %s
                  ))
                ORDER BY published_at DESC LIMIT %s OFFSET %s;
            """, (macro_clean, macro_clean, page_size, offset))
        else:
            cur.execute("""
                SELECT id, source_feed, title, original_url, author, published_at, macro_tag, macro_tags, micro_tags, tldr, image_url, image_status
                FROM articles 
                WHERE is_processed = TRUE 
                  AND macro_tag IS NOT NULL 
                  AND macro_tag != 'Off-Topic'
                ORDER BY published_at DESC LIMIT %s OFFSET %s;
            """, (page_size, offset))
        rows = cur.fetchall()

    return [
        {
            "id": str(r[0]), "source": r[1], "title": r[2], "url": r[3],
            "author": r[4], "published_at": r[5], "macro_tag": r[6],
            "macro_tags": r[7] if r[7] else ([r[6]] if r[6] else []),
            "micro_tags": r[8], "tldr": r[9],
            "image_url": r[10],
            "image_status": r[11] or ("resolved" if r[10] else "gradient_fallback")
        }
        for r in rows
    ]


@router.get("/api/articles/{article_id}")
def get_article(article_id: str):
    valid_id = validate_uuid(article_id, "article_id")
    with get_db() as cur:
        cur.execute("""
            SELECT id, source_feed, title, original_url, author, published_at, 
                   executive_briefing, COALESCE(raw_scraped_text, clean_text), 
                   macro_tag, macro_tags, micro_tags, tldr, image_url, image_status
            FROM articles WHERE id = %s;
        """, (valid_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Article not found")

        source = row[1]
        title = row[2]
        briefing = row[6]
        raw_clean = row[7]
        tldr = row[11]

        # 1. Use existing executive briefing if available
        if briefing and briefing.strip():
            body_display = briefing.strip()
        else:
            # 2. Generate on-the-fly so the body is a REAL Big TL;DR and never duplicates the 2-sentence summary
            text_for_briefing = raw_clean or ""
            if text_for_briefing and len(text_for_briefing.strip()) >= 80:
                try:
                    from llm_enrichment import generate_briefing
                    gen_briefing = generate_briefing(title, text_for_briefing, source=source or "")
                    if gen_briefing and gen_briefing.strip():
                        body_display = gen_briefing.strip()
                        # Persist to DB so subsequent requests are instant
                        try:
                            cur.execute(
                                "UPDATE articles SET executive_briefing = %s, clean_text = %s WHERE id = %s;",
                                (body_display, body_display, valid_id)
                            )
                        except Exception:
                            pass
                    else:
                        body_display = raw_clean
                except Exception as ex:
                    body_display = raw_clean
            else:
                body_display = raw_clean

        return {
            "id": str(row[0]), "source": row[1], "title": row[2], "url": row[3],
            "author": row[4], "published_at": row[5], "clean_text": body_display,
            "macro_tag": row[8],
            "macro_tags": row[9] if row[9] else ([row[8]] if row[8] else []),
            "micro_tags": row[10], "tldr": tldr,
            "image_url": row[12],
            "image_status": row[13] or ("resolved" if row[12] else "gradient_fallback")
        }

