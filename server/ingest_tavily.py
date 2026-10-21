import os
import sys
import time
import json
import re
import email.utils
import hashlib
import argparse
import logging
from datetime import datetime, timezone, timedelta
from contextlib import contextmanager
from typing import Any, Optional
from urllib.parse import urlparse
import requests
from dotenv import load_dotenv

import query_scheduler
from tavily_service import search_news, tavily_extract
from url_utils import canonicalize_url, extract_domain
from content_cleaner import clean_article_markdown, extract_normalized_shingles
from image_extractor import resolve_article_image

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("tavily_ingestion")

API_INGEST_URL = os.getenv("API_INGEST_URL", "http://localhost:8000/api/internal/ingest")
INGESTION_SECRET = os.getenv("INGESTION_SECRET")

STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".ingest_state.json")

# LEGACY (kept, not used by the default mode): hand-written rotating queries,
# 3 per category. Only run with `--legacy`. The default mode is the
# demand-driven schedule built from query_templates.json (see query_scheduler.py).
TAXONOMY_QUERIES = {
    "AI": [
        ("autonomous AI agents LLM inference reasoning models", "news"),
        ("open source AI models weights benchmarks Ollama vLLM", "news"),
        ("AI chip clusters data centers compute scaling", "news"),
    ],
    "Hardware": [
        ("semiconductor chip fabrication TSMC 2nm packaging GPUs", "news"),
        ("consumer CPUs GPUs gaming laptops handheld consoles", "news"),
        ("solid state storage DDR5 memory architectures", "news"),
    ],
    "Tech": [
        ("cloud infrastructure cybersecurity software developer platforms", "news"),
        ("open source software frameworks programming languages", "news"),
        ("enterprise SaaS cloud native databases devops", "news"),
    ],
    "Automotive": [
        ("electric vehicle solid state battery autonomous driving robotaxi", "news"),
        ("EV charging infrastructure battery manufacturing range", "news"),
        ("software defined vehicles automotive silicon compute", "news"),
    ],
    "Gaming": [
        ("video games console Steam Deck PC gaming engine releases", "news"),
        ("PlayStation Xbox Nintendo handheld hardware game development", "news"),
        ("Unreal Engine 5 graphics ray tracing PC gaming hardware", "news"),
    ],
    "Finance": [
        ("macro economy central banks fintech interest rates cryptocurrency", "finance"),
        ("venture capital tech startup investments IPO market", "finance"),
        ("digital banking payment infrastructure crypto regulation", "finance"),
    ],
    "Science": [
        ("space exploration NASA fusion energy quantum computing materials", "news"),
        ("biotechnology genomics CRISPR medical hardware discoveries", "news"),
        ("renewable energy grid storage nuclear fission reactors", "news"),
    ],
}


def _load_ingest_state() -> dict:
    """Loads rotation state from .ingest_state.json with safe defaults."""
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return {
                        "cycle_index": int(data.get("cycle_index", 0)),
                        "last_successful_run_utc": data.get("last_successful_run_utc")
                    }
    except Exception as e:
        logger.warning("[State] Could not read %s, using defaults: %s", STATE_FILE, e)
    return {"cycle_index": 0, "last_successful_run_utc": None}


def _save_ingest_state(state: dict):
    """Atomically writes rotation state to .ingest_state.json."""
    try:
        temp_file = f"{STATE_FILE}.tmp"
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
        os.replace(temp_file, STATE_FILE)
    except Exception as e:
        logger.error("[State] Failed to persist state to %s: %s", STATE_FILE, e)


def _parse_and_validate_date(raw_date: Any, max_age_days: int = 14) -> Optional[str]:
    """
    Parses ISO-8601 or RFC-2822 timestamps, enforces UTC normalization,
    and guards against future or expired timestamps.
    Falls back gracefully to current UTC time for missing publisher metadata.
    """
    now_utc = datetime.now(timezone.utc)
    if raw_date:
        dt = None
        if isinstance(raw_date, datetime):
            dt = raw_date
        elif isinstance(raw_date, str) and raw_date.strip():
            clean_str = raw_date.strip().replace("Z", "+00:00")
            try:
                dt = datetime.fromisoformat(clean_str)
            except Exception:
                try:
                    dt = email.utils.parsedate_to_datetime(raw_date)
                except Exception:
                    pass

        if dt is not None:
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            else:
                dt = dt.astimezone(timezone.utc)

            # Reject future timestamps (> now + 2 hours tolerance for clock drift)
            if dt > now_utc + timedelta(hours=2):
                logger.warning("[Date Gate] Dropped future date: %s", raw_date)
                return None

            # Reject stale dates older than max_age_days
            if dt < now_utc - timedelta(days=max_age_days):
                logger.warning("[Date Gate] Dropped stale date (>%d days old): %s", max_age_days, raw_date)
                return None

            return dt.isoformat()

    # Safe Hackathon Fallback: default to current time so valid articles aren't lost
    return now_utc.isoformat()


def _truncate_markdown_safely(text: str, max_chars: int = 25000) -> str:
    """
    Slices text at max_chars, breaking on a paragraph or sentence boundary,
    and balances open code fences (```) to prevent formatting corruption.
    """
    if len(text) <= max_chars:
        return text

    sliced = text[:max_chars]
    # Break on paragraph boundary if near the cutoff
    last_para = sliced.rfind('\n\n')
    if last_para >= max_chars - 1200:
        sliced = sliced[:last_para].strip()
    else:
        last_sent = sliced.rfind('. ')
        if last_sent >= max_chars - 600:
            sliced = sliced[:last_sent + 1].strip()

    # Code block balancing: if odd number of ``` fences, close the block
    code_fences = len(re.findall(r'^```', sliced, flags=re.MULTILINE))
    if code_fences % 2 == 1:
        sliced += "\n```\n"

    return sliced


def get_personalized_search_queries(max_queries: int = 3) -> list[tuple[str, str]]:
    """
    LEGACY (kept, only used by `--legacy`): template queries built from all
    users' tags plus a fixed angle suffix. Superseded by the demand-driven
    schedule, where each followed category/subtopic has its own query.

    Synthesizes dynamic multi-angle search queries from active user interest tags AND
    liked/disliked article interactions (discovery, technical depth, and counterpoint).
    Ensures Tavily autonomous harvesting actively adapts to user behavior and feedback.
    """
    queries: list[tuple[str, str]] = []
    try:
        from db import pool
        with pool.connection(timeout=0.5) as conn:
            with conn.cursor() as cur:
                # 1. Gather micro-tags from explicitly liked articles (highest signal)
                cur.execute("""
                    SELECT unnest(a.micro_tags) AS tag, COUNT(*) AS cnt
                    FROM user_article_interactions uai
                    JOIN articles a ON a.id = uai.article_id
                    WHERE uai.interaction_type = 'like'
                      AND a.micro_tags IS NOT NULL
                    GROUP BY tag
                    ORDER BY cnt DESC
                    LIMIT 6;
                """)
                liked_tags = [r[0] for r in cur.fetchall() if r[0] and r[0] != "off_topic"]

                # 2. Gather micro-tags from disliked/skipped articles to exclude
                cur.execute("""
                    SELECT DISTINCT unnest(a.micro_tags) AS tag
                    FROM user_article_interactions uai
                    JOIN articles a ON a.id = uai.article_id
                    WHERE uai.interaction_type IN ('dislike', 'skip')
                      AND a.micro_tags IS NOT NULL
                    LIMIT 10;
                """)
                disliked_tags = {r[0] for r in cur.fetchall() if r[0]}

                # 3. Gather onboarding preferred_micro_tags
                cur.execute("""
                    SELECT DISTINCT unnest(preferred_micro_tags) AS tag 
                    FROM users 
                    WHERE preferred_micro_tags IS NOT NULL AND cardinality(preferred_micro_tags) > 0
                    LIMIT 8;
                """)
                pref_tags = [r[0] for r in cur.fetchall() if r[0]]

                merged_raw = list(dict.fromkeys(liked_tags + pref_tags))
                filtered_tags = [t.replace("_", " ") for t in merged_raw if t not in disliked_tags]
                if not filtered_tags and merged_raw:
                    filtered_tags = [t.replace("_", " ") for t in merged_raw[:4]]

                angles = [
                    "breaking announcements and industry releases",
                    "technical architecture benchmarks and analysis",
                    "independent review risks and market challenges"
                ]
                if filtered_tags:
                    for idx, i in enumerate(range(0, min(len(filtered_tags), max_queries * 2), 2)):
                        chunk = filtered_tags[i:i+2]
                        angle_suffix = angles[idx % len(angles)]
                        topic_type = "finance" if any(k in " ".join(chunk) for k in ("crypto", "fintech", "market", "stock", "earnings")) else "news"
                        queries.append((f"{' '.join(chunk)} {angle_suffix}", topic_type))
    except Exception as e:
        logger.info("[Ingest] Personalized query synthesis note: %s", e)
    return queries[:max_queries]




# Path segments of listing / hub / non-article pages (home pages, tag and
# author archives, stock quotes, job boards). Such pages carry no story.
_NON_ARTICLE_SEGMENTS = {
    "tag", "tags", "category", "categories", "author", "authors", "topic", "topics",
    "search", "quote", "quotes", "symbol", "jobs", "job", "careers", "events",
}
_HUB_SEGMENTS = {"news", "latest", "blog", "blogs", "home", "index", "markets", "tech", "technology"}


def _looks_like_article_url(url: str) -> bool:
    """
    Cheap URL heuristic that drops home pages, section fronts and listing pages
    (e.g. "site.com/", "site.com/news", "site.com/quote/ABC", "site.com/jobs/...").
    Single-segment article slugs ("site.com/smart-reveals-micro-ev") are kept.
    """
    try:
        parsed = urlparse(url)
    except Exception:
        return False
    path = parsed.path.strip("/")
    # Old-style CMS links carry the story id in the query string
    # ("index.cfm?do=main.textpost&id=48AB..."): keep them.
    has_id_query = bool(re.search(r"(^|&)(id|p|story|article|newsid)=[^&]*\d", parsed.query or "", re.I))
    if not path:
        return has_id_query
    segments = [s.lower() for s in path.split("/") if s]
    if any(s in _NON_ARTICLE_SEGMENTS for s in segments):
        return False
    if has_id_query:
        return True
    if all(s in _HUB_SEGMENTS for s in segments):
        return False
    if len(segments) == 1:
        slug = segments[0].rsplit(".", 1)[0]
        return "-" in slug or "_" in slug or any(ch.isdigit() for ch in slug)
    return True


class HarvestDedup:
    """In-memory dedup state shared by all queries of one harvest cycle."""

    def __init__(self):
        self.seen_urls: set[str] = set()
        self.seen_content_hashes: set[str] = set()
        self.seen_shingle_sets: list[set[tuple[str, ...]]] = []


def _harvest_query(
    query: str,
    search_topic: str,
    max_results: int,
    time_range: str,
    purpose: str,
    dedup: HarvestDedup,
    secret: str,
    filter_by_published_date: Optional[bool] = None,
) -> tuple[int, int, bool]:
    """
    Runs one Tavily search and ingests its new articles through the API.
    Pipeline per result: URL dedup -> article-URL check -> markdown cleaning ->
    batched Extract fallback for thin content -> content-hash and shingle
    (wire copy) dedup -> date gate -> POST /api/internal/ingest.

    Returns (fetched, inserted, abort). abort=True means the ingest API rejected
    the secret and the whole cycle must stop.
    """
    try:
        results = search_news(
            topic=query,
            max_results=max_results,
            time_range=time_range,
            search_topic=search_topic,
            include_raw_content="markdown",
            timeout=18.0,
            purpose=purpose,
            filter_by_published_date=filter_by_published_date,
        )
    except Exception as e:
        logger.error("[Search Error] Tavily search failed for '%s': %s", query[:30], e)
        return 0, 0, False

    # Pass 1: Clean raw content & collect short-content URLs for a single batched Tavily Extract call (N13)
    staged_items = []
    short_urls_to_extract = []

    for r in results:
        raw_url = r.get("url", "").strip()
        clean_url = canonicalize_url(raw_url)
        title = r.get("title", "").strip()
        raw_text = (r.get("raw_content") or r.get("content") or "").strip()

        if not clean_url or not title:
            continue

        # Layer 1: In-Memory URL Deduplication
        if clean_url in dedup.seen_urls:
            continue
        dedup.seen_urls.add(clean_url)

        # Home pages, section fronts, quote and job pages are not stories
        if not _looks_like_article_url(clean_url):
            logger.info("[URL Gate] Skipped non-article page: %s", clean_url)
            continue

        text = clean_article_markdown(title, raw_text)
        if not text or len(text) < 250:
            short_urls_to_extract.append(clean_url)
        staged_items.append((r, clean_url, title, text, raw_text))

    extracted_by_url = {}
    if short_urls_to_extract:
        extract_res = tavily_extract(short_urls_to_extract[:5], purpose="ingest_extract_fallback")
        for ep in extract_res.get("results", []):
            ep_url = canonicalize_url(ep.get("url", ""))
            if ep_url and ep.get("raw_content"):
                extracted_by_url[ep_url] = ep["raw_content"]

    payload = []
    for r, clean_url, title, text, raw_text in staged_items:
        if (not text or len(text) < 250) and clean_url in extracted_by_url:
            text = clean_article_markdown(title, extracted_by_url[clean_url])
        if not text or len(text) < 250:
            continue

        # Layer 2: Content Hash Deduplication (SHA-256)
        content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if content_hash in dedup.seen_content_hashes:
            continue
        dedup.seen_content_hashes.add(content_hash)

        # Layer 3: Normalized Shingle Jaccard Similarity (Syndicated wire copies)
        shingles = extract_normalized_shingles(text, k=5)
        if len(shingles) >= 5:
            is_wire_dup = False
            for prev_shingles in dedup.seen_shingle_sets:
                intersection = len(shingles & prev_shingles)
                union = len(shingles | prev_shingles)
                if union > 0 and (intersection / union) >= 0.65:
                    logger.info("[Dedup Gate] Dropped syndicated wire copy (Jaccard: %.2f) for %s", intersection / union, clean_url)
                    is_wire_dup = True
                    break
            if is_wire_dup:
                continue
            dedup.seen_shingle_sets.append(shingles)

        # Boundary-safe markdown truncation and code block balancing
        text = _truncate_markdown_safely(text, max_chars=25000)

        # Date parsing and validation
        published_iso = _parse_and_validate_date(r.get("published_date"))
        if not published_iso:
            continue

        # High-fidelity image resolution (Tavily candidates -> Markdown body -> fast OG fetch)
        effective_raw = extracted_by_url.get(clean_url) or raw_text
        tav_imgs = r.get("images") if isinstance(r.get("images"), list) else ([r.get("image")] if r.get("image") else [])
        img_url, img_status = resolve_article_image(
            raw_markdown=effective_raw,
            tavily_images=tav_imgs,
            page_url=clean_url,
            fetch_og_fallback=True
        )

        # Strict Ingest API contract payload
        payload.append({
            "Site": extract_domain(clean_url),
            "Baslik": title,
            "Link": clean_url,
            "Yazar": r.get("author") or extract_domain(clean_url),
            "Tarih": published_iso,
            "TamMetin": text,
            "image_url": img_url,
            "image_status": img_status,
            "Resim": img_url
        })

    if not payload:
        return len(results), 0, False

    # Robust POST to API Ingest with retries and fail-fast abort on 401/403
    for attempt in range(3):
        try:
            resp = requests.post(
                API_INGEST_URL,
                json=payload,
                headers={"x-secret": secret},
                timeout=25.0
            )
            if resp.status_code == 200:
                return len(results), resp.json().get("inserted", 0), False
            if resp.status_code in (401, 403):
                logger.critical("FATAL: Ingest authentication failed (HTTP %d). Halting ingestion cycle immediately.", resp.status_code)
                return len(results), 0, True
            logger.warning("Ingest API error HTTP %d (attempt %d/3): %s", resp.status_code, attempt + 1, resp.text)
        except Exception as e:
            logger.warning("Ingest connection failed (attempt %d/3): %s", attempt + 1, e)
        if attempt < 2:
            time.sleep(1.0 if attempt == 0 else 3.0)
    return len(results), 0, False


# =====================================================================
# Default mode: demand-driven schedule (query_templates.json)
# =====================================================================
def _credit_budget(cost_per_query: int = 2) -> Optional[int]:
    """
    How many queries may run before automatic ingestion would dip into the
    credit reserve (TAVILY_CREDIT_RESERVE, default 150). None = no limit
    (mock mode, or remaining credits unknown).
    """
    if os.getenv("TAVILY_MOCK", "0").lower() in ("1", "true"):
        return None
    from db import get_db
    from tavily_service import configured_keys

    reserve = int(os.getenv("TAVILY_CREDIT_RESERVE", "150"))
    with get_db() as cur:
        status = query_scheduler.key_credit_status(cur, configured_keys())
    remaining = query_scheduler.total_remaining(status)
    allowed = query_scheduler.affordable_count(remaining, reserve, cost_per_query)
    for s in status:
        logger.info("[Budget] key %s: used ~%s / %s (Tavily reports %s + %s logged locally)%s",
                    s["key_id"], s["used"], s["limit"], s["reported_used"], s["local_since"],
                    " [exhausted]" if s["exhausted"] else "")
    if remaining is not None:
        logger.info("[Budget] Credits remaining: %d (reserve %d) -> up to %s queries this cycle.", remaining, reserve, allowed)
    else:
        logger.warning("[Budget] Remaining Tavily credits unknown; running without a budget limit this cycle.")
    return allowed


@contextmanager
def _schedule_lock():
    """
    Serializes schedule runs across processes (the --loop collector, the API's
    "fetch now" background tasks) with a PostgreSQL advisory lock, so the same
    due query is never fetched twice. Waits for the current holder to finish;
    due queries are recomputed after the lock is taken.
    """
    from db import pool
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_lock(hashtext('wof_ingest_schedule'));")
        try:
            yield
        finally:
            conn.execute("SELECT pg_advisory_unlock(hashtext('wof_ingest_schedule'));")


def run_demand_cycle(only: Optional[set] = None) -> tuple[int, int, int]:
    """
    Runs every followed query whose cadence is due (optionally only the query
    ids in `only`, e.g. one user's new interests). Returns
    (queries_run, total_fetched, total_inserted).
    """
    with _schedule_lock():
        return _run_due_queries(only)


def _run_due_queries(only: Optional[set] = None) -> tuple[int, int, int]:
    from db import get_db

    secret = os.getenv("INGESTION_SECRET")
    if not secret:
        logger.critical("FATAL: INGESTION_SECRET environment variable is unset. Aborting harvest.")
        return 0, 0, 0

    config = query_scheduler.load_config()
    templates = query_scheduler.build_templates(config)
    search_cfg = config.get("search", {})
    backoff = config.get("backoff", {})

    with get_db() as cur:
        due = query_scheduler.sync_and_get_due(cur, templates)
    if only is not None:
        due = [d for d in due if d.template.query_id in only]
    if not due:
        logger.debug("[Schedule] No queries due.")
        return 0, 0, 0

    allowed = _credit_budget()
    if allowed is not None and allowed < len(due):
        if allowed == 0:
            logger.warning("[Budget] Credit reserve reached; skipping %d due queries (they stay due).", len(due))
            return 0, 0, 0
        logger.warning("[Budget] Running %d of %d due queries to protect the credit reserve.", allowed, len(due))
        due = due[:allowed]

    dedup = HarvestDedup()
    runs = fetched_total = inserted_total = 0
    for item in due:
        t = item.template
        logger.info("[Schedule] %-8s %-32s '%s' (followers=%d, every %dh, range=%s)",
                    t.kind, t.query_id, t.query, item.followers, item.interval_hours, t.time_range)
        fetched, inserted, abort = _harvest_query(
            query=t.query,
            search_topic=t.topic,
            max_results=int(search_cfg.get("max_results", 20)),
            time_range=t.time_range,
            purpose="demand_ingestion",
            dedup=dedup,
            secret=secret,
            filter_by_published_date=search_cfg.get("filter_by_published_date"),
        )
        if abort:
            break
        with get_db() as cur:
            interval = query_scheduler.record_run(cur, item, fetched, inserted, backoff)
        logger.info("   -> %d fetched | %d new | next run in %dh", fetched, inserted, interval)
        runs += 1
        fetched_total += fetched
        inserted_total += inserted

    logger.info("[Schedule] Cycle complete: %d queries, %d fetched, %d new articles.", runs, fetched_total, inserted_total)
    return runs, fetched_total, inserted_total


def fetch_follow_now(follow_key: str, macro: str) -> tuple[int, int]:
    """
    First fetch for a "+" follow, run right after a user adds it (API
    background task). Skipped when the shared follow query is not due, i.e. it
    already ran recently for another user. Returns (fetched, inserted).
    """
    secret = os.getenv("INGESTION_SECRET")
    if not secret:
        return 0, 0
    qid = query_scheduler.follow_query_id(follow_key, macro)
    runs, fetched, inserted = run_demand_cycle(only={qid})
    if runs == 0:
        logger.info("[Follow] %s fetched recently (or credit reserve reached); waiting for its next run.", qid)
    else:
        logger.info("[Follow] %s -> %d fetched | %d new", qid, fetched, inserted)
    return fetched, inserted


def user_query_ids(macros, micros) -> set:
    """Query ids a single user's categories and subtopics map to."""
    templates = query_scheduler.load_templates()
    return set(query_scheduler.compute_demand(templates, [(macros, micros)]))


def fetch_user_interests_now(macros, micros) -> tuple[int, int]:
    """
    "Fetch and save" right after a user saves interests (API background task):
    runs that user's queries that are due now; topics fetched recently for
    someone else are skipped. Returns (fetched, inserted).
    """
    only = user_query_ids(macros, micros)
    if not only or not os.getenv("INGESTION_SECRET"):
        return 0, 0
    runs, fetched, inserted = run_demand_cycle(only=only)
    logger.info("[Interests] %d due of %d queries ran -> %d fetched | %d new", runs, len(only), fetched, inserted)
    return fetched, inserted


def run_seed(time_range: Optional[str] = None) -> tuple[int, int, int]:
    """
    One-off database fill: runs every template (all categories and all
    subtopics, followed or not) once. Does not touch the schedule. Respects the
    credit reserve.
    """
    secret = os.getenv("INGESTION_SECRET")
    if not secret:
        logger.critical("FATAL: INGESTION_SECRET environment variable is unset. Aborting seed.")
        return 0, 0, 0

    config = query_scheduler.load_config()
    templates = sorted(
        query_scheduler.build_templates(config).values(),
        key=lambda t: (query_scheduler.KIND_PRIORITY.get(t.kind, 9), t.query_id),
    )
    search_cfg = config.get("search", {})
    seed_range = time_range or config.get("seed", {}).get("time_range", "week")

    allowed = _credit_budget()
    if allowed is not None and allowed < len(templates):
        logger.warning("[Budget] Seeding %d of %d templates to protect the credit reserve.", allowed, len(templates))
        templates = templates[:allowed]

    logger.info("[Seed] Running %d template queries (time_range=%s)...", len(templates), seed_range)
    dedup = HarvestDedup()
    runs = fetched_total = inserted_total = 0
    for t in templates:
        fetched, inserted, abort = _harvest_query(
            query=t.query,
            search_topic=t.topic,
            max_results=int(search_cfg.get("max_results", 20)),
            time_range=seed_range,
            purpose="seed_ingestion",
            dedup=dedup,
            secret=secret,
            filter_by_published_date=search_cfg.get("filter_by_published_date"),
        )
        if abort:
            break
        logger.info("[Seed] %-32s '%s' -> %d fetched | %d new", t.query_id, t.query, fetched, inserted)
        runs += 1
        fetched_total += fetched
        inserted_total += inserted
    logger.info("[Seed] Complete: %d queries, %d fetched, %d new articles.", runs, fetched_total, inserted_total)
    return runs, fetched_total, inserted_total


# =====================================================================
# Legacy mode: fixed rotating queries (kept for reference, `--legacy`)
# =====================================================================
def harvest_and_ingest(
    max_per_topic: int = 4,
    target_total: int = 0,
    all_queries: bool = False,
    time_range: str = "day"
) -> tuple[int, int]:
    """
    LEGACY autonomous multi-category harvesting with TAXONOMY_QUERIES rotation
    and the template "Personalized" queries. Only used with `--legacy`.
    Preserves exact signature: max_per_topic is 1st argument, target_total is 2nd argument.
    Returns (total_fetched, total_inserted).
    """
    secret = os.getenv("INGESTION_SECRET")
    if not secret:
        logger.critical("FATAL: INGESTION_SECRET environment variable is unset. Aborting harvest.")
        return 0, 0

    state = _load_ingest_state()
    cycle_index = state.get("cycle_index", 0)

    total_fetched = 0
    total_inserted = 0
    dedup = HarvestDedup()
    category_stats = {}
    abort_all = False

    logger.info(
        "Harvest cycle starting | Mode: %s | cycle_index: %d | time_range: %s | target_total: %s",
        "ALL-QUERIES" if all_queries else "ROTATING-SINGLE",
        cycle_index,
        time_range,
        target_total or "N/A"
    )

    # Dynamic Personalization Loop: Synthesize queries from active user preferences & likes
    query_schedule = dict(TAXONOMY_QUERIES)
    personalized_queries = get_personalized_search_queries(max_queries=3)
    if personalized_queries:
        logger.info("[Ingest] Injected %d personalized user interest queries into harvest cycle.", len(personalized_queries))
        query_schedule["Personalized"] = personalized_queries

    for category, query_tuples in query_schedule.items():
        if abort_all:
            break

        category_fetched = 0
        category_inserted = 0

        # Determine which queries to run for this category
        if all_queries or category == "Personalized":
            selected_queries = query_tuples
        else:
            selected_queries = [query_tuples[cycle_index % len(query_tuples)]]

        for query, search_topic in selected_queries:
            logger.info("[Ingest: %s] Query: '%s' (topic=%s, requesting %d)...", category, query[:45], search_topic, max_per_topic)
            fetched, inserted, abort_all = _harvest_query(
                query=query,
                search_topic=search_topic,
                max_results=max_per_topic,
                time_range=time_range,
                purpose="personalized_ingestion" if category == "Personalized" else "ingestion",
                dedup=dedup,
                secret=secret,
            )
            category_fetched += fetched
            category_inserted += inserted
            total_fetched += fetched
            total_inserted += inserted
            if abort_all:
                break

        category_stats[category] = {"fetched": category_fetched, "stored": category_inserted}
        logger.info("  -> [%s Summary] %d fetched | %d stored.", category, category_fetched, category_inserted)

    # State update and rotation
    max_queries = max(len(q) for q in TAXONOMY_QUERIES.values())
    new_state = {
        "cycle_index": (cycle_index + 1) % max_queries,
        "last_successful_run_utc": datetime.now(timezone.utc).isoformat()
    }
    _save_ingest_state(new_state)

    logger.info("================ HARVEST BALANCE REPORT ================")
    for cat, stats in category_stats.items():
        logger.info("  * %-12s: %3d stored (fetched %3d)", cat, stats["stored"], stats["fetched"])
    logger.info("========================================================")

    return total_fetched, total_inserted


def main():
    parser = argparse.ArgumentParser(
        description="Tavily News Ingestion Engine. Default: demand-driven schedule from query_templates.json "
                    "(only categories/subtopics that users follow, each at its own cadence)."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="Run due queries once and exit (default)")
    mode.add_argument("--loop", action="store_true", help="Keep running: check for due queries every --tick seconds")
    mode.add_argument("--seed", action="store_true", help="One-off fill: run ALL templates once (followed or not)")
    mode.add_argument("--legacy", action="store_true", help="Old mode: fixed rotating TAXONOMY_QUERIES + template Personalized queries")
    parser.add_argument("--tick", type=int, default=600, help="Loop mode: seconds between schedule checks (default 600). Checks cost no credits.")
    parser.add_argument("--seed-range", default=None, help="Seed mode: Tavily time_range (default from query_templates.json, 'week')")
    # Legacy-only options
    parser.add_argument("--all-queries", action="store_true", help="Legacy: execute all 3 sub-queries per category")
    parser.add_argument("--max", type=int, default=4, help="Legacy: max results per query (default 4)")
    parser.add_argument("--target", type=int, default=0, help="Legacy: target total articles (compatibility)")
    args = parser.parse_args()

    # Fail-fast check on startup CLI invocation
    if not os.getenv("INGESTION_SECRET"):
        logger.critical("FATAL: INGESTION_SECRET environment variable is missing. Halting ingestion.")
        sys.exit(1)

    if args.seed:
        run_seed(args.seed_range)
        return

    if args.legacy:
        # Legacy queries are kept for reference only; they run once, on request.
        logger.info("Starting Tavily Ingestion (LEGACY rotating queries, one shot)...")
        fetched, inserted = harvest_and_ingest(
            max_per_topic=args.max,
            target_total=args.target,
            all_queries=args.all_queries,
            time_range="day"
        )
        logger.info("Cycle complete: %d fetched, %d newly stored.", fetched, inserted)
        return

    if not args.loop:
        run_demand_cycle()
        return

    logger.info("Starting demand-driven ingestion loop (schedule check every %ds)...", args.tick)
    while True:
        try:
            run_demand_cycle()
        except Exception as e:
            logger.error("[Schedule] Cycle failed: %s", e)
        time.sleep(args.tick)


if __name__ == "__main__":
    main()
