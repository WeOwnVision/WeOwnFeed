"""
Ingestion status: Tavily credits per API key and the demand-driven schedule.
Useful as a live "how are we spending Tavily" panel (no credits spent).
"""
import os

from fastapi import APIRouter

from db import get_db
import query_scheduler
from tavily_service import configured_keys

router = APIRouter(tags=["Ingestion"])


@router.get("/api/ingestion/status")
def ingestion_status():
    with get_db() as cur:
        query_scheduler.ensure_state_table(cur)
        keys = query_scheduler.key_credit_status(cur, configured_keys())
        cur.execute("""
            SELECT query_id, kind, query, followers, interval_hours, last_run_at, next_run_at,
                   last_inserted, total_runs, total_inserted
            FROM ingest_query_state
            WHERE followers > 0
            ORDER BY next_run_at NULLS FIRST, query_id;
        """)
        schedule = [
            {
                "query_id": r[0], "kind": r[1], "query": r[2], "followers": r[3],
                "interval_hours": r[4], "last_run_at": r[5], "next_run_at": r[6],
                "last_inserted": r[7], "total_runs": r[8], "total_inserted": r[9],
            }
            for r in cur.fetchall()
        ]
    return {
        "credit_reserve": int(os.getenv("TAVILY_CREDIT_RESERVE", "150")),
        "credits_remaining": query_scheduler.total_remaining(keys),
        "keys": keys,
        "active_queries": len(schedule),
        "schedule": schedule,
    }
