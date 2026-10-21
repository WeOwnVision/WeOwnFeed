"""
query_scheduler.py
------------------
Demand-driven Tavily query schedule for ingest_tavily.py.

- Templates live in query_templates.json: one query per category and per
  taxonomy subtopic.
- A query is active only while at least one onboarded user follows it
  (users.preferred_macro_tags / preferred_micro_tags). Nobody follows it -> it
  never runs and costs no credits.
- Each kind has its own cadence (category 6 h, core subtopic 24 h, specific
  subtopic 48 h). The ingest loop only *checks* every few minutes which queries
  are due; checking is free.
- Low-yield backoff: a query that keeps returning almost no new articles slows
  down (interval doubles up to a cap) and returns to its base cadence as soon as
  it is productive again.
- Credit reserve: before a cycle the remaining Tavily plan credits are read from
  the /usage endpoint; automatic ingestion stops before dipping into the reserve
  (TAVILY_CREDIT_RESERVE) so verification and the live demo keep working.

The pure functions here (templates, demand, backoff, budget) have no database
or network access and are unit-tested in tests/test_query_scheduler.py.
"""

import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import requests

from embedder import embedding_dim

logger = logging.getLogger("query_scheduler")

TEMPLATES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "query_templates.json")
TAVILY_USAGE_URL = "https://api.tavily.com/usage"

# Due queries run in this order: broad category feeds first, then subtopics.
KIND_PRIORITY = {"category": 0, "core": 1, "specific": 2, "follow": 3}

STATE_DDL = """
CREATE TABLE IF NOT EXISTS ingest_query_state (
    query_id VARCHAR(120) PRIMARY KEY,
    kind VARCHAR(20) NOT NULL,
    macro VARCHAR(50) NOT NULL,
    tag VARCHAR(80),
    query TEXT NOT NULL,
    followers INT NOT NULL DEFAULT 0,
    interval_hours INT NOT NULL,
    low_yield_streak INT NOT NULL DEFAULT 0,
    next_run_at TIMESTAMP WITH TIME ZONE,
    last_run_at TIMESTAMP WITH TIME ZONE,
    last_fetched INT NOT NULL DEFAULT 0,
    last_inserted INT NOT NULL DEFAULT 0,
    total_runs INT NOT NULL DEFAULT 0,
    total_inserted INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ingest_query_state_due ON ingest_query_state (followers, next_run_at);
"""

# "+" follows: specific things (a company, product, person) a user types in
# onboarding. Each distinct (follow_key, macro) becomes one shared query.
FOLLOWS_DDL = f"""
CREATE TABLE IF NOT EXISTS user_follows (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(60) NOT NULL,
    follow_key VARCHAR(60) NOT NULL,
    macro VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (user_id, follow_key)
);
CREATE INDEX IF NOT EXISTS idx_user_follows_key ON user_follows (follow_key, macro);
-- Meaning vector of the follow name: topic-like follows ("Quantum Physics")
-- rarely appear verbatim in titles, so the feed also matches them semantically.
ALTER TABLE user_follows ADD COLUMN IF NOT EXISTS embedding vector({embedding_dim()});
"""

MAX_FOLLOWS_PER_USER = 3

# Credit accounting. Tavily's /usage counter can lag for a long time (observed
# frozen for hours on 2026-10-18), so the budget adds our own logged spend
# (tavily_calls, per key) since the reported value was first seen.
CREDIT_DDL = """
ALTER TABLE tavily_calls ADD COLUMN IF NOT EXISTS key_id VARCHAR(16);
CREATE TABLE IF NOT EXISTS tavily_usage_seen (
    key_id VARCHAR(16) PRIMARY KEY,
    reported_usage INT NOT NULL,
    plan_limit INT NOT NULL,
    first_seen_at TIMESTAMP WITH TIME ZONE NOT NULL,
    checked_at TIMESTAMP WITH TIME ZONE NOT NULL
);
-- Last estimate: the estimate never goes down within a month, even when the
-- lagging Tavily counter moves only part of the way.
ALTER TABLE tavily_usage_seen ADD COLUMN IF NOT EXISTS estimated_used INT;
"""


@dataclass(frozen=True)
class QueryTemplate:
    query_id: str          # "cat:AI" or "sub:AI:llm_agents"
    kind: str              # category | core | specific
    macro: str
    tag: Optional[str]
    query: str
    topic: str
    interval_hours: int
    time_range: str


@dataclass(frozen=True)
class DueQuery:
    template: QueryTemplate
    followers: int
    interval_hours: int     # current interval, after any backoff
    low_yield_streak: int


# =====================================================================
# Templates
# =====================================================================
def load_config(path: str = TEMPLATES_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_templates(config: dict) -> Dict[str, QueryTemplate]:
    """Flattens query_templates.json into QueryTemplate objects keyed by query_id."""
    search = config.get("search", {})
    cadence = config["cadence"]
    default_topic = search.get("topic", "news")
    templates: Dict[str, QueryTemplate] = {}

    def make(query_id: str, kind: str, macro: str, tag: Optional[str], entry: dict) -> QueryTemplate:
        rule = cadence[kind]
        return QueryTemplate(
            query_id=query_id,
            kind=kind,
            macro=macro,
            tag=tag,
            query=entry["query"].strip(),
            topic=entry.get("topic", default_topic),
            interval_hours=int(entry.get("interval_hours", rule["interval_hours"])),
            time_range=entry.get("time_range", rule["time_range"]),
        )

    for macro, cat in config["categories"].items():
        cid = f"cat:{macro}"
        templates[cid] = make(cid, "category", macro, None, cat)
        for tag, sub in cat.get("subtopics", {}).items():
            sid = f"sub:{macro}:{tag}"
            templates[sid] = make(sid, sub.get("kind", "core"), macro, tag, sub)
    return templates


def load_templates(path: str = TEMPLATES_PATH) -> Dict[str, QueryTemplate]:
    return build_templates(load_config(path))


# =====================================================================
# Demand: which queries are followed, and by how many users
# =====================================================================
def compute_demand(
    templates: Dict[str, QueryTemplate],
    profiles: Iterable[Tuple[Sequence[str], Sequence[str]]],
) -> Dict[str, int]:
    """
    Maps each followed query_id to its follower count.

    `profiles` holds (preferred_macro_tags, preferred_micro_tags) per onboarded
    user. A category query is followed by everyone who picked the category. A
    subtopic query is followed by users who picked that subtopic (a subtopic
    without its category still counts). Tags without a template (e.g. free-form
    LLM tags learned from likes) are ignored.
    """
    by_macro = {t.macro.lower(): t.query_id for t in templates.values() if t.kind == "category"}
    by_tag: Dict[str, str] = {}
    for t in templates.values():
        if t.tag and t.tag not in by_tag:
            by_tag[t.tag] = t.query_id

    demand: Dict[str, int] = {}
    for macros, micros in profiles:
        followed = set()
        for m in macros or []:
            qid = by_macro.get(str(m).strip().lower())
            if qid:
                followed.add(qid)
        for tag in micros or []:
            qid = by_tag.get(str(tag).strip().lower())
            if qid:
                followed.add(qid)
        for qid in followed:
            demand[qid] = demand.get(qid, 0) + 1
    return demand


def normalize_follow(name: str) -> str:
    """Follow key: case- and space-insensitive ("  Steam  Deck " -> "steam deck")."""
    return " ".join(str(name).split()).lower()


def follow_query_id(follow_key: str, macro: str) -> str:
    return f"follow:{macro}:{follow_key}"


def build_follow_templates(
    config: dict,
    rows: Iterable[Tuple[str, str, str, int]],
) -> Tuple[Dict[str, QueryTemplate], Dict[str, int]]:
    """
    Turns aggregated follows (follow_key, macro, display_name, followers) into
    query templates and demand. The query is "{name} {category_term}" (e.g.
    "Revolut finance"): the category word keeps namesakes apart (Apple the
    company vs. the fruit). Unknown categories are skipped.
    """
    rule = config["cadence"]["follow"]
    pattern = config.get("follow_template", "{name} {category_term}")
    topic = config.get("search", {}).get("topic", "news")
    categories = config["categories"]
    templates: Dict[str, QueryTemplate] = {}
    demand: Dict[str, int] = {}
    for key, macro, name, followers in rows:
        cat = categories.get(macro)
        if not cat or followers <= 0:
            continue
        qid = follow_query_id(key, macro)
        templates[qid] = QueryTemplate(
            query_id=qid,
            kind="follow",
            macro=macro,
            tag=None,
            query=pattern.format(name=" ".join(str(name).split()), category_term=cat.get("category_term", macro)).strip(),
            topic=topic,
            interval_hours=int(rule["interval_hours"]),
            time_range=rule["time_range"],
        )
        demand[qid] = demand.get(qid, 0) + int(followers)
    return templates, demand


def order_due(due: List[DueQuery]) -> List[DueQuery]:
    """Category feeds first, then by follower count (most followed first)."""
    return sorted(due, key=lambda d: (KIND_PRIORITY.get(d.template.kind, 9), -d.followers, d.template.query_id))


# =====================================================================
# Low-yield backoff
# =====================================================================
def next_interval(
    base_hours: int,
    current_hours: int,
    low_yield_streak: int,
    inserted: int,
    backoff: dict,
) -> Tuple[int, int]:
    """
    Returns (new_interval_hours, new_low_yield_streak) after a run.

    Productive run (>= low_yield_inserted new articles): back to the base cadence.
    Otherwise the streak grows; after low_yield_runs low runs in a row the
    interval doubles (capped at max_interval_hours) and the streak restarts.
    """
    threshold = int(backoff.get("low_yield_inserted", 2))
    runs = int(backoff.get("low_yield_runs", 2))
    cap = int(backoff.get("max_interval_hours", 168))
    current = max(int(current_hours or base_hours), base_hours)

    if inserted >= threshold:
        return base_hours, 0
    streak = low_yield_streak + 1
    if streak >= runs:
        return min(current * 2, max(cap, base_hours)), 0
    return current, streak


# =====================================================================
# Credit budget
# =====================================================================
def credits_remaining_from_usage(usage: dict) -> Optional[int]:
    """Remaining plan credits from a Tavily /usage response (None if unknown)."""
    account = (usage or {}).get("account") or {}
    limit = account.get("plan_limit")
    used = account.get("plan_usage")
    if limit is None or used is None:
        return None
    return int(limit) - int(used)


def fetch_usage(api_key: Optional[str], timeout: float = 10.0) -> Optional[Tuple[int, int]]:
    """(plan_usage, plan_limit) as reported by Tavily /usage, or None if unavailable."""
    if not api_key:
        return None
    try:
        resp = requests.get(TAVILY_USAGE_URL, headers={"Authorization": f"Bearer {api_key}"}, timeout=timeout)
        if resp.status_code != 200:
            logger.warning("[Budget] Tavily /usage returned HTTP %d", resp.status_code)
            return None
        account = (resp.json() or {}).get("account") or {}
        if account.get("plan_usage") is None or account.get("plan_limit") is None:
            return None
        return int(account["plan_usage"]), int(account["plan_limit"])
    except Exception as e:
        logger.warning("[Budget] Could not read Tavily usage: %s", e)
        return None


def fetch_remaining_credits(api_key: Optional[str], timeout: float = 10.0) -> Optional[int]:
    """Remaining plan credits as reported by Tavily (may lag). None if unavailable."""
    usage = fetch_usage(api_key, timeout)
    return None if usage is None else usage[1] - usage[0]


def estimate_used(
    reported_usage: int,
    local_since_first_seen: float,
    previous_estimate: Optional[int] = None,
    local_since_previous: float = 0.0,
) -> int:
    """
    Conservative credits used: the larger of
      - Tavily's reported value + what we logged since that value was first seen
        (covers a frozen counter), and
      - our previous estimate + what we logged since that estimate
        (covers a counter that catches up only part of the way).
    So the estimate never decreases within a month. Double counting calls Tavily
    already included errs on the safe side.
    """
    from_report = reported_usage + max(local_since_first_seen, 0)
    from_previous = (previous_estimate or 0) + max(local_since_previous, 0)
    return int(max(from_report, from_previous))


def key_credit_status(cur, keys: Sequence[str], now: Optional[datetime] = None) -> List[dict]:
    """
    Per-key credit picture: [{key_id, reported_used, local_since, used, limit,
    remaining}]. The first key also owns calls logged before key ids existed
    (key_id IS NULL). Unknown limits give remaining=None.
    """
    from tavily_service import key_id as make_key_id, is_key_exhausted

    now = now or datetime.now(timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    cur.execute(CREDIT_DDL)
    status = []
    for index, key in enumerate(keys):
        kid = make_key_id(key)
        usage = fetch_usage(key)
        cur.execute("""
            SELECT reported_usage, plan_limit, first_seen_at, checked_at, estimated_used
            FROM tavily_usage_seen WHERE key_id = %s;
        """, (kid,))
        seen = cur.fetchone()
        # Anything recorded in an earlier month does not carry over.
        if seen is not None and seen[3] < month_start:
            seen = None
        previous_estimate = seen[4] if seen else None
        previous_at = seen[3] if seen else month_start

        if usage is not None:
            reported, limit = usage
            if seen is None:
                # First observation: count our whole month to be safe.
                first_seen = month_start
            elif seen[0] != reported:
                first_seen = now
            else:
                first_seen = seen[2]
        elif seen is not None:
            reported, limit, first_seen = seen[0], seen[1], seen[2]
        else:
            status.append({"key_id": kid, "reported_used": None, "local_since": None, "used": None,
                           "limit": None, "remaining": None, "exhausted": is_key_exhausted(kid)})
            continue

        def logged_since(since):
            cur.execute("""
                SELECT COALESCE(SUM(credits_est), 0) FROM tavily_calls
                WHERE created_at >= %s AND cache_hit = FALSE
                  AND (key_id = %s OR (%s AND key_id IS NULL));
            """, (max(since, month_start), kid, index == 0))
            return float(cur.fetchone()[0] or 0)

        local = logged_since(first_seen)
        used = estimate_used(reported, local, previous_estimate, logged_since(previous_at))
        cur.execute("""
            INSERT INTO tavily_usage_seen (key_id, reported_usage, plan_limit, first_seen_at, checked_at, estimated_used)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (key_id) DO UPDATE
            SET reported_usage = EXCLUDED.reported_usage, plan_limit = EXCLUDED.plan_limit,
                first_seen_at = EXCLUDED.first_seen_at, checked_at = EXCLUDED.checked_at,
                estimated_used = EXCLUDED.estimated_used;
        """, (kid, reported, limit, first_seen, now, used))
        status.append({
            "key_id": kid, "reported_used": reported, "local_since": round(local, 1), "used": used,
            "limit": limit, "remaining": max(limit - used, 0), "exhausted": is_key_exhausted(kid),
        })
    return status


def total_remaining(status: Sequence[dict]) -> Optional[int]:
    """
    Remaining credits over keys that still work. No working key -> 0. If no
    working key's balance is known -> None (unknown, do not limit). Keys with an
    unknown balance count as 0 when others are known (conservative).
    """
    live = [s for s in status if not s.get("exhausted")]
    if not live:
        return 0
    known = [s["remaining"] for s in live if s.get("remaining") is not None]
    if not known:
        return None
    return sum(known)


def affordable_count(remaining: Optional[int], reserve: int, cost_per_query: int = 2) -> Optional[int]:
    """
    How many queries this cycle may run without dipping into the reserve.
    cost_per_query counts the search (1 credit) plus a possible extract
    fallback (<= 1 credit). None means "unknown, do not limit".
    """
    if remaining is None:
        return None
    return max(0, (remaining - reserve) // max(cost_per_query, 1))


# =====================================================================
# Database state
# =====================================================================
def ensure_state_table(cur) -> None:
    cur.execute(STATE_DDL)
    cur.execute(FOLLOWS_DDL)
    cur.execute(CREDIT_DDL)


def fetch_follow_rows(cur) -> List[Tuple[str, str, str, int]]:
    """(follow_key, macro, display_name, followers) for every followed thing."""
    cur.execute("""
        SELECT follow_key, macro, MIN(name), COUNT(*)
        FROM user_follows
        GROUP BY follow_key, macro;
    """)
    return [(r[0], r[1], r[2], int(r[3])) for r in cur.fetchall()]


def fetch_profiles(cur) -> List[Tuple[List[str], List[str]]]:
    cur.execute("""
        SELECT preferred_macro_tags, preferred_micro_tags
        FROM users
        WHERE onboarding_completed = TRUE
          AND cardinality(preferred_macro_tags) > 0;
    """)
    return [(r[0] or [], r[1] or []) for r in cur.fetchall()]


def sync_and_get_due(cur, templates: Dict[str, QueryTemplate], now: Optional[datetime] = None) -> List[DueQuery]:
    """
    Updates follower counts in ingest_query_state (new followed queries become
    due immediately; unfollowed ones drop to 0 followers and stop) and returns
    the queries that are due now, in run order.
    """
    now = now or datetime.now(timezone.utc)
    ensure_state_table(cur)
    demand = compute_demand(templates, fetch_profiles(cur))
    follow_templates, follow_demand = build_follow_templates(load_config(), fetch_follow_rows(cur))
    templates = {**templates, **follow_templates}
    demand.update(follow_demand)

    cur.execute("UPDATE ingest_query_state SET followers = 0, updated_at = NOW() WHERE followers > 0;")
    for qid, followers in demand.items():
        t = templates[qid]
        cur.execute("""
            INSERT INTO ingest_query_state (query_id, kind, macro, tag, query, followers, interval_hours, next_run_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (query_id) DO UPDATE
            SET kind = EXCLUDED.kind,
                macro = EXCLUDED.macro,
                tag = EXCLUDED.tag,
                query = EXCLUDED.query,
                followers = EXCLUDED.followers,
                interval_hours = GREATEST(ingest_query_state.interval_hours, EXCLUDED.interval_hours),
                next_run_at = COALESCE(ingest_query_state.next_run_at, EXCLUDED.next_run_at),
                updated_at = NOW();
        """, (qid, t.kind, t.macro, t.tag, t.query, followers, t.interval_hours, now))

    cur.execute("""
        SELECT query_id, followers, interval_hours, low_yield_streak
        FROM ingest_query_state
        WHERE followers > 0 AND (next_run_at IS NULL OR next_run_at <= %s);
    """, (now,))
    due = [
        DueQuery(template=templates[qid], followers=f, interval_hours=iv, low_yield_streak=st)
        for qid, f, iv, st in cur.fetchall()
        if qid in templates
    ]
    return order_due(due)


def record_run(cur, due: DueQuery, fetched: int, inserted: int, backoff: dict, now: Optional[datetime] = None) -> int:
    """Stores a run's result and schedules the next one. Returns the new interval in hours."""
    now = now or datetime.now(timezone.utc)
    interval, streak = next_interval(
        due.template.interval_hours, due.interval_hours, due.low_yield_streak, inserted, backoff
    )
    cur.execute("""
        UPDATE ingest_query_state
        SET interval_hours = %s,
            low_yield_streak = %s,
            last_run_at = %s,
            next_run_at = %s,
            last_fetched = %s,
            last_inserted = %s,
            total_runs = total_runs + 1,
            total_inserted = total_inserted + %s,
            updated_at = NOW()
        WHERE query_id = %s;
    """, (interval, streak, now, now + timedelta(hours=interval), fetched, inserted, inserted, due.template.query_id))
    return interval
