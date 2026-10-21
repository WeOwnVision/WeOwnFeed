"""
migrate_v1_tables.py
--------------------
Safeguard 2: Direct psycopg runner applying V1 database tables idempotently.
Applies:
  - tavily_calls (Tavily Telemetry)
  - watched_sites (RSS-less Site Monitoring)
  - site_discovered_urls (Discovered URLs for diffing)
  - story_clusters (Semantic Story Clustering)
  - evidence_cards (Verifiable Structured Receipts)
  - ingest_query_state (Demand-driven ingestion schedule, see query_scheduler.py)
  - users.interest_context / interest_context_en (optional onboarding context sentence)
  - users.password_hash + user_sessions (accounts, routers/auth.py)
"""

import sys
import logging
from db import get_db
from embedder import embedding_dim

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("migration_v1")

V1_DDL = f"""
-- 1. Tavily Telemetry Tracking
CREATE TABLE IF NOT EXISTS tavily_calls (
    id BIGSERIAL PRIMARY KEY,
    endpoint VARCHAR(50) NOT NULL,
    purpose VARCHAR(50) NOT NULL,
    params_hash VARCHAR(64) NOT NULL,
    credits_est NUMERIC DEFAULT 1,
    latency_ms INT DEFAULT 0,
    result_count INT DEFAULT 0,
    cluster_id UUID,
    cache_hit BOOLEAN DEFAULT FALSE,
    detail TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tavily_calls_created ON tavily_calls (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tavily_calls_endpoint ON tavily_calls (endpoint);

-- 2. RSS-less Site Monitoring
CREATE TABLE IF NOT EXISTS watched_sites (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    site_name VARCHAR(100) NOT NULL,
    root_url TEXT NOT NULL UNIQUE,
    select_paths TEXT[] DEFAULT ARRAY['/news/.*', '/press/.*', '/blog/.*'],
    last_mapped_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    status VARCHAR(20) DEFAULT 'pending',
    article_count INT DEFAULT 0,
    last_checked_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_watched_sites (
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    site_id UUID REFERENCES watched_sites(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (user_id, site_id)
);
CREATE INDEX IF NOT EXISTS idx_user_watched_sites_user ON user_watched_sites (user_id);
CREATE INDEX IF NOT EXISTS idx_user_watched_sites_site ON user_watched_sites (site_id);

CREATE TABLE IF NOT EXISTS site_discovered_urls (
    id BIGSERIAL PRIMARY KEY,
    site_id UUID REFERENCES watched_sites(id) ON DELETE CASCADE,
    url_canonical TEXT NOT NULL,
    first_seen TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_ingested BOOLEAN DEFAULT FALSE,
    UNIQUE (site_id, url_canonical)
);
CREATE INDEX IF NOT EXISTS idx_site_discovered_canonical ON site_discovered_urls (url_canonical);

-- 3. Semantic Story Clusters
CREATE TABLE IF NOT EXISTS story_clusters (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    macro_tag VARCHAR(50) NOT NULL,
    cluster_title TEXT NOT NULL,
    centroid_embedding vector({embedding_dim()}),
    article_ids UUID[] NOT NULL,
    independent_origins_count INT DEFAULT 1,
    origin_breakdown JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_story_clusters_macro ON story_clusters (macro_tag, created_at DESC);

-- 4. Verifiable Evidence Cards ("Receipts")
CREATE TABLE IF NOT EXISTS evidence_cards (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    cluster_id UUID REFERENCES story_clusters(id) ON DELETE CASCADE UNIQUE,
    claims JSONB NOT NULL DEFAULT '[]'::jsonb,
    summary_verdict VARCHAR(50) NOT NULL,
    independent_origins INT DEFAULT 1,
    total_sources INT DEFAULT 1,
    raw_evidence_citations JSONB DEFAULT '[]'::jsonb,
    tavily_telemetry JSONB DEFAULT '{{}}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Articles Worker Reliability & Error Tracking
ALTER TABLE articles ADD COLUMN IF NOT EXISTS error_message TEXT;
ALTER TABLE articles ADD COLUMN IF NOT EXISTS retry_count INT DEFAULT 0;
ALTER TABLE articles ADD COLUMN IF NOT EXISTS fact_check_cache JSONB;

-- 6. Article cover images (also in schema.sql; existing databases need them here)
ALTER TABLE articles ADD COLUMN IF NOT EXISTS image_url TEXT;
ALTER TABLE articles ADD COLUMN IF NOT EXISTS image_status VARCHAR(50);

-- 7. Tavily 5-Endpoint Telemetry & Watched Sites Expansions
ALTER TABLE tavily_calls ADD COLUMN IF NOT EXISTS detail TEXT;
ALTER TABLE watched_sites ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'pending';
ALTER TABLE watched_sites ADD COLUMN IF NOT EXISTS article_count INT DEFAULT 0;
ALTER TABLE watched_sites ADD COLUMN IF NOT EXISTS last_checked_at TIMESTAMP WITH TIME ZONE;
"""

def sanitize_and_prewarm_db() -> None:
    """
    Idempotent startup data sanitizer and pre-warmer:
      1. Purges unit-test 'mock_%' rows from tavily_calls when TAVILY_MOCK=0.
      2. Marks Benchmark News / Facebook stubs as Off-Topic.
      3. Applies refine_macro_classification across processed articles to eliminate cross-domain tag leakage.
      4. Purges legacy 1-line stub or misclassified rows from daily_intelligence_digests.
      5. Ensures story_clusters has coverage across all 7 macro categories.
      6. Ensures watched_sites and site_discovered_urls are initialized.
    """
    import os
    import json
    import uuid
    from taxonomy import (
        refine_macro_classification,
        extract_domain_keywords,
        clean_micro_tags,
        get_subtags_for_macro,
        MACRO_CATEGORIES,
    )
    from evidence_verifier import assign_origins

    with get_db() as cur:
        if os.getenv("TAVILY_MOCK", "0").lower() not in ("1", "true"):
            cur.execute("DELETE FROM tavily_calls WHERE params_hash LIKE 'mock_%';")

        cur.execute("""
            UPDATE articles 
            SET macro_tag = 'Off-Topic', macro_tags = ARRAY['Off-Topic'] 
            WHERE (source_feed ILIKE '%facebook.com%' OR source_feed ILIKE '%Benchmark News%')
              AND (macro_tag IS NULL OR macro_tag != 'Off-Topic');
        """)

        cur.execute("""
            SELECT id, title, clean_text, tldr
            FROM articles
            WHERE is_processed = TRUE AND (macro_tag IS NULL OR embedding IS NULL);
        """)
        untagged_rows = cur.fetchall()
        if untagged_rows:
            from embedder import get_embedder
            emb_engine = get_embedder()
            for aid, title, ctext, tldr in untagged_rows:
                p_mac, m_arr = refine_macro_classification(title, ctext or "", "Tech", ["Tech"])
                kws = extract_domain_keywords(title, ctext or "")
                valid_subs = list(get_subtags_for_macro(p_mac).keys())
                mics = clean_micro_tags(kws + valid_subs[:3], max_tags=5)
                safe_tldr = tldr or f"{title}. {(ctext or '')[:180].strip()}."
                vec = emb_engine.embed_text(f"{title}. {safe_tldr}")
                cur.execute("""
                    UPDATE articles
                    SET macro_tag = COALESCE(macro_tag, %s),
                        macro_tags = COALESCE(macro_tags, %s),
                        micro_tags = COALESCE(micro_tags, %s),
                        tldr = COALESCE(tldr, %s),
                        embedding = COALESCE(embedding, %s::vector),
                        on_topic_score = COALESCE(on_topic_score, 0.85),
                        confidence_score = COALESCE(confidence_score, 0.80)
                    WHERE id = %s;
                """, (p_mac, m_arr, mics, safe_tldr, vec, aid))

        cur.execute("""
            SELECT id, title, clean_text, macro_tag, macro_tags, micro_tags 
            FROM articles 
            WHERE is_processed = TRUE AND macro_tag IS NOT NULL AND macro_tag != 'Off-Topic';
        """)
        for aid, title, ctext, m_tag, m_tags_arr, mic_arr in cur.fetchall():
            new_p, new_arr = refine_macro_classification(title, ctext or "", m_tag, m_tags_arr)
            new_mics = list(mic_arr or [])
            if new_p != m_tag or not new_mics:
                kws = extract_domain_keywords(title, ctext or "")
                valid_subs = set(get_subtags_for_macro(new_p).keys())
                kept = [t for t in new_mics if t in valid_subs or t in kws]
                for s in list(valid_subs)[:2]:
                    if s not in kept:
                        kept.append(s)
                new_mics = clean_micro_tags(kws + kept, max_tags=6)
            if new_p != m_tag or new_arr != (m_tags_arr or []) or new_mics != (mic_arr or []):
                cur.execute(
                    "UPDATE articles SET macro_tag = %s, macro_tags = %s, micro_tags = %s WHERE id = %s;",
                    (new_p, new_arr, new_mics, aid),
                )

        # Remove legacy 1-line stub digests or digests containing YouTube/social citations
        cur.execute("""
            DELETE FROM daily_intelligence_digests
            WHERE LENGTH(COALESCE(synthesis_markdown, '')) < 120
               OR synthesis_markdown LIKE 'Daily consensus summary:%'
               OR cluster_title ILIKE '%Tavily Demo%'
               OR tavily_evidence::text ILIKE '%youtube.com%'
               OR (macro_tag = 'Gaming' AND cluster_title ILIKE '%Tesla%');
        """)
        cur.execute("""
            DELETE FROM evidence_cards
            WHERE raw_evidence_citations::text ILIKE '%youtube.com%'
               OR raw_evidence_citations::text ILIKE '%facebook.com%';
        """)

        # Ensure story_clusters has at least 1 cluster per populated macro category
        for mac in MACRO_CATEGORIES:
            cur.execute("SELECT COUNT(*) FROM story_clusters WHERE macro_tag = %s;", (mac,))
            if (cur.fetchone() or [0])[0] > 0:
                continue
            cur.execute("""
                SELECT id, title, tldr, clean_text, original_url, published_at, embedding
                FROM articles
                WHERE is_processed = TRUE AND macro_tag = %s AND embedding IS NOT NULL
                ORDER BY published_at DESC LIMIT 2;
            """, (mac,))
            rows = cur.fetchall()
            if not rows:
                continue
            c_ids = [str(r[0]) for r in rows]
            sorted_k = ",".join(sorted(x.lower() for x in c_ids))
            det_cid = str(uuid.uuid5(uuid.NAMESPACE_OID, sorted_k))
            o_docs = [
                {"id": str(r[0]), "title": r[1], "tldr": r[2] or "", "text": r[3] or "", "url": r[4], "published_at": r[5]}
                for r in rows
            ]
            o_info = assign_origins(o_docs)
            c_title = f"{mac} Intelligence Consensus: {rows[0][1][:65]}"
            cur.execute("""
                INSERT INTO story_clusters (id, macro_tag, cluster_title, centroid_embedding, article_ids, independent_origins_count, origin_breakdown, updated_at)
                VALUES (%s, %s, %s, %s::vector, %s::uuid[], %s, %s::jsonb, NOW())
                ON CONFLICT (id) DO NOTHING;
            """, (det_cid, mac, c_title, rows[0][6], c_ids, o_info["independent_origins_count"], json.dumps(o_info["origins"])))


def run_migration() -> bool:
    logger.info("Executing V1 Database Migration & Self-Healing Sanitization...")
    try:
        with get_db() as cur:
            cur.execute(V1_DDL)
            # Demand-driven ingestion schedule (query_templates.json) and "+" follows
            from query_scheduler import STATE_DDL, FOLLOWS_DDL, CREDIT_DDL
            cur.execute(STATE_DDL)
            cur.execute(FOLLOWS_DDL)
            cur.execute(CREDIT_DDL)
            # Optional onboarding context sentence (routers/users.py)
            from routers.users import CONTEXT_DDL
            cur.execute(CONTEXT_DDL)
            # Home page "Latest developments" card cache (routers/latest.py)
            from routers.latest import LATEST_DDL
            cur.execute(LATEST_DDL)
            # Accounts: password hashes and session tokens (routers/auth.py)
            from routers.auth import AUTH_DDL
            cur.execute(AUTH_DDL)
        sanitize_and_prewarm_db()
        logger.info("✓ V1 Database Tables, Indexes & Taxonomy Sanitization verified.")
        return True
    except Exception as e:
        logger.warning("Migration failed (database may be offline or initializing): %s", e)
        return False


if __name__ == "__main__":
    success = run_migration()
    sys.exit(0 if success else 1)

