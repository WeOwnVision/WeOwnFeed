import hmac
import hashlib
from datetime import datetime, timezone
from dateutil import parser as date_parser
from fastapi import APIRouter, HTTPException, Header

from db import get_db
from schemas import ArticleCopyIn, ScrapedArticleIn
from story_copies import TITLE_RELATED, origin_of, same_story, title_similarity
from url_utils import canonicalize_url, extract_domain
from content_cleaner import clean_article_markdown
from image_extractor import is_valid_article_image, extract_og_image_from_url
from dedup import attach_also_published
from fact_check_status import attach_fact_check_verdicts
from routers.deps import INGESTION_SECRET, validate_uuid
from routers.users import get_personalized_feed_data

router = APIRouter(tags=["Articles & Ingestion"])


# A story that arrives within this window of a stored one it copies is listed
# on that story instead of being processed again (story_copies.py).
COPY_WINDOW_DAYS = 3


def _parse_pub_date(value):
    try:
        pub_date = date_parser.parse(value) if value else datetime.now(timezone.utc)
        if pub_date.tzinfo is None:
            pub_date = pub_date.replace(tzinfo=timezone.utc)
    except Exception:
        pub_date = datetime.now(timezone.utc)
    return min(pub_date, datetime.now(timezone.utc))


def _store_copies(cur, article_id, copies) -> int:
    stored = 0
    for c in copies:
        link = canonicalize_url(c.Link)
        if not link:
            continue
        cur.execute("""
            INSERT INTO article_mentions (article_id, source, title, url, published_at, origin)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (article_id, url) DO NOTHING;
        """, (article_id, c.Site or extract_domain(link), c.Baslik, link,
              _parse_pub_date(c.Tarih), c.Origin or extract_domain(link)))
        stored += cur.rowcount or 0
    return stored


def _stored_story_copied_by(cur, title: str, text: str, link: str):
    """Id of a recent stored story that this one copies, or None."""
    cur.execute("""
        SELECT id, title FROM articles
        WHERE duplicate_of IS NULL
          AND original_url <> %s
          AND created_at >= NOW() - (%s || ' days')::interval
          AND (macro_tag IS NULL OR macro_tag <> 'Off-Topic');
    """, (link, str(COPY_WINDOW_DAYS)))
    candidates = sorted(
        ((str(r[0]), r[1], title_similarity(title, r[1] or "")) for r in cur.fetchall()),
        key=lambda c: -c[2],
    )
    for cand_id, cand_title, sim in candidates[:3]:
        if sim < TITLE_RELATED:
            break
        cur.execute("SELECT LEFT(clean_text, 8000) FROM articles WHERE id = %s;", (cand_id,))
        row = cur.fetchone()
        if same_story(title, text, cand_title or "", (row[0] if row else "") or ""):
            return cand_id
    return None


@router.post("/api/internal/ingest")
def ingest_articles(items: list[ScrapedArticleIn], x_secret: str = Header(...)):
    """
    Stores fetched stories. Each may carry `Copies` (other outlets' versions
    of it, listed and never processed). A story that copies one stored in the
    last COPY_WINDOW_DAYS is added to that story's copies instead of becoming
    a new article. An item with empty TamMetin only adds its copies to the
    stored story at its Link.
    """
    if not hmac.compare_digest(x_secret.encode("utf-8"), INGESTION_SECRET.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Invalid ingestion secret")

    inserted = 0
    merged = 0
    with get_db() as cur:
        for item in items:
            canonical_link = canonicalize_url(item.Link)
            url_hash = hashlib.sha256(canonical_link.encode("utf-8")).hexdigest()

            if not item.TamMetin.strip():
                cur.execute("SELECT id FROM articles WHERE url_hash = %s;", (url_hash,))
                row = cur.fetchone()
                if row:
                    merged += _store_copies(cur, row[0], item.Copies)
                continue

            pub_date = _parse_pub_date(item.Tarih)
            cleaned_content = clean_article_markdown(item.Baslik, item.TamMetin)

            cur.execute("SELECT 1 FROM articles WHERE url_hash = %s;", (url_hash,))
            if not cur.fetchone():
                primary_id = _stored_story_copied_by(cur, item.Baslik, cleaned_content, canonical_link)
                if primary_id:
                    copy = ArticleCopyIn(
                        Site=item.Site, Baslik=item.Baslik, Link=canonical_link, Tarih=item.Tarih,
                        Origin=origin_of(cleaned_content, canonical_link),
                    )
                    merged += _store_copies(cur, primary_id, [copy, *item.Copies])
                    continue

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
            row = cur.fetchone()
            if row:
                inserted += 1
                merged += _store_copies(cur, row[0], item.Copies)

    return {"received": len(items), "inserted": inserted, "merged": merged}


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
                SELECT 
                    a.id, a.source_feed, a.title, a.original_url, a.author, a.published_at, 
                    a.macro_tag, a.macro_tags, a.micro_tags, a.tldr, a.image_url, a.image_status,
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
                  AND (a.macro_tag ILIKE %s OR EXISTS (
                      SELECT 1 FROM unnest(a.macro_tags) m WHERE m ILIKE %s
                  ))
                ORDER BY a.published_at DESC LIMIT %s OFFSET %s;
            """, (macro_clean, macro_clean, page_size, offset))
        else:
            cur.execute("""
                SELECT 
                    a.id, a.source_feed, a.title, a.original_url, a.author, a.published_at, 
                    a.macro_tag, a.macro_tags, a.micro_tags, a.tldr, a.image_url, a.image_status,
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
                  AND a.macro_tag IS NOT NULL 
                  AND a.macro_tag != 'Off-Topic'
                ORDER BY a.published_at DESC LIMIT %s OFFSET %s;
            """, (page_size, offset))
        rows = cur.fetchall()

    def _parse_also_published(val):
        if val is None:
            return []
        if isinstance(val, list):
            return val
        if isinstance(val, str):
            try:
                import json
                return json.loads(val)
            except Exception:
                return []
        return []

    return attach_also_published(attach_fact_check_verdicts([
        {
            "id": str(r[0]), "source": r[1], "title": r[2], "url": r[3],
            "author": r[4], "published_at": r[5], "macro_tag": r[6],
            "macro_tags": r[7] if r[7] else ([r[6]] if r[6] else []),
            "micro_tags": r[8], "tldr": r[9],
            "image_url": r[10],
            "image_status": r[11] or ("resolved" if r[10] else "gradient_fallback"),
            "also_published_by": _parse_also_published(r[12]) if len(r) > 12 else [],
            "also_published_by_count": int(r[13]) if len(r) > 13 and r[13] is not None else 0
        }
        for r in rows
    ]))


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

        return attach_also_published(attach_fact_check_verdicts([{
            "id": str(row[0]), "source": row[1], "title": row[2], "url": row[3],
            "author": row[4], "published_at": row[5], "clean_text": body_display,
            "macro_tag": row[8],
            "macro_tags": row[9] if row[9] else ([row[8]] if row[8] else []),
            "micro_tags": row[10], "tldr": tldr,
            "image_url": row[12],
            "image_status": row[13] or ("resolved" if row[12] else "gradient_fallback")
        }]))[0]

