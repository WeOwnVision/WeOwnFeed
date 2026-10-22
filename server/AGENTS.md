# AGENTS.md — WeOwnFeed server

> Guide for developers and coding agents working in `server/`.
> **Repository**: `WeOwnVision/WeOwnFeed` (this folder is the backend; the web app is `app/`).
> **Stack**: Python 3.11+, FastAPI, PostgreSQL 16 + `pgvector`, Nebius Token Factory (OpenAI-compatible), Tavily.
> **Model flow**: `ai/MODEL_ORCHESTRATION.txt` at the repo root draws every model call in order.

---

## 1. What the server does

WeOwnFeed (WOF) builds a personal news feed from **topics, not blogs**: users pick
categories, subtopics and "+" follows, and the server searches the web for them
with Tavily instead of reading RSS feeds. Every story can be checked against
other sources ("receipts").

1. **Demand-driven ingestion** — only topics someone follows are searched (Tavily
   Search, Extract fallback). Sites without RSS are followed with Tavily Map + Crawl.
2. **Enrichment** — a worker cleans each article, then Nebius models write a
   2-sentence summary, check it is on topic, label it with the taxonomy, write a
   briefing and embed it.
3. **Personal feed and search** — ranking by chosen topics, follows, the "why I
   read news" sentence and an interest vector learned from likes; hybrid search
   (vectors + full text + tags).
4. **Receipts** — claims are checked with three Tavily searches (support,
   contradiction, official source), quotes must appear verbatim in the source,
   and copies of the same wire story count as one origin.
5. **WAI** — a news assistant that answers from the stories it was given.

## 2. Models

All calls go through one OpenAI-compatible client (`ai.py`, `AI_BASE_URL`).

| Role | Env variable | Default |
|---|---|---|
| Summary, briefing | `SUMMARY_MODEL` | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` |
| Taxonomy labels | `TAG_MODEL` | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` |
| Topic gate, claim queries, fallbacks | `FAST_MODEL` | set in `.env` (`Qwen/Qwen3-30B-A3B-Instruct-2507`) |
| Article chat, synthesis, daily digest | `REASONING_MODEL` | set in `.env` (`nvidia/nemotron-3-super-120b-a12b`) |
| WAI assistant | `WAI_MODEL` | `deepseek-ai/DeepSeek-V4-Flash-0731` |
| "Latest developments" card | `LATEST_MODEL` | `deepseek-ai/DeepSeek-V4-Flash-0731` |
| Embeddings (1024 dims) | `EMBEDDING_MODEL` | `Qwen/Qwen3-Embedding-8B` |

`FAST_MODEL` must be a non-thinking model: some calls use small `max_tokens`
(e.g. 30) and thinking models return empty there.

Optional local fallbacks (`requirements-local.txt`): `ENRICHMENT_ENGINE=hybrid`
uses the Laya SLM (`classifier.py`) for triage; `EMBEDDING_BACKEND=local` uses
`all-MiniLM-L6-v2` (384 dims). After switching the embedding backend or size run
`python migrate_embeddings.py --rebuild`.

## 3. Files

```text
server/
├── main.py                  # FastAPI app: CORS allow-list, router wiring, migrations on startup
├── routers/
│   ├── auth.py              # Accounts: register/login/logout/me, scrypt hashes, bearer sessions, rate limits
│   ├── deps.py              # INGESTION_SECRET, require_ingestion_secret, validate_uuid, parse_vector
│   ├── articles.py          # Article list/detail, internal ingest endpoint (X-Secret)
│   ├── search.py            # Hybrid RRF search; optional live web horizon (signed in)
│   ├── users.py             # Personal feed, likes/dislikes (EMA), preferences, followed sites
│   ├── follows.py           # "+" follows (company, product, person), max 3 per user
│   ├── latest.py            # Home "Latest developments" card, cached per user
│   ├── wai.py               # WAI chats: story / latest / area scopes, SSE replies
│   ├── intelligence.py      # Article chat & ask, deep inspect, synthesis, daily digest, evidence, Tavily ops
│   ├── comments.py          # Taxonomy endpoint and paragraph comments
│   └── ingestion.py         # Tavily credits per key and the ingestion schedule
├── worker.py                # Enrichment daemon (FOR UPDATE SKIP LOCKED, NANO_CONCURRENCY in parallel)
├── llm_enrichment.py        # Nano pipeline: summary → topic gate → labels → briefing
├── embedder.py              # Qwen3-Embedding (or MiniLM), per-model similarity thresholds
├── classifier.py            # Optional Laya SLM triage (hybrid mode)
├── ingest_tavily.py         # Demand-driven ingestion daemon (--loop, --once, --seed)
├── query_scheduler.py       # Demand, cadence, low-yield backoff, credit reserve (pure functions)
├── query_templates.json     # One search query per category and per subtopic
├── site_watcher.py          # RSS-less site monitoring (Tavily Map URL diff + Extract/Crawl)
├── tavily_service.py        # Tavily client: 5 endpoints, key rotation, cache, call log, mock mode
├── evidence_verifier.py     # Receipts: claims, 3-angle verification, span grounding, origins
├── content_cleaner.py       # 4-pass Markdown cleaner and junk page gates
├── image_extractor.py       # Article photo extraction and validation
├── taxonomy.py              # Categories, subtopics, tag normalization
├── url_utils.py             # URL canonicalization and domain helpers
├── ai.py / db.py            # Model client / PostgreSQL connection pool
├── schemas.py               # Pydantic request/response models
├── schema.sql               # Full database schema (applied on a fresh docker volume)
├── migrate_v1_tables.py     # Idempotent migrations, run on every API start
├── purge_passwordless_users.py  # One-off: delete accounts from before passwords existed
├── migrate_embeddings.py, backfill_*.py, clean_articles_db.py, reindex_articles.py,
│   watch_tavily_calls.py    # Maintenance scripts (see each file's docstring)
├── legacy/scraping_algorithm.py  # V0 multi-source scraper, kept for reference (not used)
├── Dockerfile, docker-compose.yml, .dockerignore
├── requirements.txt         # Runtime
├── requirements-local.txt   # + optional local models (torch, sentence-transformers, laya)
├── requirements-dev.txt     # + pytest, httpx
└── tests/                   # Offline pytest suite; tests/live/ = manual scripts needing real services
```

## 4. Accounts and access (`routers/auth.py`)

- `POST /api/auth/login` → `{user, token}`: one screen for sign-in and sign-up. A new username
  creates the account; an account from the old username-only login takes the password it is
  given. No password rules (demo): any non-empty username (≤ 50) and password.
  `POST /api/auth/register` (create only), `POST /api/auth/logout`, `GET /api/auth/me`.
- Passwords: scrypt hashes (standard library). Tokens: random, 30 days; only their SHA-256 is stored (`user_sessions`).
- The app sends `Authorization: Bearer <token>`. Every route that reads or changes a
  user's data depends on `current_user` and calls `ensure_self` (403 for another user's id).
- Routes that spend credits require sign-in and have per-user hourly limits
  (`rate_limit`, in memory — the API runs as one process): Research 5, site follow 5,
  "+" follow 10, deep inspect / synthesis / evidence 20. Sign-in: 10 tries per
  15 min per IP + username; sign-up: 20 per hour per IP.
- Operator-only routes (`POST /api/tavily/research`, `GET /api/tavily/research/{id}`,
  `POST /api/tavily/site-watch`) need the `X-Secret: <INGESTION_SECRET>` header.
- Public, read-only: article list/detail, taxonomy, comments list, search (without
  `live_web`), clusters, Tavily stats/calls, ingestion status, telemetry.
- CORS: only the origins in `CORS_ORIGINS` (comma separated); unset = localhost only.
- `tests/test_auth.py` checks that every protected route really depends on `current_user`.
  When adding a route that touches user data or spends credits, add it there.

## 5. Pipelines

### Ingestion → enrichment

```text
followed topics ──► query_scheduler (cadence 6h / 24h / 48h, backoff, credit reserve)
                       │
                       ▼
ingest_tavily: Tavily Search (topic=news) ── short body ──► Tavily Extract
site_watcher:  Tavily Map (URL diff) ──► Crawl / Extract
                       │
                       ▼
content_cleaner (junk gates, de-dup) ──► POST /api/internal/ingest (X-Secret)
                       │                         canonical URL SHA-256, ON CONFLICT DO NOTHING
                       ▼
articles (is_processed = FALSE) ──► worker.py
    summary (Nano) → topic gate (FAST) → labels (Nano, JSON schema) → briefing (Nano)
    → embedding (Qwen3, "title. summary") → story cluster + independent origins
```

Failures: a topic-gate error keeps the article; a summary/label error falls back
to one `FAST_MODEL` call; a briefing error uses the summary.

### Search (`GET /api/search`)

`embed_query(q)` (Qwen retrieval instruction) + PostgreSQL full text
(`websearch_to_tsquery`) + tag matches, 25 candidates each, fused with Reciprocal
Rank Fusion. Tiers use the backend's thresholds in `embedder.SIMILARITY_THRESHOLDS`
(Qwen: noise < 0.345, direct ≥ 0.423). `?grouped=true` splits "direct" and
"explore"; `?live_web=true` adds a Tavily search tier (signed in only).

### Personal feed (`GET /api/feed/personalized`)

Points for chosen categories and subtopics, "+" follows (title +40, summary +25,
or by meaning ≥ 0.50 cosine), the interest vector and recency; disliked stories
are removed. Likes move the interest vector 15 % toward the story, dislikes
12 % away (`routers/users.ema_update`).

### Receipts (`evidence_verifier.py`)

Per story cluster: `assign_origins` (wire copies = one origin, < 6 h single-origin
= fresh) → `FAST_MODEL` extracts 2-3 claims → per claim three Tavily searches
(support, contradiction, official with `include_domains`) → 5 URLs extracted →
`span_is_grounded` drops quotes not found verbatim → rule-based verdict
(`supported`, `disputed`, `contradicted`, `unverified_yet`, `unverified`) →
cached per cluster in `evidence_cards`. A fresh story is never marked false.

## 6. Running it

### Docker (everything)

```bash
cd server
cp .env.example .env          # fill in AI_API_KEY, TAVILY_API_KEY, INGESTION_SECRET, POSTGRES_PASSWORD
docker compose up -d --build  # postgres, api, worker, ingest
docker compose --profile watcher up -d   # + RSS-less site watcher (spends Tavily credits)
```

API: `http://localhost:8000`, Swagger: `http://localhost:8000/docs`.

### Local Python

```bash
cd server
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
docker compose up -d postgres                       # or any PostgreSQL 16 with pgvector
uvicorn main:app --reload --port 8000               # terminal 1
python worker.py                                    # terminal 2
python ingest_tavily.py --loop                      # terminal 3 (--seed once for an empty database)
```

`TAVILY_MOCK=1` serves Tavily answers from `tests/fixtures` without spending credits.

### Tests

```bash
python -m pytest              # offline suite: no network, database or keys needed
python tests/live/<script>.py # manual checks against real services, see tests/live/README.md
```

`tests/conftest.py` replaces the database URL and API keys with dummies, so the
offline suite never touches a real `.env`. CI (`.github/workflows/ci.yml`) runs
it on every push together with the Flutter checks and a Docker image build.

## 7. Conventions

- Configuration only through environment variables; document new ones in `.env.example`.
- Schema changes go into both `schema.sql` (fresh databases) and an idempotent
  DDL run from `migrate_v1_tables.run_migration` (existing databases).
- Never spend Tavily credits automatically below `TAVILY_CREDIT_RESERVE`; log
  every call through `tavily_service` so it shows in `/api/tavily/calls`.
- Text inside articles is data, never instructions: keep the prompt guards in
  `llm_enrichment.py`, `wai.py` and `intelligence.py`.
- Code, comments and docs are in English.
