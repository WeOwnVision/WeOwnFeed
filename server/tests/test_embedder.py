"""
Offline tests for the embedding backends (embedder.py): no network, no DB, no model download.

Run:  python tests/test_embedder.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")
os.environ.setdefault("AI_API_KEY", "test-key")

import embedder


class FakeEmbeddings:
    def __init__(self, fail_first=False):
        self.calls = []
        self.fail_first = fail_first
        self.embeddings = self

    def create(self, model, input, dimensions, timeout):
        self.calls.append({"model": model, "input": list(input), "dimensions": dimensions})
        if self.fail_first and len(self.calls) == 1:
            raise TimeoutError("slow")
        data = [type("D", (), {"index": i, "embedding": [float(i)] * dimensions}) for i in range(len(input))]
        return type("R", (), {"data": list(reversed(data))})   # out of order on purpose


def _nebius(fake, dim=8):
    e = embedder.NebiusEmbedder(dim=dim)
    e.client = fake
    return e


def test_backend_settings():
    os.environ.pop("EMBEDDING_BACKEND", None)
    os.environ.pop("EMBEDDING_DIM", None)
    assert embedder.embedding_backend() == "nebius" and embedder.embedding_dim() == 1024
    os.environ["EMBEDDING_DIM"] = "512"
    assert embedder.embedding_dim() == 512
    os.environ["EMBEDDING_BACKEND"] = "local"
    assert embedder.embedding_dim() == 384
    assert embedder.similarity_thresholds()["follow_min"] == 0.45      # original MiniLM values
    assert embedder.similarity_thresholds()["feed_floor"] == 0.0
    os.environ["EMBEDDING_BACKEND"] = "something-else"
    assert embedder.embedding_backend() == "nebius"
    os.environ.pop("EMBEDDING_BACKEND")
    os.environ.pop("EMBEDDING_DIM")
    for t in embedder.SIMILARITY_THRESHOLDS.values():
        assert t["search_noise"] < t["search_direct"] < t["search_top"]
    print("✓ test_backend_settings PASSED")


def test_documents_and_queries():
    fake = FakeEmbeddings()
    e = _nebius(fake)
    assert e.embed_text("  Anthropic IPO ") == [0.0] * 8
    assert fake.calls[-1]["input"] == ["Anthropic IPO"] and fake.calls[-1]["dimensions"] == 8
    e.embed_query("Revolut")
    assert fake.calls[-1]["input"] == [embedder.QUERY_INSTRUCTION + "Revolut"]
    calls = len(fake.calls)
    e.embed_query(" Revolut ")                                          # cached: no second call
    assert len(fake.calls) == calls
    vecs = e.embed_batch(["a", "", "c"])
    assert [v[0] for v in vecs] == [0.0, 1.0, 2.0]                     # put back in input order
    assert fake.calls[-1]["input"][1] == "empty"
    print("✓ test_documents_and_queries PASSED")


def test_batches_and_retry():
    fake = FakeEmbeddings()
    e = _nebius(fake)
    e.embed_batch([str(i) for i in range(150)])
    assert [len(c["input"]) for c in fake.calls] == [64, 64, 22]
    fake = FakeEmbeddings(fail_first=True)
    assert _nebius(fake).embed_text("x") == [0.0] * 8                  # second attempt succeeds
    assert len(fake.calls) == 2
    print("✓ test_batches_and_retry PASSED")


if __name__ == "__main__":
    print("=" * 65)
    print("   EMBEDDING BACKEND TEST SUITE")
    print("=" * 65)
    test_backend_settings()
    test_documents_and_queries()
    test_batches_and_retry()
    print("=" * 65)
    print("ALL 3 EMBEDDING TESTS PASSED!")
    print("=" * 65)
