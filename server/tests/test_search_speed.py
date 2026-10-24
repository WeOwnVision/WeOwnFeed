"""Search never waits long for the query embedding: past the limit it answers
from full text and tags, and says so (`semantic: false`)."""

import time
from contextlib import contextmanager

import routers.search as search


class _Cursor:
    def __init__(self):
        self.params = None

    def execute(self, _sql, params=None):
        self.params = params

    def fetchall(self):
        return []


def _fake_db(cursor):
    @contextmanager
    def get_db():
        yield cursor
    return get_db


class _SlowEmbedder:
    def embed_query(self, text):
        time.sleep(1.0)
        return [0.1] * 4


class _FastEmbedder:
    def embed_query(self, text):
        return [0.1] * 4


def test_slow_embedding_falls_back_to_text_search(monkeypatch):
    cur = _Cursor()
    monkeypatch.setattr(search, "get_db", _fake_db(cur))
    monkeypatch.setattr(search, "get_embedder", lambda: _SlowEmbedder())
    monkeypatch.setattr(search, "SEARCH_EMBED_WAIT_SECONDS", 0.1)
    t = time.perf_counter()
    res = search.execute_hybrid_search("nvidia europe cloud", grouped=True)
    assert time.perf_counter() - t < 0.8
    assert res["semantic"] is False
    assert cur.params["q_vec"] is None


def test_fast_embedding_uses_meaning_tier(monkeypatch):
    cur = _Cursor()
    monkeypatch.setattr(search, "get_db", _fake_db(cur))
    monkeypatch.setattr(search, "get_embedder", lambda: _FastEmbedder())
    res = search.execute_hybrid_search("nvidia europe cloud", grouped=True)
    assert res["semantic"] is True
    assert cur.params["q_vec"] == [0.1] * 4
