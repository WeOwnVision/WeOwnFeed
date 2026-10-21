"""
"Latest developments" card of the home page: one generated headline and one
paragraph that tie together the stories ranked highest for the user (their
personalized feed), shaped by their topics and optional context sentence.

The stories' own summaries are reused (no per-user article summaries) and the
result is cached per user: a request returns the cached card at once and
regenerates it in the background when the top stories changed and the card is
older than LATEST_REFRESH_MINUTES; a change of topics or context sentence
regenerates it right away.

Model: DeepSeek-V4-Flash (the team demo's writer) without thinking. Tried
2026-10-18 on 4 real users: headlines 46-66 characters, 64-77 word paragraphs
grounded in the summaries, 1.5-2.6 s and ~$0.0002 per card (with thinking:
9-18 s, 2-4x the cost, similar quality).
"""
import hashlib
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.encoders import jsonable_encoder

from ai import FAST_MODEL, ai_client
from db import get_db
from routers.deps import validate_uuid
from routers.auth import current_user, ensure_self
from routers.users import get_personalized_feed_data

router = APIRouter(tags=["Users & Personalization"])
logger = logging.getLogger("latest_router")

LATEST_MODEL = os.getenv("LATEST_MODEL", "deepseek-ai/DeepSeek-V4-Flash-0731")
LATEST_STORY_COUNT = 8
LATEST_REFRESH_MINUTES = 60
# The home card shows the headline in 26-28 px serif type over at most 3 lines.
HEADLINE_MAX_CHARS = 70
PARAGRAPH_MAX_WORDS = 90
WRITE_ATTEMPTS = 2

LATEST_DDL = """
CREATE TABLE IF NOT EXISTS user_latest_developments (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    profile_key TEXT NOT NULL,       -- topics + context sentence the card was written for
    stories_key TEXT NOT NULL,       -- ids of the stories it was written from
    headline TEXT NOT NULL,
    paragraph TEXT NOT NULL,
    articles JSONB NOT NULL,         -- those stories, as feed items
    model TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
"""

SYSTEM_PROMPT = f"""You write the "Latest developments" card at the top of a reader's personal news home page.
You get the reader's topics, optionally why they read the news, and the summaries of the stories ranked highest for them.

Write:
- headline: one headline that captures the most important development(s) across these stories. At most {HEADLINE_MAX_CHARS} characters including spaces. Plain news style, no clickbait, no colon-heavy lists, no quotes, no emoji.
- paragraph: 3 to 4 short sentences (at most {PARAGRAPH_MAX_WORDS} words) telling the reader what happened lately. Connect related stories, lead with what matters most for this reader's topics and purpose, mention key names and numbers.

Rules: use only facts stated in the summaries; never add numbers, dates or claims that are not there. Skip items that are not news (price pages, listings). Do not address the reader as "you" more than once. Do not mention "summaries" or "stories" as sources.
Reply with JSON only: {{"headline": str, "paragraph": str}}"""

_table_ready = False


def _ensure_table(cur) -> None:
    global _table_ready
    if not _table_ready:
        cur.execute(LATEST_DDL)
        _table_ready = True


def _key(*parts: Any) -> str:
    return hashlib.sha1(json.dumps(parts, sort_keys=True, default=str).encode("utf-8")).hexdigest()[:16]


def _profile(cur, user_id: str) -> Tuple[List[str], List[str], Optional[str]]:
    cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS interest_context TEXT;")
    cur.execute("SELECT preferred_macro_tags, preferred_micro_tags, interest_context FROM users WHERE id = %s;",
                (user_id,))
    row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    return list(row[0] or []), list(row[1] or []), row[2]


def _prompt(macros: List[str], micros: List[str], context: Optional[str], stories: List[dict]) -> str:
    topics = ", ".join(macros + [t.replace("_", " ") for t in micros[:6]])
    lines = "\n".join(f"{i + 1}. {s['title']} ({s.get('source') or ''}): {s.get('tldr') or ''}"
                      for i, s in enumerate(stories))
    why = f"Why they read: {context}\n" if context else ""
    return f"Reader topics: {topics}\n{why}\nStories:\n{lines}"


def _parse(raw: str) -> Dict[str, str]:
    data = json.loads(raw[raw.find("{"):raw.rfind("}") + 1])
    headline = " ".join(str(data.get("headline") or "").split()).strip('"')
    paragraph = " ".join(str(data.get("paragraph") or "").split())
    if not headline or not paragraph:
        raise ValueError("empty headline or paragraph")
    return {"headline": headline, "paragraph": paragraph}


def fit_headline(headline: str, limit: int = HEADLINE_MAX_CHARS) -> str:
    """Last resort for a headline still too long after a retry: cut at a word boundary."""
    if len(headline) <= limit:
        return headline
    cut = headline[:limit + 1].rsplit(" ", 1)[0].rstrip(" ,;:-–—")
    return cut or headline[:limit]


def write_card(prompt: str) -> Tuple[Dict[str, str], str]:
    """Headline + paragraph. A headline over the limit is sent back once with its length;
    LATEST_MODEL failures fall back to FAST_MODEL. Raises when every attempt fails."""
    error: Exception = RuntimeError("no attempt")
    for model in (LATEST_MODEL, FAST_MODEL):
        messages = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": prompt}]
        card = None
        for _ in range(WRITE_ATTEMPTS):
            try:
                resp = ai_client.chat.completions.create(
                    model=model,
                    temperature=0.2,
                    max_tokens=500,
                    messages=messages,
                    response_format={"type": "json_object"},
                    extra_body={"chat_template_kwargs": {"thinking": False, "enable_thinking": False}},
                    timeout=45.0,
                )
                raw = resp.choices[0].message.content or ""
                card = _parse(raw)
            except Exception as e:
                error = e
                logger.warning("[Latest] %s failed: %s", model, e)
                continue
            if len(card["headline"]) <= HEADLINE_MAX_CHARS:
                return card, model
            messages = messages + [
                {"role": "assistant", "content": raw},
                {"role": "user", "content": f"The headline has {len(card['headline'])} characters. "
                                            f"Rewrite it in at most {HEADLINE_MAX_CHARS} characters; keep the paragraph."},
            ]
        if card:
            return {**card, "headline": fit_headline(card["headline"])}, model
    raise error


def generate_latest(user_id: str) -> Optional[dict]:
    """Writes and stores the card from the user's current top stories. None when the
    user has no personalized feed yet (onboarding not finished)."""
    feed = get_personalized_feed_data(user_id, page=1, page_size=LATEST_STORY_COUNT)
    stories = feed.get("articles") or []
    if feed.get("is_fallback") or not stories:
        return None
    with get_db() as cur:
        _ensure_table(cur)
        macros, micros, context = _profile(cur, user_id)
    card, model = write_card(_prompt(macros, micros, context, stories))
    stories_json = jsonable_encoder(stories)
    with get_db() as cur:
        cur.execute("""
            INSERT INTO user_latest_developments
                (user_id, profile_key, stories_key, headline, paragraph, articles, model, created_at)
            VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s, NOW())
            ON CONFLICT (user_id) DO UPDATE
            SET profile_key = EXCLUDED.profile_key, stories_key = EXCLUDED.stories_key,
                headline = EXCLUDED.headline, paragraph = EXCLUDED.paragraph,
                articles = EXCLUDED.articles, model = EXCLUDED.model, created_at = NOW()
            RETURNING created_at;
        """, (user_id, _key(macros, micros, context), _key([s["id"] for s in stories]),
              card["headline"], card["paragraph"], json.dumps(stories_json), model))
        created_at = cur.fetchone()[0]
    logger.info("[Latest] %s: '%s' (%s)", user_id[:8], card["headline"], model)
    return {**card, "articles": stories_json, "model": model, "generated_at": created_at, "refreshing": False}


def forget_latest(cur, user_id: str) -> None:
    """Drops the user's card (their topics or context sentence changed): the next
    request writes a new one right away instead of showing the old one."""
    cur.execute("SELECT to_regclass('user_latest_developments') IS NOT NULL;")
    if cur.fetchone()[0]:
        cur.execute("DELETE FROM user_latest_developments WHERE user_id = %s;", (user_id,))


def _refresh_in_background(user_id: str) -> None:
    try:
        generate_latest(user_id)
    except Exception as e:
        logger.warning("[Latest] background refresh failed for %s: %s", user_id[:8], e)


@router.get("/api/users/{user_id}/latest-developments")
def latest_developments(user_id: str, background: BackgroundTasks, me: str = Depends(current_user)):
    """
    Home page card: {headline, paragraph, articles (the stories it covers, newest
    ranking first), model, generated_at, refreshing}. 409 until the user has picked
    interests. The first call writes the card (~2 s); later calls return the cached
    card and refresh it in the background when the top stories changed.
    """
    ensure_self(user_id, me)
    return latest_card(validate_uuid(user_id, "user_id"), background)


def latest_card(valid_user_id: str, background: Optional[BackgroundTasks] = None) -> dict:
    """The user's card as the endpoint returns it (also used by WAI's "latest" chat).
    Without `background` a stale card is returned as is, never refreshed."""
    with get_db() as cur:
        _ensure_table(cur)
        macros, micros, context = _profile(cur, valid_user_id)
        cur.execute("""
            SELECT profile_key, stories_key, headline, paragraph, articles, model, created_at
            FROM user_latest_developments WHERE user_id = %s;
        """, (valid_user_id,))
        cached = cur.fetchone()

    if cached:
        # Likes also add topics, so a changed profile is refreshed in the background
        # like changed stories; saving preferences deletes the card (forget_latest).
        profile_key, stories_key, headline, paragraph, articles, model, created_at = cached
        refreshing = False
        stale = created_at < datetime.now(timezone.utc) - timedelta(minutes=LATEST_REFRESH_MINUTES)
        if background is not None and stale:
            top = get_personalized_feed_data(valid_user_id, page=1, page_size=LATEST_STORY_COUNT)
            stories_changed = _key([s["id"] for s in top.get("articles") or []]) != stories_key
            if stories_changed or profile_key != _key(macros, micros, context):
                background.add_task(_refresh_in_background, valid_user_id)
                refreshing = True
        return {"headline": headline, "paragraph": paragraph, "articles": articles, "model": model,
                "generated_at": created_at, "refreshing": refreshing}

    try:
        result = generate_latest(valid_user_id)
    except Exception as e:
        logger.error("[Latest] could not write the card for %s: %s", valid_user_id[:8], e)
        raise HTTPException(status_code=503, detail="Latest developments are not available right now")
    if result is None:
        raise HTTPException(status_code=409, detail="Pick your interests first")
    return result
