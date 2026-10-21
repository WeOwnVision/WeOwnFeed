"""
WAI, the news assistant. A chat always starts from a scope, and WAI writes the
first message itself after reading the scope's material:

  story  - one story (from a news card); WAI reads its full text, as the
           original article chat did
  latest - the user's "Latest developments" card and the 8 stories behind it
           (from the home page)
  area   - the latest stories of one category or subtopic the user picks in the
           WAI tab (last 7 days, 30 if that is too thin)

Model: DeepSeek-V4-Flash without thinking (FAST_MODEL fallback). The server picks
the material and the model answers in one call per message (no tool loop), so a
reply starts streaming in ~1-2 s. Requests are stateless: the app sends the scope
and the stories it was shown with every message.
"""
import json
import logging
import os
from typing import Dict, List, Literal, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException
from fastapi.encoders import jsonable_encoder
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from ai import FAST_MODEL, ai_client
from db import get_db
from routers.deps import validate_uuid
from routers.auth import current_user, ensure_self
from schemas import ChatTurn
from taxonomy import MACRO_CATEGORIES, format_tag_label, get_taxonomy_hierarchy

router = APIRouter(tags=["WAI Assistant"])
logger = logging.getLogger("wai_router")

WAI_MODEL = os.getenv("WAI_MODEL", "deepseek-ai/DeepSeek-V4-Flash-0731")
STORY_TEXT_CHARS = 10000
AREA_STORY_COUNT = 10
AREA_RECENT_DAYS = 7
AREA_FALLBACK_DAYS = 30
AREA_MIN_STORIES = 4
HISTORY_TURNS = 6
NO_THINKING = {"chat_template_kwargs": {"thinking": False, "enable_thinking": False}}

ARTICLE_COLUMNS = "id, source_feed, title, original_url, author, published_at, macro_tag, macro_tags, micro_tags, tldr, image_url, image_status"

SYSTEM_PROMPT = """You are WAI, the intelligent news assistant of the WeOwnFeed (WOF) news app.
{scope}

INSTRUCTIONS:
1. Conversational Continuity: You are in an active dialogue with the reader. Always track the conversation history. When the reader asks a follow-up, refers to "this", or responds to your previous message, interpret their request in the context of the preceding dialogue. If the reader asks to translate your previous message into their language, provide the translation of your previous response immediately—never translate or mirror the reader's own prompt.
2. Grounded Reporting: Answer questions using the facts, figures, and context provided in the MATERIAL below. Never invent external facts, numbers, or quotes.
3. Helpfulness: Directly answer what the reader asks for—including summaries, explanations of mentioned threads, or translations of conversation turns. If a specific detail is not covered in the material, state what is known first, then note what is not specified.
4. Language: Always reply in the language the reader uses. If the reader asks to translate into another language, do so faithfully.
5. Formatting: Use clean Markdown with **bold** highlights for key names and metrics. Keep responses crisp and concise.
{citation_rule}
{reader}

--- MATERIAL ---
{material}"""

OPENING_PROMPT = {
    "story": ("Start the conversation. In English, at most 55 words, 2-3 sentences: say in one line what this story "
              "is about, point to the one thing most worth this reader's attention given their topics, and end with "
              "one question offering a concrete next step (for example explaining the key points or what it means "
              "for them)."),
    "latest": ("Start the conversation. In English, at most 55 words, 2-3 sentences: say you have gone through their "
               "latest developments, hint at the one or two most striking threads in a few words without explaining "
               "them, and end by asking whether they would like you to summarize the most striking aspects or dig "
               "into one thread."),
    "area": ("Start the conversation. In English, at most 55 words, 2-3 sentences: say you have read the latest "
             "stories in {area}, hint at the one or two most striking developments in a few words without explaining "
             "them, and end by asking whether they would like a summary of the most striking developments in {area} "
             "or to dig into one of them."),
}
EMPTY_AREA_OPENING = ("I couldn't find recent stories in {area} yet. New ones arrive through the day; meanwhile you "
                      "can pick another area or ask me about your latest developments.")


class WaiScope(BaseModel):
    user_id: str
    mode: Literal["story", "latest", "area"]
    article_id: Optional[str] = Field(default=None, description="story mode: the story")
    area: Optional[str] = Field(default=None, description="area mode: a category (e.g. 'AI') or subtopic tag")


class WaiChatRequest(WaiScope):
    source_ids: List[str] = Field(default_factory=list, description="latest/area: the stories the chat opened with")
    history: List[ChatTurn] = Field(default_factory=list)
    question: str


def _article_dicts(rows) -> List[dict]:
    return [jsonable_encoder({
        "id": str(r[0]), "source": r[1], "title": r[2], "url": r[3], "author": r[4], "published_at": r[5],
        "macro_tag": r[6], "macro_tags": r[7] or ([r[6]] if r[6] else []), "micro_tags": r[8] or [], "tldr": r[9],
        "image_url": r[10] if len(r) > 10 else None,
        "image_status": r[11] if len(r) > 11 else None,
    }) for r in rows]


def _articles_by_id(ids: List[str]) -> List[dict]:
    valid = [validate_uuid(i, "source_id") for i in ids[:AREA_STORY_COUNT]]
    if not valid:
        return []
    with get_db() as cur:
        cur.execute(f"SELECT {ARTICLE_COLUMNS} FROM articles WHERE id = ANY(%s::uuid[]);", (valid,))
        by_id = {d["id"]: d for d in _article_dicts(cur.fetchall())}
    return [by_id[i] for i in valid if i in by_id]


def resolve_area(area: Optional[str]) -> Tuple[str, str, str]:
    """(kind, key, label) for a category name or subtopic tag; 400 when unknown."""
    value = (area or "").strip()
    for macro in MACRO_CATEGORIES:
        if macro.lower() == value.lower():
            names = {c["macro"]: c.get("display_name") or c["macro"] for c in get_taxonomy_hierarchy()}
            return "macro", macro, names.get(macro, macro)
    tags = {t["tag"]: t["label"] for c in get_taxonomy_hierarchy() for t in c["micro_tags"]}
    if value in tags:
        return "micro", value, tags[value] or format_tag_label(value)
    raise HTTPException(status_code=400, detail=f"Unknown area: {value or '(empty)'}")


def area_stories(kind: str, key: str) -> List[dict]:
    """Newest on-topic stories of the area: last AREA_RECENT_DAYS, widened to
    AREA_FALLBACK_DAYS when fewer than AREA_MIN_STORIES."""
    match = "(a.macro_tag = %(key)s OR %(key)s = ANY(a.macro_tags))" if kind == "macro" else "%(key)s = ANY(a.micro_tags)"
    rows = []
    with get_db() as cur:
        for days in (AREA_RECENT_DAYS, AREA_FALLBACK_DAYS):
            cur.execute(f"""
                SELECT {", ".join("a." + c.strip() for c in ARTICLE_COLUMNS.split(","))}
                FROM articles a
                WHERE a.is_processed AND a.macro_tag IS NOT NULL AND a.macro_tag <> 'Off-Topic'
                  AND (a.on_topic_score IS NULL OR a.on_topic_score >= 0.40)
                  AND a.published_at >= NOW() - make_interval(days => %(days)s)
                  AND {match}
                ORDER BY a.published_at DESC
                LIMIT %(limit)s;
            """, {"key": key, "days": days, "limit": AREA_STORY_COUNT})
            rows = cur.fetchall()
            if len(rows) >= AREA_MIN_STORIES:
                break
    return _article_dicts(rows)


def _reader(user_id: str) -> str:
    with get_db() as cur:
        cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS interest_context TEXT;")
        cur.execute("SELECT preferred_macro_tags, preferred_micro_tags, interest_context FROM users WHERE id = %s;",
                    (user_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
    topics = ", ".join(list(row[0] or []) + [format_tag_label(t) for t in (row[1] or [])[:6]])
    line = f"Reader's topics: {topics or 'not chosen yet'}."
    if row[2]:
        line += f" Why they read the news: {row[2]}"
    return line


def _story_material(article_id: Optional[str]) -> Tuple[str, List[dict], str]:
    valid_id = validate_uuid(article_id or "", "article_id")
    with get_db() as cur:
        cur.execute(f"SELECT {ARTICLE_COLUMNS}, COALESCE(raw_scraped_text, clean_text) FROM articles WHERE id = %s;", (valid_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Article not found")
    story = _article_dicts([row[:-1]])[0]
    material = f"Story: {story['title']} ({story['source']})\n\n{(row[-1] or story['tldr'] or '')[:STORY_TEXT_CHARS]}"
    return material, [story], story["title"]


def _stories_material(stories: List[dict], intro: str = "") -> str:
    lines = "\n".join(f"[{i + 1}] {s['title']} ({s.get('source') or ''}): {s.get('tldr') or ''}"
                      for i, s in enumerate(stories))
    return f"{intro}{lines}"


def build_scope(scope: WaiScope, source_ids: Optional[List[str]] = None) -> Dict:
    """Material, stories and title of a chat. source_ids (follow-up messages) pins the
    stories the chat opened with, so new arrivals do not shift the citation numbers."""
    user_id = validate_uuid(scope.user_id, "user_id")
    reader = _reader(user_id)
    if scope.mode == "story":
        material, stories, title = _story_material(scope.article_id)
        return {"scope": "The reader is asking about one news story.", "material": material, "stories": stories,
                "title": title, "subtitle": "Story chat", "reader": reader, "citations": False, "area_label": None}

    if scope.mode == "latest":
        from routers.latest import latest_card  # routers.latest imports routers.users
        card = latest_card(user_id)
        stories = _articles_by_id(source_ids) if source_ids else card.get("articles") or []
        intro = (f"The reader's latest developments card.\nHeadline: {card.get('headline')}\n"
                 f"Paragraph: {card.get('paragraph')}\n\nThe stories behind it:\n")
        return {"scope": "The reader is asking about their latest developments: the stories ranked highest for them.",
                "material": _stories_material(stories, intro), "stories": stories,
                "title": card.get("headline") or "Your latest developments",
                "subtitle": f"Your latest developments · {len(stories)} stories", "reader": reader,
                "citations": True, "area_label": None}

    kind, key, label = resolve_area(scope.area)
    stories = _articles_by_id(source_ids) if source_ids else area_stories(kind, key)
    return {"scope": f"The reader is asking about the latest news in {label}.",
            "material": _stories_material(stories, f"Latest stories in {label}:\n"), "stories": stories,
            "title": label, "subtitle": f"{label} · {len(stories)} recent stories", "reader": reader,
            "citations": True, "area_label": label}


def _system_message(ctx: Dict) -> Dict[str, str]:
    citation_rule = ("Refer to stories by their numbers in square brackets, like [2], right after the facts you use."
                     if ctx["citations"] else "")
    return {"role": "system", "content": SYSTEM_PROMPT.format(
        scope=ctx["scope"], citation_rule=citation_rule, reader=ctx["reader"], material=ctx["material"])}


def _complete(messages: List[Dict[str, str]], max_tokens: int) -> str:
    """One non-streamed reply; WAI_MODEL, then FAST_MODEL. Raises when both fail."""
    error: Exception = RuntimeError("no attempt")
    for model in (WAI_MODEL, FAST_MODEL):
        try:
            resp = ai_client.chat.completions.create(model=model, messages=messages, temperature=0.3,
                                                     max_tokens=max_tokens, extra_body=NO_THINKING, timeout=45.0)
            text = (resp.choices[0].message.content or "").strip()
            if text:
                return text
            error = ValueError("empty reply")
        except Exception as e:
            error = e
            logger.warning("[WAI] %s failed: %s", model, e)
    raise error


@router.post("/api/wai/open")
def open_chat(scope: WaiScope, me: str = Depends(current_user)):
    """
    Starts a chat: {mode, title, subtitle, opening, sources}. WAI reads the scope's
    material and writes the first message (English); `sources` are the stories the
    chat is about, numbered [1]..[n] in WAI's answers (story mode: the one story).
    """
    ensure_self(scope.user_id, me)
    ctx = build_scope(scope)
    if scope.mode == "area" and not ctx["stories"]:
        opening = EMPTY_AREA_OPENING.format(area=ctx["area_label"])
    else:
        instruction = OPENING_PROMPT[scope.mode].format(area=ctx["area_label"] or "")
        try:
            opening = _complete([_system_message(ctx), {"role": "user", "content": instruction}], max_tokens=250)
        except Exception as e:
            logger.error("[WAI] opening failed (%s): %s", scope.mode, e)
            raise HTTPException(status_code=503, detail="WAI is not available right now")
    return {"mode": scope.mode, "title": ctx["title"], "subtitle": ctx["subtitle"], "opening": opening,
            "sources": ctx["stories"]}


@router.post("/api/wai/chat")
def chat(req: WaiChatRequest, me: str = Depends(current_user)):
    """Answers one message, streamed as SSE `data: {"token": "..."}` events and a final
    `data: [DONE]` (same format as the article chat)."""
    ensure_self(req.user_id, me)
    ctx = build_scope(req, source_ids=req.source_ids or None)
    history = [t.model_dump() for t in req.history[-HISTORY_TURNS:] if t.role in ("user", "assistant")]
    messages = [_system_message(ctx), *history, {"role": "user", "content": req.question.strip()}]

    def stream_tokens():
        for model in (WAI_MODEL, FAST_MODEL):
            sent = False
            try:
                stream = ai_client.chat.completions.create(model=model, messages=messages, temperature=0.3,
                                                           max_tokens=700, stream=True, extra_body=NO_THINKING,
                                                           timeout=45.0)
                for chunk in stream:
                    if not chunk.choices:
                        continue
                    d = chunk.choices[0].delta
                    token = getattr(d, "content", None) or getattr(d, "reasoning_content", None) or getattr(d, "reasoning", None)
                    if token:
                        sent = True
                        yield f"data: {json.dumps({'token': token})}\n\n"
                if sent:
                    yield "data: [DONE]\n\n"
                    return
            except Exception as e:
                logger.warning("[WAI] %s stream failed: %s", model, e)
                if sent:  # half an answer already shown: report instead of restarting
                    yield f"data: {json.dumps({'error': str(e)})}\n\n"
                    return
        yield f"data: {json.dumps({'error': 'WAI is not available right now'})}\n\n"

    return StreamingResponse(stream_tokens(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                                      "X-Accel-Buffering": "no"})
