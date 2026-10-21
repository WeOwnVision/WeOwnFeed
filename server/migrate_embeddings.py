"""Embedding maintenance.

  python migrate_embeddings.py            # embed articles that have no vector yet
  python migrate_embeddings.py --rebuild  # after changing EMBEDDING_BACKEND / EMBEDDING_DIM

--rebuild resizes every vector column to the configured size (embedder.embedding_dim())
and re-embeds everything: articles, story cluster centroids, "+" follows, and user
interest vectors (each user's starting sentence, then their likes/dislikes replayed in
order, so learned interests survive the model change).
"""

import argparse
import time
import logging
from db import get_db
from embedder import embedding_dim, get_embedder

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("migrate_embeddings")
logging.getLogger("httpx").setLevel(logging.WARNING)

# (table, column) pairs that hold embedding vectors.
VECTOR_COLUMNS = [
    ("articles", "embedding"),
    ("users", "interest_embedding"),
    ("user_follows", "embedding"),
    ("story_clusters", "centroid_embedding"),
]


def _article_text(title: str, tldr: str, clean_text: str) -> str:
    return f"{title}. {tldr if tldr else (clean_text or '')[:300]}"


def _column_dim(cur, table: str, column: str):
    """Declared vector size of table.column; None when the table/column does not exist."""
    cur.execute("""
        SELECT a.atttypmod FROM pg_attribute a
        WHERE a.attrelid = to_regclass(%s) AND a.attname = %s AND NOT a.attisdropped;
    """, (table, column))
    row = cur.fetchone()
    return row[0] if row else None


def embed_articles(only_missing: bool) -> int:
    embedder = get_embedder()
    with get_db() as cur:
        cur.execute(f"""
            SELECT id, title, tldr, clean_text FROM articles
            {"WHERE embedding IS NULL" if only_missing else ""}
            ORDER BY created_at ASC;
        """)
        rows = cur.fetchall()
    logger.info("Embedding %d articles with %s (%d dimensions)...", len(rows), embedder.model_name, embedder.dim)
    t0 = time.perf_counter()
    batch = 64
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        vectors = embedder.embed_batch([_article_text(r[1], r[2], r[3]) for r in chunk])
        with get_db() as cur:
            for (art_id, *_), vec in zip(chunk, vectors):
                cur.execute("UPDATE articles SET embedding = %s::vector WHERE id = %s;", (str(vec), art_id))
        logger.info("[%d/%d] articles embedded", min(i + batch, len(rows)), len(rows))
    if rows:
        logger.info("Articles done in %.1fs.", time.perf_counter() - t0)
    return len(rows)


def rebuild() -> None:
    import numpy as np
    from routers.deps import parse_vector
    from routers.users import _standard_interest_text, ema_update

    dim = embedding_dim()
    embedder = get_embedder()

    # 1. Resize vector columns (contents dropped; refilled below).
    with get_db() as cur:
        for table, column in VECTOR_COLUMNS:
            current = _column_dim(cur, table, column)
            if current is None:
                logger.info("%s.%s does not exist; skipped.", table, column)
            elif current == dim:
                logger.info("%s.%s already vector(%d).", table, column, dim)
            else:
                if (table, column) == ("articles", "embedding"):
                    cur.execute("DROP INDEX IF EXISTS idx_articles_embedding;")
                cur.execute(f"ALTER TABLE {table} ALTER COLUMN {column} TYPE vector({dim}) USING NULL;")
                logger.info("%s.%s: vector(%s) -> vector(%d)", table, column, current, dim)

    # 2. Articles, then the search index.
    embed_articles(only_missing=False)
    with get_db() as cur:
        cur.execute("CREATE INDEX IF NOT EXISTS idx_articles_embedding ON articles USING hnsw (embedding vector_cosine_ops);")

    with get_db() as cur:
        # 3. Story cluster centroids: mean of the member articles (cosine ignores length).
        if _column_dim(cur, "story_clusters", "centroid_embedding") is not None:
            cur.execute("""
                UPDATE story_clusters sc
                SET centroid_embedding = (SELECT AVG(a.embedding) FROM articles a WHERE a.id = ANY(sc.article_ids));
            """)
            logger.info("Story cluster centroids recomputed: %d", cur.rowcount)

        # 4. "+" follows: the name as a query.
        follows = []
        if _column_dim(cur, "user_follows", "embedding") is not None:
            cur.execute("SELECT id, name FROM user_follows;")
            follows = cur.fetchall()
    for fid, name in follows:
        with get_db() as cur:
            cur.execute("UPDATE user_follows SET embedding = %s::vector WHERE id = %s;",
                        (str(embedder.embed_query(name)), fid))
    logger.info("Follows re-embedded: %d", len(follows))

    # 5. Users: starting sentence, then interactions replayed in order.
    with get_db() as cur:
        cur.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS interest_context_en TEXT;")
        cur.execute("""
            SELECT id, preferred_macro_tags, preferred_micro_tags, interest_context_en
            FROM users WHERE COALESCE(array_length(preferred_macro_tags, 1), 0) > 0;
        """)
        users = cur.fetchall()
    for uid, macros, micros, context_en in users:
        vec = np.array(embedder.embed_query(context_en or _standard_interest_text(macros, micros or [])))
        with get_db() as cur:
            cur.execute("""
                SELECT i.interaction_type, a.embedding
                FROM user_article_interactions i JOIN articles a ON a.id = i.article_id
                WHERE i.user_id = %s AND i.interaction_type IN ('like', 'dislike', 'skip')
                ORDER BY i.created_at ASC;
            """, (uid,))
            replayed = 0
            for itype, art_emb in cur.fetchall():
                new_vec = ema_update(vec, parse_vector(art_emb), itype)
                if new_vec is not None:
                    vec, replayed = new_vec, replayed + 1
            cur.execute("UPDATE users SET interest_embedding = %s::vector WHERE id = %s;", (str(vec.tolist()), uid))
        logger.info("User %s: interest vector rebuilt (%d interactions replayed)", str(uid)[:8], replayed)


def verify() -> None:
    with get_db() as cur:
        cur.execute("SELECT count(*) FILTER (WHERE embedding IS NOT NULL), count(*) FROM articles;")
        embedded, total = cur.fetchone()
    logger.info("Database verification: %d/%d articles have embeddings.", embedded, total)
    assert embedded == total, f"Mismatch: {embedded} embedded vs {total} total articles"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rebuild", action="store_true",
                        help="Resize vector columns to the configured model and re-embed everything")
    args = parser.parse_args()
    if args.rebuild:
        rebuild()
    else:
        embed_articles(only_missing=True)
    verify()
