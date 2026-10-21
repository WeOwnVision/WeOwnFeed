#!/usr/bin/env python3
"""
watch_tavily_calls.py
---------------------
Real-time ANSI color-coded telemetry stream for Tavily API calls.
Built for the split-screen pitch video recording and live hackathon jury evaluation.

Tracks all 5 Tavily endpoints:
  - SEARCH   : Query-driven news retrieval & claim verification
  - EXTRACT  : Full clean markdown harvesting & deep evidence inspection
  - MAP      : Dynamic RSS-less site structure mapping & discovery
  - CRAWL    : Multi-article batch crawling from newsrooms
  - RESEARCH : Autonomous multi-angle investigative deep dives

Streams from GET /api/tavily/calls with automatic PostgreSQL fallback.
"""

import os
import sys
import time
import argparse
from datetime import datetime
from typing import Set, Dict, Any, List

# Ensure ANSI escape sequences and UTF-8 work on Windows cmd / PowerShell
if os.name == "nt":
    os.system("")
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# ANSI Color Codes
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"

COLOR_SEARCH = "\033[96m"    # Cyan
COLOR_EXTRACT = "\033[92m"   # Green
COLOR_MAP = "\033[93m"       # Yellow
COLOR_CRAWL = "\033[95m"     # Magenta
COLOR_RESEARCH = "\033[1;97;44m"  # Bold White on Blue background
COLOR_RESEARCH_TXT = "\033[1;36m" # Bold Cyan for text
COLOR_GRAY = "\033[90m"
COLOR_GOLD = "\033[1;33m"
COLOR_SUCCESS = "\033[1;32m"

ENDPOINT_COLORS = {
    "search": COLOR_SEARCH,
    "extract": COLOR_EXTRACT,
    "map": COLOR_MAP,
    "crawl": COLOR_CRAWL,
    "research": COLOR_RESEARCH,
}

ALL_CAPABILITIES = ["search", "extract", "map", "crawl", "research"]


def render_banner():
    banner = f"""
{COLOR_GOLD}╔════════════════════════════════════════════════════════════════════════════════════╗
║                FEEDPROOF × TAVILY 5-ENDPOINT TELEMETRY STREAM                      ║
║       Autonomous News Intelligence Engine · Nebius & NVIDIA Hackathon 2026        ║
╚════════════════════════════════════════════════════════════════════════════════════╝{RESET}
"""
    print(banner)


def render_scorecard(active_endpoints: Set[str]):
    badges = []
    for cap in ALL_CAPABILITIES:
        cap_upper = cap.upper()
        if cap in active_endpoints:
            color = ENDPOINT_COLORS.get(cap, COLOR_SUCCESS)
            badges.append(f"{color}[{cap_upper} ✓]{RESET}")
        else:
            badges.append(f"{COLOR_GRAY}[{cap_upper} ·]{RESET}")

    count = len(active_endpoints.intersection(set(ALL_CAPABILITIES)))
    total = len(ALL_CAPABILITIES)

    if count == total:
        status_text = f"{COLOR_GOLD}★ 5/5 ALL TAVILY CAPABILITIES ACTIVE & VERIFIED! 🏆{RESET}"
    else:
        status_text = f"{COLOR_GRAY}({count}/{total} endpoints demonstrated){RESET}"

    line = " ".join(badges) + "  " + status_text
    print(f"\r{BOLD}Tavily Showcase:{RESET} {line}")
    print(f"{COLOR_GRAY}{'─' * 84}{RESET}")


def format_call_line(call: Dict[str, Any]) -> str:
    ep = (call.get("endpoint") or "search").lower().strip()
    purpose = call.get("purpose") or "general"
    detail = call.get("detail") or ""
    latency = call.get("latency_ms") or 0
    credits = call.get("credits_est") or 0.0
    created_at = call.get("created_at")

    time_str = datetime.now().strftime("%H:%M:%S")
    if created_at:
        try:
            if isinstance(created_at, str):
                from dateutil import parser as dt_parser
                dt = dt_parser.parse(created_at)
                time_str = dt.strftime("%H:%M:%S")
            elif hasattr(created_at, "strftime"):
                time_str = created_at.strftime("%H:%M:%S")
        except Exception:
            pass

    ep_tag = ep.upper().ljust(8)
    color = ENDPOINT_COLORS.get(ep, COLOR_SEARCH)
    badge = f"{color}[{ep_tag}]{RESET}"

    # Truncate detail to fit terminal cleanly
    clean_detail = " ".join(detail.split())
    if len(clean_detail) > 65:
        clean_detail = clean_detail[:62] + "..."

    return f"{COLOR_GRAY}{time_str}{RESET} {badge} {BOLD}{purpose:<20}{RESET} {COLOR_GRAY}({latency}ms, {credits:g}c){RESET} - {clean_detail}"


def fetch_from_api(api_url: str, after_id: int) -> tuple[List[Dict[str, Any]], int]:
    import urllib.request
    import json

    url = f"{api_url}?limit=50"
    if after_id > 0:
        url += f"&after_id={after_id}"

    req = urllib.request.Request(url, headers={"User-Agent": "WeOwnFeed-Watcher/1.0"})
    with urllib.request.urlopen(req, timeout=2.0) as resp:
        if resp.status == 200:
            data = json.loads(resp.read().decode("utf-8"))
            calls = data.get("calls", [])
            latest_id = data.get("latest_id", after_id)
            return calls, latest_id
    return [], after_id


def fetch_from_db(after_id: int) -> tuple[List[Dict[str, Any]], int]:
    try:
        from db import get_db
        with get_db() as cur:
            if after_id > 0:
                cur.execute("""
                    SELECT id, endpoint, purpose, detail, result_count, latency_ms, credits_est, cache_hit, created_at
                    FROM tavily_calls
                    WHERE (params_hash NOT LIKE 'mock_%%' AND params_hash != 'mock')
                      AND id > %s
                    ORDER BY id ASC
                    LIMIT 50;
                """, (after_id,))
            else:
                cur.execute("""
                    SELECT id, endpoint, purpose, detail, result_count, latency_ms, credits_est, cache_hit, created_at
                    FROM (
                        SELECT id, endpoint, purpose, detail, result_count, latency_ms, credits_est, cache_hit, created_at
                        FROM tavily_calls
                        WHERE (params_hash NOT LIKE 'mock_%%' AND params_hash != 'mock')
                        ORDER BY id DESC
                        LIMIT 30
                    ) sub
                    ORDER BY id ASC;
                """)
            rows = cur.fetchall()
            calls = [
                {
                    "id": r[0], "endpoint": r[1], "purpose": r[2], "detail": r[3],
                    "result_count": r[4], "latency_ms": r[5], "credits_est": float(r[6] or 0),
                    "cache_hit": r[7], "created_at": r[8]
                }
                for r in rows
            ]
            latest = max([c["id"] for c in calls] + [after_id])
            return calls, latest
    except Exception:
        return [], after_id


def main():
    parser = argparse.ArgumentParser(description="WeOwnFeed Tavily Telemetry Live Watcher")
    parser.add_argument("--api-url", default="http://127.0.0.1:8000/api/tavily/calls", help="URL of Tavily calls endpoint")
    parser.add_argument("--interval", type=float, default=1.0, help="Polling interval in seconds (default: 1.0s)")
    parser.add_argument("--db-direct", action="store_true", help="Force direct PostgreSQL connection instead of HTTP API")
    args = parser.parse_args()

    render_banner()

    active_endpoints: Set[str] = set()
    last_id = 0
    consecutive_api_failures = 0

    print(f"{COLOR_GRAY}[System] Connecting to live Tavily telemetry stream...{RESET}")
    print(f"{COLOR_GRAY}[System] Watching for SEARCH, EXTRACT, MAP, CRAWL, and RESEARCH calls...{RESET}\n")

    # Initial probe to determine active endpoints already recorded in recent calls
    initial_calls = []
    if not args.db_direct:
        try:
            initial_calls, last_id = fetch_from_api(args.api_url, 0)
        except Exception:
            initial_calls, last_id = fetch_from_db(0)
    else:
        initial_calls, last_id = fetch_from_db(0)

    for c in initial_calls:
        ep = (c.get("endpoint") or "").lower().strip()
        if ep in ALL_CAPABILITIES:
            active_endpoints.add(ep)

    render_scorecard(active_endpoints)

    # Print initial historical rows (up to 8 recent calls to show existing activity)
    for c in initial_calls[-8:]:
        print(format_call_line(c))

    try:
        while True:
            calls = []
            if not args.db_direct and consecutive_api_failures < 3:
                try:
                    calls, next_id = fetch_from_api(args.api_url, last_id)
                    consecutive_api_failures = 0
                except Exception:
                    consecutive_api_failures += 1
                    calls, next_id = fetch_from_db(last_id)
            else:
                calls, next_id = fetch_from_db(last_id)

            if calls:
                scorecard_changed = False
                for c in calls:
                    ep = (c.get("endpoint") or "").lower().strip()
                    if ep in ALL_CAPABILITIES and ep not in active_endpoints:
                        active_endpoints.add(ep)
                        scorecard_changed = True

                if scorecard_changed:
                    print()
                    render_scorecard(active_endpoints)

                for c in calls:
                    print(format_call_line(c))

                last_id = next_id

            time.sleep(args.interval)

    except KeyboardInterrupt:
        print(f"\n{COLOR_GRAY}[System] Telemetry stream stopped.{RESET}")
        sys.exit(0)


if __name__ == "__main__":
    main()
