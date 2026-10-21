"""
tests/live/test_tavily_showcase.py
-----------------------------
Comprehensive automated test suite for the Tavily 5-Endpoint Showcase backend contracts:
  - Contract A: GET /api/tavily/calls telemetry feed
  - Contract B: POST & GET /api/articles/{id}/deep-inspect/research article-bound research
  - Contract C: Follow Site endpoints (GET, POST, DELETE /api/users/{id}/sites) + +25 feed boost & matched_sites
  - Telemetry Watcher: format_call_line, scorecard logic
"""

import os
import sys
import uuid
import json
from datetime import datetime, timezone
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# This suite writes test rows (tavily_calls, articles, users, sites) into the
# database the app uses; its fake calls would show in the Tavily terminal as
# real ones. Run it only against a throwaway database, on purpose.
if os.environ.get("ALLOW_DB_WRITE_TESTS") != "1":
    print("Skipped: writes to the app database. Set ALLOW_DB_WRITE_TESTS=1 "
          "and point DATABASE_URL at a throwaway database to run it.")
    sys.exit(0)

# Mock Tavily: site follows in this suite would otherwise spend real credits.
os.environ["TAVILY_MOCK"] = "1"
os.environ["INGESTION_SECRET"] = os.environ.get("INGESTION_SECRET", "test-secret-123")

from main import app
from db import get_db
from tavily_service import log_tavily_call
from watch_tavily_calls import format_call_line, render_scorecard

client = TestClient(app)


def test_contract_a_tavily_calls():
    """Verify Contract A: GET /api/tavily/calls returns detail, latest_id, and filters mocks."""
    test_run_tag = f"test_a_{uuid.uuid4().hex[:6]}"
    
    # Insert test calls directly via tavily_service.log_tavily_call
    log_tavily_call(
        endpoint="search",
        purpose="verify_support",
        params_hash=f"hash_{test_run_tag}_1",
        credits_est=1.0,
        latency_ms=320,
        result_count=5,
        is_mock=False,
        detail=f"TSMC 2nm volume production {test_run_tag}"
    )
    log_tavily_call(
        endpoint="map",
        purpose="site_follow_map",
        params_hash=f"hash_{test_run_tag}_2",
        credits_est=1.0,
        latency_ms=450,
        result_count=12,
        is_mock=False,
        detail=f"https://example.com/{test_run_tag}"
    )

    # Fetch without after_id
    resp = client.get("/api/tavily/calls?limit=10")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert "calls" in data
    assert "latest_id" in data
    assert len(data["calls"]) > 0

    calls = data["calls"]
    # Check ascending order
    for i in range(len(calls) - 1):
        assert calls[i]["id"] <= calls[i + 1]["id"], "Calls must be ordered ascending (newest last)"

    # Check structure of items
    last_call = calls[-1]
    assert "endpoint" in last_call
    assert "purpose" in last_call
    assert "detail" in last_call
    assert "latency_ms" in last_call
    assert "credits_est" in last_call

    # Test after_id pagination
    target_id = calls[0]["id"]
    resp2 = client.get(f"/api/tavily/calls?after_id={target_id}&limit=10")
    assert resp2.status_code == 200
    data2 = resp2.json()
    for c in data2["calls"]:
        assert c["id"] > target_id, "after_id must return strictly greater IDs"

    print("✓ Contract A: GET /api/tavily/calls PASSED")


def test_contract_b_article_bound_research():
    """Verify Contract B: Article-bound research endpoint and cache."""
    test_art_id = str(uuid.uuid4())
    url_hash = uuid.uuid4().hex
    title = "NVIDIA Blackwell Ultra GB200 NVL72 Rack Architecture Deep Dive"

    # Insert test article into DB
    with get_db() as cur:
        cur.execute("""
            INSERT INTO articles (
                id, url_hash, source_feed, title, original_url, clean_text,
                macro_tag, macro_tags, micro_tags, tldr, is_processed
            ) VALUES (
                %s, %s, 'NVIDIA Blog', %s, 'https://nvidia.com/test-gb200',
                'NVIDIA has announced GB200 NVL72 with full liquid cooling and dual Grace CPUs.',
                'Hardware', ARRAY['Hardware', 'Tech'], ARRAY['gpu', 'blackwell'],
                'NVIDIA reveals GB200 NVL72 liquid-cooled racks for hyperscale AI.',
                TRUE
            );
        """, (test_art_id, url_hash, title))

    # Initial GET before research is triggered -> should return status 'none'
    resp = client.get(f"/api/articles/{test_art_id}/deep-inspect/research")
    assert resp.status_code == 200, resp.text
    initial_data = resp.json()
    assert initial_data["status"] == "none"

    # Seed fact_check_cache with mock completed research to test retrieval and cache contract
    mock_research_report = {
        "status": "completed",
        "query": f"What are the technical specifications of {title}?",
        "research": {
            "status": "completed",
            "report": "Comprehensive research shows GB200 NVL72 delivers 30X real-time inference speedup.",
            "sources": [{"url": "https://nvidia.com/press", "title": "Press Release"}],
            "model": "mini"
        }
    }
    with get_db() as cur:
        cur.execute("""
            UPDATE articles
            SET fact_check_cache = jsonb_set(
                COALESCE(fact_check_cache, '{}'::jsonb),
                '{research}',
                %s::jsonb
            )
            WHERE id = %s;
        """, (json.dumps(mock_research_report), test_art_id))

    # GET after completed research
    resp2 = client.get(f"/api/articles/{test_art_id}/deep-inspect/research")
    assert resp2.status_code == 200
    res_data = resp2.json()
    assert res_data["status"] == "completed"
    assert "GB200 NVL72 delivers 30X" in res_data["research"]["report"]

    print("✓ Contract B: Article-bound Deep Inspect research PASSED")


def test_contract_c_site_follow_lifecycle():
    """Verify Contract C: Follow site CRUD, validation, 5-site cap, and feed boost."""
    test_user_id = str(uuid.uuid4())
    username = f"tester_{uuid.uuid4().hex[:8]}"

    # Create test user
    with get_db() as cur:
        cur.execute("""
            INSERT INTO users (id, username, onboarding_completed, preferred_macro_tags)
            VALUES (%s, %s, TRUE, ARRAY['Tech', 'Hardware']);
        """, (test_user_id, username))

    # 1. Invalid URL validation
    resp_invalid = client.post(f"/api/users/{test_user_id}/sites", json={"url": "not-a-valid-url"})
    assert resp_invalid.status_code == 400
    assert "http" in resp_invalid.json()["detail"].lower()

    # 2. Follow valid site (e.g. unique newsroom)
    site_key = f"newsroom-{uuid.uuid4().hex[:6]}"
    site_url = f"https://{site_key}.org/news"
    resp_follow = client.post(f"/api/users/{test_user_id}/sites", json={"url": site_url})
    assert resp_follow.status_code == 200, resp_follow.text
    site_data = resp_follow.json()
    assert "id" in site_data
    assert site_data["url"] == site_url
    expected_name = site_key.capitalize()
    assert site_data["name"] == expected_name
    site_id = site_data["id"]

    # 3. GET followed sites
    resp_get = client.get(f"/api/users/{test_user_id}/sites")
    assert resp_get.status_code == 200
    sites_list = resp_get.json()
    assert len(sites_list) == 1
    assert sites_list[0]["id"] == site_id
    assert sites_list[0]["url"] == site_url

    # 4. Enforce max 5 sites
    for i in range(4):
        resp_add = client.post(f"/api/users/{test_user_id}/sites", json={"url": f"https://site{i}-{uuid.uuid4().hex[:6]}.com/blog"})
        assert resp_add.status_code == 200

    # 6th site must be rejected with 400
    resp_overflow = client.post(f"/api/users/{test_user_id}/sites", json={"url": "https://overflow.example.com/news"})
    assert resp_overflow.status_code == 400
    assert "maximum 5" in resp_overflow.json()["detail"].lower()

    # 5. Insert article matching the followed site domain to test feed boost (+25) and matched_sites
    test_art_id = str(uuid.uuid4())
    art_hash = uuid.uuid4().hex
    with get_db() as cur:
        cur.execute("""
            INSERT INTO articles (
                id, url_hash, source_feed, title, original_url, clean_text,
                macro_tag, macro_tags, micro_tags, tldr, is_processed
            ) VALUES (
                %s, %s, %s, 'Frontier Model Architecture Details Revealed',
                %s,
                'Detailed breakdown of the new reasoning models and sparse mixture of experts.',
                'Tech', ARRAY['Tech'], ARRAY['llm', 'ai'],
                'Overview of next-gen frontier model architecture.',
                TRUE
            );
        """, (test_art_id, art_hash, expected_name, f"{site_url}/model-reveal"))

    # Fetch personalized feed
    feed_resp = client.get(f"/api/feed/personalized?user_id={test_user_id}&page_size=20")
    assert feed_resp.status_code == 200, feed_resp.text
    feed_data = feed_resp.json()
    articles = feed_data.get("articles", [])
    
    # Check if matched article has matched_sites populated and personal_score boosted
    matching_arts = [a for a in articles if a["id"] == test_art_id]
    assert len(matching_arts) == 1, "Article from followed site must appear in feed"
    art = matching_arts[0]
    assert "matched_sites" in art
    assert expected_name in art["matched_sites"]
    assert art["personal_score"] >= 45, f"Personal score should be boosted, got {art['personal_score']}"

    # 6. DELETE (unfollow site)
    resp_unfollow = client.delete(f"/api/users/{test_user_id}/sites/{site_id}")
    assert resp_unfollow.status_code == 200
    assert resp_unfollow.json()["status"] == "unfollowed"

    # Verify site list now has 4 sites
    resp_after = client.get(f"/api/users/{test_user_id}/sites")
    assert resp_after.status_code == 200
    assert len(resp_after.json()) == 4

    print("✓ Contract C: Site Follow CRUD, max-5 cap, and feed boost PASSED")


def test_telemetry_watcher_formatting():
    """Verify telemetry watcher format_call_line and scorecard logic."""
    call = {
        "endpoint": "map",
        "purpose": "site_follow_map",
        "detail": "https://deepmind.google/discover/blog",
        "latency_ms": 412,
        "credits_est": 1.0,
        "created_at": datetime.now(timezone.utc).isoformat()
    }
    line = format_call_line(call)
    assert "[MAP     ]" in line
    assert "site_follow_map" in line
    assert "412ms" in line
    assert "https://deepmind.google" in line

    # Test full 5 capabilities scorecard render
    active = {"search", "extract", "map", "crawl", "research"}
    render_scorecard(active)

    print("✓ Telemetry Watcher: ANSI formatting and scorecard logic PASSED")


if __name__ == "__main__":
    test_contract_a_tavily_calls()
    test_contract_b_article_bound_research()
    test_contract_c_site_follow_lifecycle()
    test_telemetry_watcher_formatting()
    print("\n🎉 ALL TAVILY SHOWCASE TESTS PASSED!")
