"""Copies of a story are listed once per outlet and grouped into independent
origins, whether they were linked later (duplicate_of) or kept as a name and
a link when fetched (article_mentions)."""

from contextlib import contextmanager

import dedup


class _Cursor:
    """Answers each execute() with the next prepared result."""

    def __init__(self, results):
        self.results = list(results)
        self.current = []

    def execute(self, *_):
        self.current = self.results.pop(0)

    def fetchall(self):
        return self.current


def _use_db(monkeypatch, results):
    @contextmanager
    def fake_db():
        yield _Cursor(results)
    monkeypatch.setattr("db.get_db", fake_db)


def test_copies_are_grouped_per_outlet_and_origin(monkeypatch):
    primary_text = "SAN JOSE (Reuters) - Nvidia said on Tuesday ..."
    _use_db(monkeypatch, [
        # primaries: id, text, url
        [("p1", primary_text, "https://reuters.com/a"), ("p2", "Own reporting.", "https://cnbc.com/b")],
        # copies: primary, id, source, title, url, published_at, text, origin
        [
            ("p1", "c1", "yahoo.com", "Copy", "https://yahoo.com/a", None, None, "Reuters"),
            ("p1", "c2", "yahoo.com", "Copy again", "https://yahoo.com/b", None, None, "Reuters"),
            ("p1", "c3", "reuters.com", "Same outlet", "https://reuters.com/c", None, None, "Reuters"),
            ("p1", "c4", "techcrunch.com", "Own take", "https://techcrunch.com/d", None, "TechCrunch reported", None),
        ],
    ])
    items = [{"id": "p1", "source": "reuters.com"}, {"id": "p2", "source": "cnbc.com"}]
    dedup.attach_also_published(items)

    p1, p2 = items
    assert [o["source"] for o in p1["also_published_by"]] == ["yahoo.com", "techcrunch.com"]
    assert p1["also_published_by_count"] == 2
    assert p1["independent_origins_count"] == 2
    wire = p1["origins"][0]
    assert wire["name"] == "Reuters" and wire["wire"] is True
    assert wire["outlets"] == ["reuters.com", "yahoo.com"]
    assert p1["origins"][1]["outlets"] == ["techcrunch.com"]

    assert p2["also_published_by"] == [] and p2["also_published_by_count"] == 0
    assert p2["origins"] == [] and p2["independent_origins_count"] == 1
