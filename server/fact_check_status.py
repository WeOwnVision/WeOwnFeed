"""
fact_check_status.py
--------------------
The saved Fact Check result of stories as one short code, so story lists
can show a badge without sending the whole result:

  supported     ✓  official source, or 2+ independent sources, no contradiction
  disputed      ⚠  support and contradiction
  contradicted  ✕  contradiction without independent support
  developing    ◷  fresh (< 6 h) single-origin story, too new to cross-check
  single_source    no outside evidence found yet (the app shows no badge)

Stories never fact-checked get no code.
"""

from typing import Any, Dict, List, Optional

from db import get_db

_FROM_EVIDENCE = {
    "supported": "supported",
    "disputed": "disputed",
    "contradicted": "contradicted",
    "unverified_yet": "developing",
    "unverified": "single_source",
}


def verdict_code(fact_check: Optional[Dict[str, Any]]) -> Optional[str]:
    """The code of a saved `fact_check_cache`. Results saved before the
    `verdict` field existed only have the display text, e.g.
    "Verified (Supported)"."""
    if not isinstance(fact_check, dict):
        return None
    raw = str(fact_check.get("verdict") or "").lower()
    if raw in _FROM_EVIDENCE:
        return _FROM_EVIDENCE[raw]
    text = str(fact_check.get("fact_check_verdict") or "").lower()
    if not text:
        return None
    if text.startswith("contradicted"):
        return "contradicted"
    if text.startswith("partially") or "disputed" in text:
        return "disputed"
    if text.startswith("verified"):
        return "supported"
    if "breaking" in text or "fresh" in text:
        return "developing"
    return "single_source"


def attach_fact_check_verdicts(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Adds `fact_check_verdict` to the stories that were fact-checked (one
    query for the whole list)."""
    ids = [str(i["id"]) for i in items if i.get("id")]
    if not ids:
        return items
    with get_db() as cur:
        cur.execute("""
            SELECT id, fact_check_cache FROM articles
            WHERE id = ANY(%s::uuid[]) AND fact_check_cache IS NOT NULL;
        """, (ids,))
        codes = {str(r[0]): verdict_code(r[1]) for r in cur.fetchall()}
    for item in items:
        code = codes.get(str(item.get("id")))
        if code:
            item["fact_check_verdict"] = code
    return items
