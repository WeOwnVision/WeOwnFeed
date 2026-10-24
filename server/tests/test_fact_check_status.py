"""Fact Check badge codes, from new results and from ones saved earlier."""

from fact_check_status import verdict_code


def test_code_from_evidence_verdict():
    assert verdict_code({"verdict": "supported"}) == "supported"
    assert verdict_code({"verdict": "unverified_yet"}) == "developing"
    assert verdict_code({"verdict": "unverified"}) == "single_source"


def test_code_from_older_display_text():
    assert verdict_code({"fact_check_verdict": "Verified (Supported)"}) == "supported"
    assert verdict_code({"fact_check_verdict": "Partially Verified (Disputed)"}) == "disputed"
    assert verdict_code({"fact_check_verdict": "Contradicted (Disproven)"}) == "contradicted"
    assert verdict_code({"fact_check_verdict": "Unverified (Breaking / Fresh Origin)"}) == "developing"
    assert verdict_code({"fact_check_verdict": "Unverified (Single Source)"}) == "single_source"


def test_no_code_without_a_result():
    assert verdict_code(None) is None
    assert verdict_code({}) is None
