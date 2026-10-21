from routers.articles import router as articles_router
from routers.auth import router as auth_router
from routers.search import router as search_router
from routers.intelligence import router as intelligence_router
from routers.users import router as users_router
from routers.comments import router as comments_router
from routers.follows import router as follows_router
from routers.ingestion import router as ingestion_router
from routers.latest import router as latest_router
from routers.wai import router as wai_router

__all__ = [
    "articles_router",
    "auth_router",
    "search_router",
    "intelligence_router",
    "users_router",
    "comments_router",
    "follows_router",
    "ingestion_router",
    "latest_router",
    "wai_router",
]
