import os
import re
import hashlib
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional
import numpy as np
import logging
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException

from ai import ai_client, FAST_MODEL
from db import get_db
from embedder import get_embedder, similarity_thresholds
from schemas import UserPreferencesUpdate, UserInteractionRequest, SiteFollowRequest, SiteOut
from taxonomy import MACRO_CATEGORIES, clean_micro_tags
from routers.deps import validate_uuid, parse_vector
from routers.auth import current_user, ensure_self, rate_limit
from dedup import attach_also_published
from fact_check_status import attach_fact_check_verdicts
from url_utils import canonicalize_url, extract_domain

router = APIRouter(tags=["Users & Personalization"])
logger = logging.getLogger("users_router")

# "+" follows: points for an article that is about something the user follows.
# A passing mention deep in the text does not count; the name must be in the
# title (strong) or the 2-sentence summary. A followed thing also counts like a
# chosen category, so a matching article outside the user's categories gets the
# category points too.
FOLLOW_TITLE_BOOST = 40
FOLLOW_SUMMARY_BOOST = 25
FOLLOW_CATEGORY_POINTS = 20

# Topic-like follows ("Quantum Physics") rarely appear verbatim, so an article
# whose vector is this similar to the follow name also matches (summary-level
# boost). The similarity cut-off belongs to the embedding model
# (embedder.SIMILARITY_THRESHOLDS["..."]["follow_min"]): MiniLM 0.45, Qwen 0.50.

# Optional onboarding "why" sentence ("What should your feed help you with?").
# The interest vector is built from its English version, translated with
# FAST_MODEL when saved: MiniLM only reads English; Qwen3-Embedding reads Turkish
# almost as well (AUC 0.935 vs 0.940) but English is still slightly better.
INTEREST_CONTEXT_MAX_CHARS = 200
CONTEXT_DDL = """
ALTER TABLE users ADD COLUMN IF NOT EXISTS interest_context TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS interest_context_en TEXT;
"""
SYSTEM_PROMPT_TRANSLATE_CONTEXT = (
    "The user wrote, in any language, what they want their news feed to help them with. "
    "Translate it into one natural English sentence and keep its meaning. "
    "If it is already English, return it unchanged. Reply with the sentence only."
)
_context_columns_ready = False

# Characters with special meaning in PostgreSQL regular expressions.
_PG_REGEX_SPECIAL = re.compile(r"([\\.^$*+?()\[\]{}|\-])")


def _follow_pattern(name: str) -> str:
    """Case-insensitive whole-word PostgreSQL regex for a followed name (\\m ... \\M)."""
    clean = " ".join(name.split())
    escaped = _PG_REGEX_SPECIAL.sub(r"\\\1", clean)
    # Word boundaries only next to word characters ("C++" cannot end on \M).
    start = r"\m" if clean[:1].isalnum() else ""
    end = r"\M" if clean[-1:].isalnum() else ""
    return start + escaped + end


def _user_follow_names(cur, user_id: str) -> List[str]:
    """
    Names the user follows (creates the follows table if needed). Follows saved
    before meaning vectors existed get their vector here, once.
    """
    from query_scheduler import FOLLOWS_DDL

    cur.execute("SELECT to_regclass('user_follows') IS NOT NULL;")
    if not cur.fetchone()[0]:
        cur.execute(FOLLOWS_DDL)
        return []
    cur.execute("""
        SELECT id, name, embedding IS NULL FROM user_follows
        WHERE user_id = %s ORDER BY created_at;
    """, (user_id,))
    rows = cur.fetchall()
    missing = [(fid, name) for fid, name, no_vec in rows if no_vec]
    if missing:
        embedder = get_embedder()
        for fid, name in missing:
            cur.execute("UPDATE user_follows SET embedding = %s::vector WHERE id = %s;",
                        (str(embedder.embed_query(name)), fid))
    return [r[1] for r in rows]


def _ensure_context_columns(cur) -> None:
    """Adds the interest-context columns once per process (databases created before them)."""
    global _context_columns_ready
    if not _context_columns_ready:
        cur.execute(CONTEXT_DDL)
        _context_columns_ready = True


def _clean_context(text: str) -> Optional[str]:
    """Trims the user's sentence; None when empty. Too long is a 400."""
    clean = " ".join(text.split())
    if len(clean) > INTEREST_CONTEXT_MAX_CHARS:
        raise HTTPException(
            status_code=400,
            detail=f"interest_context must be at most {INTEREST_CONTEXT_MAX_CHARS} characters"
        )
    return clean or None


def _context_to_english(text: str) -> Optional[str]:
    """English version of the user's sentence for the embedder. None on failure (never raises)."""
    try:
        resp = ai_client.chat.completions.create(
            model=FAST_MODEL,
            temperature=0.0,
            max_tokens=120,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT_TRANSLATE_CONTEXT},
                {"role": "user", "content": text}
            ],
            timeout=20.0
        )
        english = " ".join((resp.choices[0].message.content or "").split()).strip("\"'")
        return english or None
    except Exception as e:
        logger.warning("[Interests] Context translation failed (%s); using the standard sentence.", e)
        return None


def _standard_interest_text(macros: List[str], micros: List[str]) -> str:
    """Sentence built from the chosen topics, used when the user gave no context sentence."""
    text = f"Technical news and updates in {', '.join(macros)}"
    if micros:
        text += f", specifically focused on {', '.join(t.replace('_', ' ').title() for t in micros)}"
    return text + "."


def ema_update(user_vec: Optional[np.ndarray], art_vec: Optional[np.ndarray], itype: str) -> Optional[np.ndarray]:
    """
    Interest vector after one interaction (None = unchanged). Like: EMA attraction
    (+0.15 toward the article); dislike/skip: repulsion (-0.12 away from it).
    Also used by migrate_embeddings.py to replay interactions after a model change.
    """
    if art_vec is None:
        return None
    if itype == "like":
        if user_vec is None:
            return art_vec
        blended = 0.85 * user_vec + 0.15 * art_vec
        norm = float(np.linalg.norm(blended))
        return blended / norm if norm > 0 else blended
    if itype in ("dislike", "skip") and user_vec is not None:
        repelled = user_vec - 0.12 * art_vec
        norm = float(np.linalg.norm(repelled))
        return repelled / norm if norm > 0 else user_vec
    return None


def get_personalized_feed_data(user_id: str, page: int = 1, page_size: int = 20) -> Dict[str, Any]:
    valid_user_id = validate_uuid(user_id, "user_id")
    offset = (page - 1) * page_size

    with get_db() as cur:
        cur.execute("""
            SELECT onboarding_completed, preferred_macro_tags, preferred_micro_tags, interest_embedding
            FROM users WHERE id = %s;
        """, (valid_user_id,))
        user_row = cur.fetchone()
        if not user_row:
            raise HTTPException(status_code=404, detail="User not found")

        onboarding_done, preferred_macros, preferred_micros, user_interest_emb = user_row
        preferred_macros = preferred_macros or []
        preferred_micros = preferred_micros or []

        # Cold-start guardrail: If onboarding incomplete or preferred_macro_tags empty, return chronological fallback
        if not onboarding_done or not preferred_macros:
            cur.execute("""
                SELECT ws.site_name, ws.root_url
                FROM watched_sites ws
                JOIN user_watched_sites uws ON ws.id = uws.site_id
                WHERE uws.user_id = %s;
            """, (valid_user_id,))
            user_site_rows = cur.fetchall()
            user_site_domains = [
                (extract_domain(sroot), sname)
                for sname, sroot in user_site_rows
                if sroot
            ]

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
                  AND (a.on_topic_score IS NULL OR a.on_topic_score >= 0.40)
                  AND NOT EXISTS (
                      SELECT 1 FROM user_article_interactions uai_d
                      WHERE uai_d.user_id = %s
                        AND uai_d.article_id = a.id
                        AND uai_d.interaction_type IN ('dislike', 'skip')
                  )
                ORDER BY a.published_at DESC LIMIT %s OFFSET %s;
            """, (valid_user_id, page_size, offset))
            fallback_rows = cur.fetchall()

            def _parse_fallback_also_published(val):
                if val is None:
                    return []
                if isinstance(val, list):
                    return val
                if isinstance(val, str):
                    try:
                        return json.loads(val)
                    except Exception:
                        return []
                return []

            items = [
                {
                    "id": str(r[0]), "source": r[1], "title": r[2], "url": r[3],
                    "author": r[4], "published_at": r[5], "macro_tag": r[6],
                    "macro_tags": r[7] if r[7] else ([r[6]] if r[6] else []),
                    "micro_tags": r[8] or [], "tldr": r[9],
                    "image_url": r[10],
                    "image_status": r[11] or ("resolved" if r[10] else "gradient_fallback"),
                    "personal_score": 50,
                    "is_liked": False,
                    "is_disliked": False,
                    "matched_sites": [
                        sname for sdom, sname in user_site_domains
                        if (sdom and sdom in (r[3] or "")) or sname == r[1]
                    ],
                    "also_published_by": _parse_fallback_also_published(r[12]) if len(r) > 12 else [],
                    "also_published_by_count": int(r[13]) if len(r) > 13 and r[13] is not None else 0
                }
                for r in fallback_rows
            ]
            attach_fact_check_verdicts(items)
            return {
                "user_id": valid_user_id,
                "is_fallback": True,
                "fallback_reason": "Onboarding not completed or preferences empty",
                "preferred_macro_tags": preferred_macros,
                "preferred_micro_tags": preferred_micros,
                "total": len(items),
                "page": page,
                "page_size": page_size,
                "articles": items
            }

        # Multi-factor zero-leakage personalized ranking (excluding disliked/skipped articles)
        interest_vec_str = None
        user_vec = parse_vector(user_interest_emb)
        if user_vec is not None:
            interest_vec_str = str(user_vec.tolist())

        # "+" follows (routers/follows.py): an article whose title or summary
        # names a followed thing (whole-word match) enters the feed even outside
        # the user's categories and is boosted (see FOLLOW_* points above).
        follow_names = _user_follow_names(cur, valid_user_id)
        follow_patterns = [_follow_pattern(n) for n in follow_names]

        SQL_PERSONALIZED = """
        SELECT
            s.id, s.source_feed, s.title, s.original_url, s.author, s.published_at,
            s.macro_tag, s.macro_tags, s.micro_tags, s.tldr,
            LEAST(100, s.base_score
                + (CASE WHEN cardinality(s.title_follows) > 0 THEN %(follow_title_boost)s
                        WHEN cardinality(s.matched_follows) > 0 THEN %(follow_summary_boost)s
                        ELSE 0 END)
                + (CASE WHEN cardinality(s.matched_follows) > 0
                         AND NOT (s.macro_tag = ANY(%(preferred_macros)s))
                        THEN %(follow_category_points)s ELSE 0 END)
                + (CASE WHEN cardinality(s.matched_sites) > 0 THEN 25 ELSE 0 END)
            )::integer AS personal_score,
            s.is_liked,
            s.matched_follows,
            s.image_url,
            s.image_status,
            s.matched_sites,
            s.also_published_by,
            s.also_published_by_count
        FROM (
            SELECT
                a.id, a.source_feed, a.title, a.original_url, a.author, a.published_at,
                a.macro_tag, a.macro_tags, a.micro_tags, a.tldr,
                a.image_url, a.image_status,
                (
                    LEAST(40, 15 * cardinality(ARRAY(
                        SELECT unnest(a.micro_tags)
                        INTERSECT
                        SELECT unnest(%(preferred_micros)s::text[])
                    ))) +
                    (CASE WHEN a.macro_tag = ANY(%(preferred_macros)s) THEN 20 ELSE 0 END) +
                    (CASE
                        WHEN %(interest_vec)s::text IS NOT NULL AND a.embedding IS NOT NULL
                        THEN ROUND(25.0 * GREATEST(0.0,
                            (1.0 - (a.embedding <=> %(interest_vec)s::vector) - %(feed_floor)s) / (1.0 - %(feed_floor)s)))
                        ELSE 0
                     END) +
                    ROUND(15.0 * EXP(-EXTRACT(EPOCH FROM (NOW() - a.published_at)) / 259200.0))
                ) AS base_score,
                EXISTS (
                    SELECT 1 FROM user_article_interactions uai
                    WHERE uai.user_id = %(user_id)s
                      AND uai.article_id = a.id
                      AND uai.interaction_type = 'like'
                ) AS is_liked,
                ARRAY(
                    SELECT f.name
                    FROM unnest(%(follow_names)s::text[], %(follow_patterns)s::text[]) AS f(name, pattern)
                    WHERE a.title ~* f.pattern
                ) AS title_follows,
                ARRAY(
                    SELECT f.name
                    FROM unnest(%(follow_names)s::text[], %(follow_patterns)s::text[]) AS f(name, pattern)
                    WHERE a.title ~* f.pattern
                       OR COALESCE(a.tldr, '') ~* f.pattern
                    UNION
                    SELECT uf.name
                    FROM user_follows uf
                    WHERE uf.user_id = %(user_id)s
                      AND uf.embedding IS NOT NULL
                      AND a.embedding IS NOT NULL
                      AND (a.embedding <=> uf.embedding) <= %(follow_semantic_max_dist)s
                ) AS matched_follows,
                ARRAY(
                    SELECT ws.site_name
                    FROM watched_sites ws
                    JOIN user_watched_sites uws ON ws.id = uws.site_id
                    WHERE uws.user_id = %(user_id)s
                      AND (
                          EXISTS (
                              SELECT 1 FROM site_discovered_urls sdu
                              WHERE sdu.site_id = ws.id AND sdu.url_canonical = a.original_url
                          )
                          OR a.source_feed = ws.site_name
                          OR POSITION(replace(replace(replace(ws.root_url, 'https://', ''), 'http://', ''), 'www.', '') IN a.original_url) > 0
                      )
                ) AS matched_sites,
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
              AND (a.on_topic_score IS NULL OR a.on_topic_score >= 0.40)
              AND NOT EXISTS (
                  SELECT 1 FROM user_article_interactions uai_d
                  WHERE uai_d.user_id = %(user_id)s
                    AND uai_d.article_id = a.id
                    AND uai_d.interaction_type IN ('dislike', 'skip')
              )
        ) s
        WHERE s.macro_tag = ANY(%(preferred_macros)s)
           OR s.macro_tags && %(preferred_macros)s::text[]
           OR cardinality(s.matched_follows) > 0
           OR cardinality(s.matched_sites) > 0
        ORDER BY personal_score DESC, s.published_at DESC
        LIMIT %(limit)s OFFSET %(offset)s;
        """

        cur.execute(SQL_PERSONALIZED, {
            "preferred_macros": preferred_macros,
            "preferred_micros": preferred_micros,
            "interest_vec": interest_vec_str,
            "user_id": valid_user_id,
            "follow_names": follow_names,
            "follow_patterns": follow_patterns,
            "follow_title_boost": FOLLOW_TITLE_BOOST,
            "follow_summary_boost": FOLLOW_SUMMARY_BOOST,
            "follow_category_points": FOLLOW_CATEGORY_POINTS,
            "follow_semantic_max_dist": 1.0 - similarity_thresholds()["follow_min"],
            "feed_floor": similarity_thresholds()["feed_floor"],
            "limit": page_size,
            "offset": offset
        })
        ranked_rows = cur.fetchall()

        def _parse_ranked_also_published(val):
            if val is None:
                return []
            if isinstance(val, list):
                return val
            if isinstance(val, str):
                try:
                    return json.loads(val)
                except Exception:
                    return []
            return []

        items = [
            {
                "id": str(r[0]), "source": r[1], "title": r[2], "url": r[3],
                "author": r[4], "published_at": r[5], "macro_tag": r[6],
                "macro_tags": r[7] if r[7] else ([r[6]] if r[6] else []),
                "micro_tags": r[8] or [], "tldr": r[9],
                "personal_score": r[10],
                "is_liked": bool(r[11]),
                "is_disliked": False,
                "matched_follows": list(r[12] or []),
                "image_url": r[13],
                "image_status": r[14] or ("resolved" if r[13] else "gradient_fallback"),
                "matched_sites": list(r[15] or []),
                "also_published_by": _parse_ranked_also_published(r[16]) if len(r) > 16 else [],
                "also_published_by_count": int(r[17]) if len(r) > 17 and r[17] is not None else 0
            }
            for r in ranked_rows
        ]
        attach_fact_check_verdicts(items)

        return {
            "user_id": valid_user_id,
            "is_fallback": False,
            "preferred_macro_tags": preferred_macros,
            "preferred_micro_tags": preferred_micros,
            "total": len(items),
            "page": page,
            "page_size": page_size,
            "articles": items
        }


@router.get("/api/feed/personalized")
def personalized_feed(user_id: str, page: int = 1, page_size: int = 20, me: str = Depends(current_user)):
    """Zero-leakage personalized feed ranked by user preferences, GIN micro tags, and semantic vectors."""
    ensure_self(user_id, me)
    return get_personalized_feed_data(user_id=user_id, page=page, page_size=page_size)


@router.post("/api/articles/{article_id}/interactions")
def toggle_interaction(article_id: str, req: UserInteractionRequest, me: str = Depends(current_user)):
    """
    Toggles like, dislike, skip, bookmark, or read state for an article.
    Feeds user interaction context directly into both the 384d interest_embedding
    (EMA attraction on 'like', negative EMA repulsion on 'dislike'/'skip') and
    the user's preferred_micro_tags / preferred_macro_tags profile.
    """
    ensure_self(req.user_id, me)
    valid_art_id = validate_uuid(article_id, "article_id")
    valid_user_id = validate_uuid(req.user_id, "user_id")
    itype = req.interaction_type.strip().lower()
    valid_types = ("like", "dislike", "skip", "bookmark", "read")
    if itype not in valid_types:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid interaction_type. Must be one of: {', '.join(valid_types)}."
        )

    with get_db() as cur:
        cur.execute("""
            SELECT id FROM user_article_interactions
            WHERE user_id = %s AND article_id = %s AND interaction_type = %s;
        """, (valid_user_id, valid_art_id, itype))
        existing = cur.fetchone()

        if existing:
            cur.execute("""
                DELETE FROM user_article_interactions
                WHERE user_id = %s AND article_id = %s AND interaction_type = %s;
            """, (valid_user_id, valid_art_id, itype))
            return {
                "status": "removed",
                "active": False,
                "interaction_type": itype,
                "article_id": valid_art_id,
                "user_id": valid_user_id
            }

        # Remove mutually exclusive opposite signals (like vs dislike/skip)
        if itype == "like":
            cur.execute("""
                DELETE FROM user_article_interactions
                WHERE user_id = %s AND article_id = %s AND interaction_type IN ('dislike', 'skip');
            """, (valid_user_id, valid_art_id))
        elif itype in ("dislike", "skip"):
            cur.execute("""
                DELETE FROM user_article_interactions
                WHERE user_id = %s AND article_id = %s AND interaction_type = 'like';
            """, (valid_user_id, valid_art_id))

        cur.execute("""
            INSERT INTO user_article_interactions (user_id, article_id, interaction_type)
            VALUES (%s, %s, %s);
        """, (valid_user_id, valid_art_id, itype))

        updated_micros = None
        updated_macros = None
        new_vec_str = None

        # Dynamic EMA Vector & Tag Context Learning on 'like' and 'dislike'/'skip'
        if itype in ("like", "dislike", "skip"):
            cur.execute("""
                SELECT embedding, macro_tag, micro_tags
                FROM articles WHERE id = %s;
            """, (valid_art_id,))
            art_row = cur.fetchone()
            art_emb = art_row[0] if art_row else None
            art_macro = art_row[1] if art_row else None
            art_micros = (art_row[2] or []) if art_row else []

            cur.execute("""
                SELECT interest_embedding, preferred_macro_tags, preferred_micro_tags
                FROM users WHERE id = %s;
            """, (valid_user_id,))
            user_row = cur.fetchone()
            user_emb = user_row[0] if user_row else None
            curr_macros = list(user_row[1] or []) if user_row else []
            curr_micros = list(user_row[2] or []) if user_row else []

            art_vec = parse_vector(art_emb)
            user_vec = parse_vector(user_emb)

            new_vec = ema_update(user_vec, art_vec, itype)
            new_vec_str = str(new_vec.tolist()) if new_vec is not None else None

            if itype == "like":
                if art_macro and art_macro != "Off-Topic" and art_macro not in curr_macros:
                    curr_macros.append(art_macro)
                for mt in art_micros[:2]:
                    if mt and mt != "off_topic" and mt not in curr_micros:
                        curr_micros.insert(0, mt)
                curr_micros = curr_micros[:15]
            else:
                # On dislike/skip, prune disliked article's micro-tags if user has other tags
                disliked_set = set(art_micros[:2])
                remaining = [t for t in curr_micros if t not in disliked_set]
                if remaining:
                    curr_micros = remaining

            updated_macros = curr_macros
            updated_micros = curr_micros

            if new_vec_str is not None:
                cur.execute("""
                    UPDATE users 
                    SET interest_embedding = %s::vector,
                        preferred_macro_tags = %s,
                        preferred_micro_tags = %s,
                        onboarding_completed = TRUE
                    WHERE id = %s;
                """, (new_vec_str, updated_macros, updated_micros, valid_user_id))
            else:
                cur.execute("""
                    UPDATE users 
                    SET preferred_macro_tags = %s,
                        preferred_micro_tags = %s
                    WHERE id = %s;
                """, (updated_macros, updated_micros, valid_user_id))

        return {
            "status": "recorded",
            "active": True,
            "interaction_type": itype,
            "article_id": valid_art_id,
            "user_id": valid_user_id,
            "ema_updated": bool(itype in ("like", "dislike", "skip") and new_vec_str is not None),
            "updated_preferred_macro_tags": updated_macros,
            "updated_preferred_micro_tags": updated_micros
        }


USER_COLUMNS = "id, username, avatar_url, onboarding_completed, preferred_macro_tags, preferred_micro_tags, interest_context"


def _user_out(row) -> Dict[str, Any]:
    """API shape of a users row selected with USER_COLUMNS."""
    return {
        "id": str(row[0]),
        "username": row[1],
        "avatar_url": row[2],
        "onboarding_completed": bool(row[3]) if row[3] is not None else False,
        "preferred_macro_tags": row[4] or [],
        "preferred_micro_tags": row[5] or [],
        "interest_context": row[6]
    }


def _fetch_interests_now(macros: List[str], micros: List[str]) -> None:
    """Background task: fetch and save news for the user's newly chosen topics (never raises)."""
    try:
        from ingest_tavily import fetch_user_interests_now
        fetch_user_interests_now(macros, micros)
    except Exception as e:
        logger.warning("[Interests] Fetch-now failed: %s", e)


@router.put("/api/users/{user_id}/preferences")
def update_user_preferences(user_id: str, prefs: UserPreferencesUpdate, background: BackgroundTasks, me: str = Depends(current_user)):
    """
    Saves user-selected macro/micro preferences and the optional context sentence.
    The 384d interest vector is built from the context sentence (in English) when
    there is one, otherwise from a standard sentence naming the chosen topics.
    Then fetches and saves news for any chosen topic whose shared query is due
    (onboarding "fetch and save"; topics fetched recently for others are skipped).
    """
    ensure_self(user_id, me)
    valid_user_id = validate_uuid(user_id, "user_id")

    clean_macros = []
    for m in prefs.preferred_macro_tags:
        for canonical in MACRO_CATEGORIES:
            if canonical.lower() == m.strip().lower() and canonical not in clean_macros:
                clean_macros.append(canonical)
    if not clean_macros and prefs.preferred_macro_tags:
        clean_macros = [MACRO_CATEGORIES[0]]

    clean_micros = clean_micro_tags(prefs.preferred_micro_tags, max_tags=12)

    with get_db() as cur:
        _ensure_context_columns(cur)
        cur.execute("SELECT interest_context, interest_context_en FROM users WHERE id = %s;", (valid_user_id,))
        stored = cur.fetchone()
        if not stored:
            raise HTTPException(status_code=404, detail="User not found")

    # interest_context: absent = keep, empty = clear, text = set.
    if prefs.interest_context is None:
        context, context_en = stored
    else:
        context = _clean_context(prefs.interest_context)
        if not context:
            context_en = None
        elif context == stored[0] and stored[1]:
            context_en = stored[1]
        else:
            context_en = _context_to_english(context)

    interest_text = context_en or _standard_interest_text(clean_macros, clean_micros)

    embedder = get_embedder()
    interest_vector = embedder.embed_query(interest_text)

    with get_db() as cur:
        cur.execute(f"""
            UPDATE users
            SET preferred_macro_tags = %s,
                preferred_micro_tags = %s,
                onboarding_completed = TRUE,
                interest_embedding = %s::vector,
                interest_context = %s,
                interest_context_en = %s
            WHERE id = %s
            RETURNING {USER_COLUMNS};
        """, (clean_macros, clean_micros, str(interest_vector), context, context_en, valid_user_id))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        from routers.latest import forget_latest  # routers.latest imports this module
        forget_latest(cur, valid_user_id)
        background.add_task(_fetch_interests_now, list(row[4] or []), list(row[5] or []))
        return {**_user_out(row), "interest_summary": interest_text}


@router.get("/api/users/{user_id}/preferences")
def get_user_preferences(user_id: str, me: str = Depends(current_user)):
    ensure_self(user_id, me)
    valid_user_id = validate_uuid(user_id, "user_id")
    with get_db() as cur:
        _ensure_context_columns(cur)
        cur.execute(f"SELECT {USER_COLUMNS} FROM users WHERE id = %s;", (valid_user_id,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return _user_out(row)


def _process_site_follow(site_id: str, canonical_url: str, site_name: str) -> None:
    """
    Background worker for on-demand site follow:
      1. Checks TAVILY_CREDIT_RESERVE to protect live credits.
      2. Runs tavily_map(url=canonical_url, purpose="site_follow_map", detail=canonical_url).
      3. Saves discovered URLs to site_discovered_urls.
      4. If discovered < 3: sets status = 'no_articles'.
      5. Else: sets status = 'crawling', runs tavily_crawl(url=canonical_url, limit=5, purpose="site_follow_crawl", detail=canonical_url).
         Sends each post through the normal ingest path (worker labels, summarizes, embeds).
         Sets status = 'ready', updates article_count.
    """
    from tavily_service import tavily_map, tavily_crawl
    from site_watcher import NOISE_PATTERNS, SITE_MAP_DEPTH, SITE_MAP_LIMIT, is_post_url
    import query_scheduler

    logger.info("[Site Follow] Starting crawl/map for site %s (%s)", site_name, canonical_url)
    try:
        # Check credit reserve
        from tavily_service import configured_keys
        with get_db() as cur:
            credit_status = query_scheduler.key_credit_status(cur, configured_keys())
            remaining = query_scheduler.total_remaining(credit_status)
        reserve = int(os.getenv("TAVILY_CREDIT_RESERVE", "150"))
        allowed = query_scheduler.affordable_count(remaining, reserve, cost_per_query=2)
        if allowed is not None and allowed <= 0:
            logger.warning("[Site Follow] Credit reserve reached; marking site %s as failed", site_id)
            with get_db() as cur:
                cur.execute("UPDATE watched_sites SET status = 'failed', last_checked_at = NOW() WHERE id = %s;", (site_id,))
            return

        # 1. Mapping
        with get_db() as cur:
            cur.execute("UPDATE watched_sites SET status = 'mapping' WHERE id = %s;", (site_id,))

        # Same cheap map as the daily check (site_watcher): links on the
        # site's own page, no instructions (~3 credits instead of ~10).
        map_resp = tavily_map(
            url=canonical_url,
            exclude_paths=NOISE_PATTERNS,
            max_depth=SITE_MAP_DEPTH,
            limit=SITE_MAP_LIMIT,
            purpose="site_follow_map",
            detail=canonical_url
        )
        found_urls = map_resp.get("results", [])

        clean_urls: List[str] = []
        for u in found_urls:
            c = canonicalize_url(u)
            if c and is_post_url(c, canonical_url) and c not in clean_urls:
                clean_urls.append(c)

        logger.info("[Site Follow: %s] Discovered %d URLs via Tavily Map", site_name, len(clean_urls))

        with get_db() as cur:
            for u in clean_urls:
                cur.execute("""
                    INSERT INTO site_discovered_urls (site_id, url_canonical, is_ingested)
                    VALUES (%s, %s, FALSE)
                    ON CONFLICT (site_id, url_canonical) DO NOTHING;
                """, (site_id, u))
            cur.execute("UPDATE watched_sites SET last_mapped_at = NOW() WHERE id = %s;", (site_id,))

        if len(clean_urls) < 3:
            logger.info("[Site Follow: %s] Fewer than 3 articles discovered (%d); marking no_articles", site_name, len(clean_urls))
            with get_db() as cur:
                cur.execute("UPDATE watched_sites SET status = 'no_articles', last_checked_at = NOW() WHERE id = %s;", (site_id,))
            return

        # 2. Crawling
        with get_db() as cur:
            cur.execute("UPDATE watched_sites SET status = 'crawling' WHERE id = %s;", (site_id,))

        crawl_resp = tavily_crawl(
            url=canonical_url,
            instructions="recent news announcements, blog posts and press releases",
            limit=5,
            purpose="site_follow_crawl",
            detail=canonical_url
        )
        crawled_results = crawl_resp.get("results", [])
        logger.info("[Site Follow: %s] Crawled %d results via Tavily Crawl", site_name, len(crawled_results))

        # Posts go through the normal ingest path (like run_site_watch_cycle):
        # the worker labels, summarizes and embeds them, and the date comes
        # from the post itself instead of NOW().
        from site_watcher import _infer_article_date, post_title
        from routers.articles import ingest_articles
        from routers.deps import INGESTION_SECRET
        from schemas import ScrapedArticleIn

        payload: List[ScrapedArticleIn] = []
        ingested_urls: List[str] = []
        for r in crawled_results:
            raw_url = r.get("url", "")
            c_url = canonicalize_url(raw_url)
            raw_content = r.get("raw_content", "") or ""
            if not c_url or len(raw_content) < 200 or not is_post_url(c_url, canonical_url):
                continue
            title = post_title(r.get("title"), c_url, raw_content)
            payload.append(ScrapedArticleIn(
                Site=extract_domain(c_url),
                Baslik=title,
                Link=c_url,
                Yazar=site_name,
                Tarih=_infer_article_date(c_url, raw_content),
                TamMetin=raw_content,
            ))
            ingested_urls.append(c_url)

        ingested_count = 0
        if payload:
            ingested_count = ingest_articles(payload, x_secret=INGESTION_SECRET).get("inserted", 0)

        with get_db() as cur:
            for c_url in ingested_urls:
                cur.execute("""
                    INSERT INTO site_discovered_urls (site_id, url_canonical, is_ingested)
                    VALUES (%s, %s, TRUE)
                    ON CONFLICT (site_id, url_canonical) DO UPDATE SET is_ingested = TRUE;
                """, (site_id, c_url))

            cur.execute("""
                UPDATE watched_sites
                SET status = %s,
                    article_count = (SELECT COUNT(*) FROM site_discovered_urls WHERE site_id = %s AND is_ingested = TRUE),
                    last_checked_at = NOW()
                WHERE id = %s;
            """, ("ready" if ingested_urls else "no_articles", site_id, site_id))
        logger.info("[Site Follow: %s] Successfully processed; %d articles ingested, status set to ready.", site_name, ingested_count)

    except Exception as e:
        logger.exception("[Site Follow: %s] Failed processing site follow: %s", site_name, e)
        try:
            with get_db() as cur:
                cur.execute("UPDATE watched_sites SET status = 'failed', last_checked_at = NOW() WHERE id = %s;", (site_id,))
        except Exception:
            pass


@router.get("/api/users/{user_id}/sites", response_model=List[SiteOut])
def get_user_followed_sites(user_id: str, me: str = Depends(current_user)):
    """Returns list of newsrooms/sites followed by the user."""
    ensure_self(user_id, me)
    valid_user_id = validate_uuid(user_id, "user_id")
    with get_db() as cur:
        cur.execute("""
            SELECT ws.id, ws.root_url, ws.site_name, ws.status, ws.article_count, ws.last_checked_at
            FROM watched_sites ws
            JOIN user_watched_sites uws ON ws.id = uws.site_id
            WHERE uws.user_id = %s
            ORDER BY uws.created_at DESC;
        """, (valid_user_id,))
        rows = cur.fetchall()
        return [
            SiteOut(
                id=str(r[0]),
                url=r[1],
                name=r[2],
                status=r[3] or "pending",
                article_count=r[4] or 0,
                last_checked_at=r[5].isoformat() if r[5] else None
            )
            for r in rows
        ]


@router.get("/api/users/{user_id}/sites/articles")
def get_followed_site_articles(user_id: str, limit: int = 200, me: str = Depends(current_user)):
    """
    Stories from the user's followed sites, newest first, each with the
    `site_id` it came from, plus the story count per site (the Site Watch
    page's filter chips). A story belongs to a site when Tavily Map / Crawl
    found its address on the site (`site_discovered_urls`; posts often live
    on another host, e.g. nvidia.com -> blogs.nvidia.com), or by the same
    name / address rule as the personal feed's `matched_sites`. Off-topic
    posts are kept: the user asked for this site.
    """
    ensure_self(user_id, me)
    valid_user_id = validate_uuid(user_id, "user_id")
    limit = max(1, min(limit, 300))
    site_match = """
        JOIN articles a ON a.is_processed = TRUE
         AND a.duplicate_of IS NULL
         AND (
             EXISTS (
                 SELECT 1 FROM site_discovered_urls sdu
                 WHERE sdu.site_id = ws.id AND sdu.url_canonical = a.original_url
             )
             OR a.source_feed = ws.site_name
             OR POSITION(replace(replace(replace(ws.root_url, 'https://', ''), 'http://', ''), 'www.', '') IN a.original_url) > 0
         )
    """
    with get_db() as cur:
        cur.execute(f"""
            SELECT ws.id, COUNT(a.id)
            FROM user_watched_sites uws
            JOIN watched_sites ws ON ws.id = uws.site_id
            {site_match}
            WHERE uws.user_id = %s
            GROUP BY ws.id;
        """, (valid_user_id,))
        counts = {str(r[0]): int(r[1]) for r in cur.fetchall()}

        cur.execute(f"""
            SELECT ws.id, ws.site_name, a.id, a.source_feed, a.title, a.original_url, a.author,
                   a.published_at, a.macro_tag, a.macro_tags, a.micro_tags, a.tldr,
                   a.image_url, a.image_status
            FROM user_watched_sites uws
            JOIN watched_sites ws ON ws.id = uws.site_id
            {site_match}
            WHERE uws.user_id = %s
            ORDER BY a.published_at DESC NULLS LAST
            LIMIT %s;
        """, (valid_user_id, limit))
        rows = cur.fetchall()

    return {
        "counts": counts,
        "articles": attach_also_published(attach_fact_check_verdicts([
            {
                "site_id": str(r[0]),
                "matched_sites": [r[1]],
                "id": str(r[2]), "source": r[3], "title": r[4], "url": r[5],
                "author": r[6], "published_at": r[7], "macro_tag": r[8],
                "macro_tags": r[9] if r[9] else ([r[8]] if r[8] else []),
                "micro_tags": r[10] or [], "tldr": r[11],
                "image_url": r[12],
                "image_status": r[13] or ("resolved" if r[12] else "gradient_fallback"),
            }
            for r in rows
        ])),
    }


@router.post("/api/users/{user_id}/sites", response_model=SiteOut)
def follow_site(user_id: str, req: SiteFollowRequest, background_tasks: BackgroundTasks, me: str = Depends(current_user)):
    """
    Follows a custom newsroom/site URL.
    Enforces maximum 5 followed sites per user.
    Launches background Tavily Map + Crawl pipeline.
    """
    ensure_self(user_id, me)
    rate_limit(me, "site_follow", limit=5, window_seconds=3600)
    valid_user_id = validate_uuid(user_id, "user_id")
    raw_url = req.url.strip()
    if not (raw_url.startswith("http://") or raw_url.startswith("https://")):
        raise HTTPException(status_code=400, detail="URL must start with http:// or https://")

    canonical_url = canonicalize_url(raw_url)
    domain = extract_domain(canonical_url)
    if not domain or domain == "news.web" or "." not in domain:
        raise HTTPException(status_code=400, detail="Invalid site URL or domain")

    # The feed shows "Because you follow <name>", so the domain reads best.
    site_name = domain[4:] if domain.startswith("www.") else domain

    with get_db() as cur:
        # Enforce max 5 sites
        cur.execute("SELECT COUNT(*) FROM user_watched_sites WHERE user_id = %s;", (valid_user_id,))
        count = cur.fetchone()[0]
        if count >= 5:
            raise HTTPException(status_code=400, detail="Maximum 5 followed sites allowed per user")

        # Insert or get watched_site
        cur.execute("""
            INSERT INTO watched_sites (site_name, root_url, status)
            VALUES (%s, %s, 'pending')
            ON CONFLICT (root_url) DO UPDATE
            SET is_active = TRUE
            RETURNING id, site_name, root_url, status, article_count, last_checked_at,
                      (xmax = 0) AS inserted,
                      (last_mapped_at IS NULL OR last_mapped_at < NOW() - INTERVAL '20 hours') AS map_due;
        """, (site_name, canonical_url))
        row = cur.fetchone()
        site_id, site_name, root_url, status, article_count, last_checked_at, inserted, map_due = row

        # Link in user_watched_sites
        cur.execute("""
            INSERT INTO user_watched_sites (user_id, site_id)
            VALUES (%s, %s)
            ON CONFLICT (user_id, site_id) DO NOTHING;
        """, (valid_user_id, site_id))

    # A site someone already follows is shared: scan it only when it is new,
    # failed last time, or its last map is older than the daily check.
    busy = status in ("pending", "mapping", "crawling") and not inserted
    if inserted or (not busy and (status == "failed" or map_due)):
        background_tasks.add_task(_process_site_follow, str(site_id), canonical_url, site_name)

    return SiteOut(
        id=str(site_id),
        url=root_url,
        name=site_name,
        status=status or "pending",
        article_count=article_count or 0,
        last_checked_at=last_checked_at.isoformat() if last_checked_at else None
    )


@router.delete("/api/users/{user_id}/sites/{site_id}")
def unfollow_site(user_id: str, site_id: str, me: str = Depends(current_user)):
    """Unfollows a site for the user."""
    ensure_self(user_id, me)
    valid_user_id = validate_uuid(user_id, "user_id")
    valid_site_id = validate_uuid(site_id, "site_id")
    with get_db() as cur:
        cur.execute("""
            DELETE FROM user_watched_sites
            WHERE user_id = %s AND site_id = %s;
        """, (valid_user_id, valid_site_id))
    return {"status": "unfollowed", "site_id": str(valid_site_id)}
