"""
story_copies.py
---------------
Recognizes copies of the same story when they are fetched, so only one of
them is processed (cleaned, summarized, labeled, embedded) and the others are
kept as a name and a link ("also published by").

  same story   headlines nearly the same, or similar headlines plus the body
               text the fetch already has overlapping (wire reprints)
  best copy    the most authoritative source (evidence_verifier's ranking);
               on a tie, the first one fetched
  origin       the wire agency named in the byline (Reuters, AP, ...), else
               the outlet's own domain; copies sharing an origin are one
               independent source

Used by ingest_tavily (copies inside one search) and the ingest endpoint
(a copy of a story stored earlier). Copies found after a story was
processed stay linked through dedup.py as before.
"""

import re
from typing import Any, Dict, List, Optional, Sequence

from content_cleaner import extract_normalized_shingles
from url_utils import extract_domain

# "Nvidia beats estimates - Reuters", "Nvidia beats estimates | CNBC"
_SITE_SUFFIX = re.compile(r"\s+[-|–—:]\s+[^-|–—:]{2,40}$")
_STOP = {
    "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "at",
    "by", "from", "as", "is", "are", "its", "it", "this", "that", "after", "new",
}

TITLE_SAME = 0.8      # headline overlap that alone means "same story"
TITLE_RELATED = 0.4   # headline overlap that needs the body text to agree
TEXT_SAME = 0.5       # body overlap (5-word shingles) for a related headline
TEXT_WIRE = 0.65      # body overlap that alone means a reprint (old wire gate)
MIN_TITLE_WORDS = 4   # shorter headlines never match on the headline alone


def title_words(title: str) -> set:
    t = _SITE_SUFFIX.sub("", (title or "").strip()).lower()
    words = re.findall(r"[^\W_]+", t)
    return {w for w in words if len(w) > 1 and w not in _STOP}


def title_similarity(a: str, b: str) -> float:
    wa, wb = title_words(a), title_words(b)
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


def text_overlap(a: str, b: str) -> float:
    sa = extract_normalized_shingles(a or "", k=5)
    sb = extract_normalized_shingles(b or "", k=5)
    if len(sa) < 5 or len(sb) < 5:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def same_story(title_a: str, text_a: str, title_b: str, text_b: str) -> bool:
    ts = title_similarity(title_a, title_b)
    if ts >= TITLE_SAME and min(len(title_words(title_a)), len(title_words(title_b))) >= MIN_TITLE_WORDS:
        return True
    overlap = text_overlap(text_a, text_b) if (text_a and text_b) else 0.0
    if ts >= TITLE_RELATED and overlap >= TEXT_SAME:
        return True
    return overlap >= TEXT_WIRE


def origin_of(text: str, url: str) -> str:
    from evidence_verifier import detect_wire_origin
    return detect_wire_origin(text or "", url or "")


def is_wire_origin(origin: str) -> bool:
    from evidence_verifier import WIRE_PATTERNS
    return origin in WIRE_PATTERNS


def _authority(url: str) -> int:
    from evidence_verifier import _score_source_authority
    return _score_source_authority(url or "")


def group_copies(items: Sequence[Dict[str, Any]]) -> List[List[int]]:
    """
    Groups `items` ({"title", "text", "url"}) into stories; each group lists
    item indexes, best copy first (highest authority, then fetch order).
    """
    groups: List[List[int]] = []
    for i, it in enumerate(items):
        for g in groups:
            first = items[g[0]]
            if same_story(it.get("title", ""), it.get("text", ""), first.get("title", ""), first.get("text", "")):
                g.append(i)
                break
        else:
            groups.append([i])
    for g in groups:
        g.sort(key=lambda i: (-_authority(items[i].get("url", "")), i))
    return groups


def copy_entry(title: str, url: str, text: str, published: Optional[str]) -> Dict[str, Any]:
    """A copy as the ingest API takes it: name and link only, plus its origin."""
    return {
        "Site": extract_domain(url),
        "Baslik": title,
        "Link": url,
        "Tarih": published,
        "Origin": origin_of(text, url),
    }


def group_origins(primary: Dict[str, Any], copies: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Independent origins of a story and its copies ({"source", "origin"}):
    [{"name", "wire", "outlets"}], largest group first.
    """
    groups: Dict[str, Dict[str, Any]] = {}
    for c in [primary, *copies]:
        name = c.get("origin") or c.get("source") or "web"
        g = groups.setdefault(name, {"name": name, "wire": is_wire_origin(name), "outlets": []})
        if c.get("source") and c["source"] not in g["outlets"]:
            g["outlets"].append(c["source"])
    return sorted(groups.values(), key=lambda g: (-len(g["outlets"]), g["name"]))
