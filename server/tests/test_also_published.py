"""Merged copies of a story are listed once per outlet (Site Watch, search)."""

from contextlib import contextmanager

import dedup


class _Cursor:
    def __init__(self, rows):
        self.rows = rows

    def execute(self, *_):
        pass

    def fetchall(self):
        return self.rows


def test_copies_are_grouped_per_outlet(monkeypatch):
    rows = [
        ("p1", "c1", "nvidianews.nvidia.com", "Copy", "https://nvidianews.nvidia.com/a", None),
        ("p1", "c2", "nvidianews.nvidia.com", "Copy 2", "https://nvidianews.nvidia.com/b", None),
        ("p1", "c3", "blogs.nvidia.com", "Same outlet", "https://blogs.nvidia.com/c", None),
        ("p1", "c4", "reuters.com", "Wire", "https://reuters.com/d", None),
    ]

    @contextmanager
    def fake_db():
        yield _Cursor(rows)

    monkeypatch.setattr("db.get_db", fake_db)
    items = [
        {"id": "p1", "source": "blogs.nvidia.com"},
        {"id": "p2", "source": "cnbc.com"},
        {"id": "p3", "also_published_by": [], "also_published_by_count": 0},
    ]
    dedup.attach_also_published(items)
    assert [o["source"] for o in items[0]["also_published_by"]] == ["nvidianews.nvidia.com", "reuters.com"]
    assert items[0]["also_published_by_count"] == 2
    assert items[1]["also_published_by"] == [] and items[1]["also_published_by_count"] == 0
