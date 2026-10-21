import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

from image_extractor import (
    is_valid_article_image,
    score_image_candidate,
    extract_image_from_markdown,
    resolve_article_image
)

def test_is_valid_article_image():
    # Must reject favicons and Google favicon API
    assert not is_valid_article_image("https://www.google.com/s2/favicons?domain=example.com&sz=128")
    assert not is_valid_article_image("https://example.com/favicon.ico")
    assert not is_valid_article_image("https://example.com/apple-touch-icon.png")

    # Must reject SVGs and logos
    assert not is_valid_article_image("https://gamingbible.com/_next/static/media/gamingbible.2c660eff.svg")
    assert not is_valid_article_image("https://site.com/assets/images/header-logo.png")
    assert not is_valid_article_image("https://site.com/brand/site_logo_white.png")
    assert not is_valid_article_image("https://site.com/img.jpg?format=svg")

    # Must reject tiny thumbnails and tracking pixels
    assert not is_valid_article_image("https://site.com/pixel.gif")
    assert not is_valid_article_image("https://site.com/avatar_32x32.png")
    assert not is_valid_article_image("https://thumb.wikimedia.org/20px-shackle.png")

    # Must reject alt-text indicating logos or ads
    assert not is_valid_article_image("https://site.com/image.jpg", alt="Company Logo")
    assert not is_valid_article_image("https://site.com/image.jpg", alt="Sponsored advertisement")

    # Must accept genuine article photos
    assert is_valid_article_image("https://media.zenfs.com/en/techradar/87b111fc327c2301d9b3e7b939dfa8d8.jpg")
    assert is_valid_article_image("https://resizer.ladbiblegroup.com/ogimage/v3/assets/penguin_colony.jpg")
    assert is_valid_article_image("https://freeyorkk.b-cdn.net/wp-content/uploads/2026/10/car-photo.webp")


def test_extract_image_from_markdown():
    sample_md = """
# Nvidia Unveils Next-Gen Architecture

![Header Logo](https://example.com/logo.svg)

Jensen Huang announced the new chip architecture today at the annual summit.

![Jensen Huang on stage with Blackwell GPU](https://blogs.nvidia.com/wp-content/uploads/2026/10/blackwell-chip-hero-1920x1080.jpg)

Here are the key takeaways from the event:
- 4x inference throughput
- Unified memory architecture

![Advertisement](https://ads.com/banner.png)
"""
    extracted = extract_image_from_markdown(sample_md)
    assert extracted == "https://blogs.nvidia.com/wp-content/uploads/2026/10/blackwell-chip-hero-1920x1080.jpg"


def test_resolve_article_image_tavily_filtering():
    tavily_images = [
        "https://gamingbible.com/_next/static/media/gamingbible.2c660eff.svg",
        "https://gamingbible.com/_next/static/media/google-discover.c5ad10d8.svg",
        "https://resizer.ladbiblegroup.com/unsafe/rs:fit:3840:0:0:0/penguin_colony.jpg.webp",
        "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/31/Free_software_logo.svg/40px-logo.svg.png"
    ]
    img_url, status = resolve_article_image(tavily_images=tavily_images, fetch_og_fallback=False)
    assert status == "resolved"
    assert img_url == "https://resizer.ladbiblegroup.com/unsafe/rs:fit:3840:0:0:0/penguin_colony.jpg.webp"


def test_resolve_article_image_all_bad_returns_gradient_fallback():
    # If all images are logos/SVGs, must NOT return a logo or favicon; must return gradient_fallback
    bad_images = [
        "https://example.com/logo.svg",
        "https://example.com/favicon.ico",
        "https://example.com/social-share-btn.png",
    ]
    img_url, status = resolve_article_image(tavily_images=bad_images, fetch_og_fallback=False)
    assert img_url is None
    assert status == "gradient_fallback"


if __name__ == "__main__":
    test_is_valid_article_image()
    print("✓ test_is_valid_article_image passed")
    test_extract_image_from_markdown()
    print("✓ test_extract_image_from_markdown passed")
    test_resolve_article_image_tavily_filtering()
    print("✓ test_resolve_article_image_tavily_filtering passed")
    test_resolve_article_image_all_bad_returns_gradient_fallback()
    print("✓ test_resolve_article_image_all_bad_returns_gradient_fallback passed")
    print("\nAll image extractor unit tests passed!")
