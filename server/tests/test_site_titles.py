"""Titles of crawled site posts: a section heading is never a post's title."""

from site_watcher import post_title


URL = "https://blog.google/models/introducing-weathernext-3"


def test_real_title_is_kept():
    assert post_title("WeatherNext 3", URL, "") == "WeatherNext 3"


def test_generic_title_falls_back_to_page_heading():
    text = "## Related stories\n# Rapid weather prediction at scale"
    assert post_title("Related stories", URL, text) == "Rapid weather prediction at scale"


def test_generic_heading_only_falls_back_to_address():
    assert post_title(None, URL, "## Related stories") == "Introducing Weathernext 3"
