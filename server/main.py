"""
WeOwnFeed (WOF) — primary FastAPI API gateway.

Modularized into domain-specific APIRouter packages under `routers/`:
  - routers.articles      : Feed retrieval, article detail, HMAC ingestion
  - routers.search        : 3-Tier Hybrid RRF search & Live Web Horizon
  - routers.intelligence  : Grounded Copilot SSE, Multi-Source Synthesis SSE,
                            Daily Digest, Verifiable Evidence Receipts & Tavily Ops
  - routers.users         : User onboarding, preferences, EMA interactions & personalized feed
  - routers.comments      : Contextual paragraph annotations & taxonomy dictionary
  - routers.latest        : Home page "Latest developments" card (per-user headline + paragraph)
  - routers.wai           : WAI assistant chats (story / latest developments / area), model writes the opening
"""

import os
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

load_dotenv()

from routers import (
    articles_router,
    auth_router,
    comments_router,
    follows_router,
    ingestion_router,
    intelligence_router,
    latest_router,
    search_router,
    users_router,
    wai_router,
)

# Re-export core helpers for backward compatibility with direct test imports
from routers.deps import INGESTION_SECRET, parse_vector, validate_uuid
from routers.intelligence import (
    _compute_deterministic_cluster_id,
    _upsert_story_cluster,
    prepare_synthesis_context,
)
from routers.search import execute_hybrid_search, natural_search
from routers.users import get_personalized_feed_data


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Run PostgreSQL schema migrations on startup
    try:
        from migrate_v1_tables import run_migration
        run_migration()
    except Exception as e:
        import logging
        logging.getLogger("main").warning("Postgres migration note: %s", e)
    yield


app = FastAPI(title="WeOwnFeed API", lifespan=lifespan)

# Browsers may call the API only from these web app origins (comma separated,
# e.g. "https://weownfeed.vercel.app"). Unset: local development on any
# localhost / 127.0.0.1 port. Auth uses bearer tokens, not cookies.
_cors_origins = [o.strip().rstrip("/") for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_origin_regex=None if _cors_origins else r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    # bypass-tunnel-reminder: sent by the app to skip the localtunnel warning page.
    allow_headers=["Authorization", "Content-Type", "Accept", "bypass-tunnel-reminder"],
)

# Register domain routers
app.include_router(auth_router)
app.include_router(articles_router)
app.include_router(search_router)
app.include_router(intelligence_router)
app.include_router(users_router)
app.include_router(comments_router)
app.include_router(follows_router)
app.include_router(ingestion_router)
app.include_router(latest_router)
app.include_router(wai_router)

__all__ = [
    "app",
    "INGESTION_SECRET",
    "parse_vector",
    "validate_uuid",
    "execute_hybrid_search",
    "natural_search",
    "_compute_deterministic_cluster_id",
    "_upsert_story_cluster",
    "prepare_synthesis_context",
    "get_personalized_feed_data",
]

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        proxy_headers=True,
        forwarded_allow_ips=os.getenv("FORWARDED_ALLOW_IPS", "127.0.0.1")
    )
