"""Offline settings for the pytest suite.

The modules call load_dotenv(), which never overrides variables that are
already set. Setting them here first means a developer's real server/.env is
never used by the tests: no paid API call, no write to a real database.
Tests that exercise Tavily or the models mock them themselves.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ.update({
    "INGESTION_SECRET": "test-secret",
    "DATABASE_URL": "postgresql://test:test@127.0.0.1:1/test",
    # Nothing listens on port 9 (discard): an unmocked model call fails fast.
    "AI_BASE_URL": "http://127.0.0.1:9/v1",
    "AI_API_KEY": "test-key",
    "FAST_MODEL": "fast-test-model",
    "REASONING_MODEL": "reasoning-test-model",
    "TAVILY_API_KEY": "",
    "TAVILY_API_KEYS": "",
})
