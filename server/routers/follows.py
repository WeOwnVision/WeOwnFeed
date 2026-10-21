"""
"+" follows: specific things a user follows beyond the taxonomy (a company,
product or person, e.g. "Revolut" in Finance).

- Each distinct (name, category) is ONE shared ingestion query
  ("{name} {category_term}", see query_templates.json), run every 48 h while
  anybody follows it (query_scheduler.py).
- Adding a follow fetches it once right away (background task) unless the
  shared query ran recently for someone else.
- The personalized feed links articles to a follow by whole-word name match in
  the title (strong) or the 2-sentence summary, or by meaning (article vector
  close to the follow-name vector) for topic-like follows; passing mentions deep
  in the text do not count (routers/users.py).
"""
import logging
import re

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException

from db import get_db
from query_scheduler import FOLLOWS_DDL, MAX_FOLLOWS_PER_USER, normalize_follow
from routers.deps import validate_uuid
from routers.auth import current_user, ensure_self, rate_limit
from schemas import FollowCreate
from taxonomy import normalize_macro_tag, MACRO_CATEGORIES

logger = logging.getLogger("follows_router")
router = APIRouter(tags=["Users & Personalization"])

_URLISH = re.compile(r"https?://|www\.|\.(com|net|org|io)\b", re.I)


def _row(r) -> dict:
    return {"id": str(r[0]), "name": r[1], "macro": r[2], "created_at": r[3]}


def _follow_embedding(name: str):
    """Meaning vector of the follow name, embedded as a query (None if the embedder fails)."""
    try:
        from embedder import get_embedder
        return str(get_embedder().embed_query(name))
    except Exception as e:
        logger.warning("[Follow] Could not embed '%s': %s", name, e)
        return None


def _fetch_first(follow_key: str, macro: str) -> None:
    """Background task: first fetch for a new follow (never raises)."""
    try:
        from ingest_tavily import fetch_follow_now
        fetch_follow_now(follow_key, macro)
    except Exception as e:
        logger.warning("[Follow] First fetch for %s/%s failed: %s", macro, follow_key, e)


@router.get("/api/users/{user_id}/follows")
def list_follows(user_id: str, me: str = Depends(current_user)):
    ensure_self(user_id, me)
    uid = validate_uuid(user_id, "user_id")
    with get_db() as cur:
        cur.execute(FOLLOWS_DDL)
        cur.execute("""
            SELECT id, name, macro, created_at FROM user_follows
            WHERE user_id = %s ORDER BY created_at ASC;
        """, (uid,))
        return [_row(r) for r in cur.fetchall()]


@router.post("/api/users/{user_id}/follows")
def add_follow(user_id: str, req: FollowCreate, background: BackgroundTasks, me: str = Depends(current_user)):
    ensure_self(user_id, me)
    rate_limit(me, "follow", limit=10, window_seconds=3600)
    uid = validate_uuid(user_id, "user_id")
    name = " ".join(req.name.split())
    if not 2 <= len(name) <= 40:
        raise HTTPException(status_code=400, detail="Name must be 2-40 characters.")
    if _URLISH.search(name):
        raise HTTPException(status_code=400, detail="Type a name, not a link.")
    if req.macro.strip().lower() not in {m.lower() for m in MACRO_CATEGORIES}:
        raise HTTPException(status_code=400, detail=f"Unknown category '{req.macro}'.")
    macro = normalize_macro_tag(req.macro)
    key = normalize_follow(name)

    with get_db() as cur:
        cur.execute(FOLLOWS_DDL)
        cur.execute("SELECT 1 FROM users WHERE id = %s;", (uid,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="User not found")
        cur.execute("""
            SELECT id, name, macro, created_at FROM user_follows
            WHERE user_id = %s AND follow_key = %s;
        """, (uid, key))
        existing = cur.fetchone()
        if existing:
            return _row(existing)
        cur.execute("SELECT COUNT(*) FROM user_follows WHERE user_id = %s;", (uid,))
        if cur.fetchone()[0] >= MAX_FOLLOWS_PER_USER:
            raise HTTPException(status_code=400, detail=f"You can follow up to {MAX_FOLLOWS_PER_USER} things.")
        cur.execute("""
            INSERT INTO user_follows (user_id, name, follow_key, macro, embedding)
            VALUES (%s, %s, %s, %s, %s::vector)
            RETURNING id, name, macro, created_at;
        """, (uid, name, key, macro, _follow_embedding(name)))
        created = _row(cur.fetchone())

    background.add_task(_fetch_first, key, macro)
    return created


@router.delete("/api/users/{user_id}/follows/{follow_id}")
def remove_follow(user_id: str, follow_id: str, me: str = Depends(current_user)):
    ensure_self(user_id, me)
    uid = validate_uuid(user_id, "user_id")
    fid = validate_uuid(follow_id, "follow_id")
    with get_db() as cur:
        cur.execute(FOLLOWS_DDL)
        cur.execute("DELETE FROM user_follows WHERE id = %s AND user_id = %s RETURNING id;", (fid, uid))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Follow not found")
    return {"status": "removed", "id": fid}
