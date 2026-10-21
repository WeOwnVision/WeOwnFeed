"""Dense vector embeddings for search, the personalized feed, "+" follows and story clustering.

Two backends (EMBEDDING_BACKEND):
- "nebius" (default): Qwen/Qwen3-Embedding-8B on Nebius Token Factory, cut to
  EMBEDDING_DIM (default 1024) dimensions by the API. Multilingual, no local model.
- "local": sentence-transformers/all-MiniLM-L6-v2 on GPU/CPU, 384 dimensions,
  English only (the original setup).

Documents (articles) are embedded as they are; queries (search text, follow names,
interest sentences) go through embed_query(), which adds the retrieval instruction
Qwen3-Embedding expects (MiniLM ignores it). Measured 2026-10-18 on 219 labeled
articles, subtopic phrase -> labeled articles: AUC / precision@5 MiniLM 0.903 / 0.56
(Turkish phrases 0.598 / 0.18), Qwen 1024 0.940 / 0.64 (Turkish 0.935 / 0.59); without
the instruction Qwen fell to 0.917 / 0.53.

Similarity thresholds depend on the model, so each backend carries its own
(similarity_thresholds()). Changing backend or dimension needs
`python migrate_embeddings.py --rebuild` (column sizes + re-embedding).
"""

import functools
import os
import logging
from typing import Dict, List

# Suppress verbose Hugging Face hub & tokenizers warnings
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"

logger = logging.getLogger("embedder")

_embedder_instance = None

LOCAL_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
LOCAL_DIM = 384
NEBIUS_MODEL = "Qwen/Qwen3-Embedding-8B"
NEBIUS_DIM = 1024

QUERY_INSTRUCTION = "Instruct: Given a news search query, retrieve news articles relevant to the query\nQuery: "

# Cosine similarity cut-offs per backend. MiniLM values are the original ones.
# Qwen values were mapped on 2026-10-18 (219 articles) so that the same share of
# unrelated pairs passes as with MiniLM; follow_min was set by hand (0.50: 5 false
# matches over 12 names x 219 articles, real quantum-physics stories still match).
SIMILARITY_THRESHOLDS: Dict[str, Dict[str, float]] = {
    "local": {
        "search_noise": 0.22,     # below: not a search result at all
        "search_direct": 0.32,    # at or above: "Direct Focus" tier
        "search_top": 0.60,       # relevance score reaches 99 here
        "same_story": 0.55,       # worker story clustering
        "digest_sibling": 0.52,   # daily digest: a second source on the same story
        "follow_min": 0.45,       # "+" follow matched by meaning
        "feed_floor": 0.0,        # feed interest points = 25 x (sim - floor) / (1 - floor)
    },
    "nebius": {
        "search_noise": 0.345,
        "search_direct": 0.423,
        "search_top": 0.69,
        "same_story": 0.643,
        "digest_sibling": 0.622,
        "follow_min": 0.50,
        # Qwen gives unrelated articles ~0.25; the floor keeps feed points on the
        # MiniLM scale (in-category ~7, other ~2.5 of 25).
        "feed_floor": 0.20,
    },
}


def embedding_backend() -> str:
    backend = os.getenv("EMBEDDING_BACKEND", "nebius").strip().lower()
    return backend if backend in SIMILARITY_THRESHOLDS else "nebius"


def embedding_dim() -> int:
    """Vector size of the configured backend (no model is loaded)."""
    if embedding_backend() == "local":
        return LOCAL_DIM
    return int(os.getenv("EMBEDDING_DIM", str(NEBIUS_DIM)))


def similarity_thresholds() -> Dict[str, float]:
    return SIMILARITY_THRESHOLDS[embedding_backend()]


def _clean(texts: List[str]) -> List[str]:
    return [t.strip() if t and t.strip() else "empty" for t in texts]


class TextEmbedder:
    """Singleton wrapper for local sentence-transformers model."""

    def __init__(self, model_name: str = LOCAL_MODEL):
        import torch
        from sentence_transformers import SentenceTransformer

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model_name = model_name
        self.dim = LOCAL_DIM

        # Safe loading pattern:
        # First attempt to load with offline mode enabled.
        # If not cached locally, allow online download once, then lock to offline mode.
        try:
            os.environ["HF_HUB_OFFLINE"] = "1"
            logger.info("Loading %s in offline mode on %s...", self.model_name, self.device)
            self.model = SentenceTransformer(self.model_name, device=self.device)
            logger.info("Loaded %s from local cache on %s.", self.model_name, self.device)
        except Exception as e:
            logger.info("Local cache miss or offline load failed (%s). Downloading model...", e)
            os.environ.pop("HF_HUB_OFFLINE", None)
            self.model = SentenceTransformer(self.model_name, device=self.device)
            os.environ["HF_HUB_OFFLINE"] = "1"
            logger.info("Successfully downloaded and cached %s on %s.", self.model_name, self.device)

    def embed_text(self, text: str) -> List[float]:
        """Embeds a single string into a 384-dimensional float vector."""
        if not text or not text.strip():
            text = "empty"
        vec = self.model.encode(text.strip(), convert_to_numpy=True, normalize_embeddings=True)
        return vec.tolist()

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """Embeds a batch of strings efficiently into 384-dimensional vectors."""
        vecs = self.model.encode(_clean(texts), batch_size=32, convert_to_numpy=True, normalize_embeddings=True)
        return vecs.tolist()

    def embed_query(self, text: str) -> List[float]:
        """MiniLM has no query instruction; same as embed_text."""
        return self.embed_text(text)


class NebiusEmbedder:
    """Qwen3-Embedding on Nebius Token Factory (same OpenAI-compatible client as the LLM calls)."""

    BATCH = 64
    ATTEMPTS = 2

    def __init__(self, model_name: str = NEBIUS_MODEL, dim: int = NEBIUS_DIM):
        from ai import ai_client

        self.client = ai_client
        self.model_name = model_name
        self.dim = dim
        self.device = "nebius"

    def _embed(self, texts: List[str]) -> List[List[float]]:
        error: Exception = RuntimeError("no attempt")
        for _ in range(self.ATTEMPTS):
            try:
                resp = self.client.embeddings.create(model=self.model_name, input=texts,
                                                     dimensions=self.dim, timeout=30.0)
                # Vectors come back unit length when cut (checked: norm 1.0).
                return [d.embedding for d in sorted(resp.data, key=lambda d: d.index)]
            except Exception as e:
                error = e
                logger.warning("[Embedder] Nebius embedding call failed (%s)", e)
        raise error

    def embed_text(self, text: str) -> List[float]:
        return self._embed(_clean([text]))[0]

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        clean = _clean(texts)
        out: List[List[float]] = []
        for i in range(0, len(clean), self.BATCH):
            out += self._embed(clean[i:i + self.BATCH])
        return out

    def embed_query(self, text: str) -> List[float]:
        """Queries repeat (searches, follow names, the warm-up), so they are cached:
        a cached one skips the ~1 s round trip to Nebius."""
        return list(self._cached_query(_clean([text])[0]))

    @functools.lru_cache(maxsize=2048)
    def _cached_query(self, text: str) -> tuple:
        return tuple(self._embed([QUERY_INSTRUCTION + text])[0])


def get_embedder():
    """Returns the singleton embedder of the configured backend."""
    global _embedder_instance
    if _embedder_instance is None:
        if embedding_backend() == "local":
            _embedder_instance = TextEmbedder()
        else:
            _embedder_instance = NebiusEmbedder(os.getenv("EMBEDDING_MODEL", NEBIUS_MODEL), embedding_dim())
        logger.info("Embedder: %s (%d dimensions)", _embedder_instance.model_name, _embedder_instance.dim)
    return _embedder_instance
