# Live checks

Scripts here are not part of the automated test suite. Each one needs at least
one of: a running API (`http://localhost:8000`), a PostgreSQL database, real
Nebius / Tavily keys, or the optional local models (`requirements-local.txt`).
Some write to the database or spend API credits.

Run them by hand from `server/`, for example:

```bash
uvicorn main:app --port 8000          # in another terminal
python tests/live/test_live_endpoints.py
```

| Script | Needs |
|---|---|
| `comprehensive_test_evaluation.py` | running API, data in the database |
| `test_copilot_demo.py` | running API, Nebius key |
| `test_live_endpoints.py` | running API |
| `test_search_suite.py` | running API |
| `test_search_speed.py` | database |
| `test_seed.py` | running API, `INGESTION_SECRET`; writes articles |
| `test_user_personalization.py` | running API, database; creates a user |
| `test_tavily_showcase.py` | `ALLOW_DB_WRITE_TESTS=1` and a throwaway database |
| `test_hybrid_enrichment.py` | local Laya model (`requirements-local.txt`) |
