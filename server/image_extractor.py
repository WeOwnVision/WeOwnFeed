"""Production-grade news article photo extraction and sanitization engine.

Extracts genuine, high-resolution editorial article photos while strictly filtering out:
- Site logos, SVG badges, and brand icons
- 16px/32px favicons and Google favicon fallbacks
- Social share buttons, avatars, and tracking pixels
- Low-resolution thumbnails

Sources inspected in priority order:
1. Validated candidate from Tavily Search / Extract `images` list
2. First substantive editorial image embedded in the article Markdown body
3. Fast OpenGraph (`og:image`) / Twitter Card (`twitter:image`) `<head>` extraction
"""

import re
import logging
import urllib.parse
from typing import Optional, List, Union, Tuple
import requests
from bs4 import BeautifulSoup

logger = logging.getLogger("image_extractor")

# High-precision patterns for images that must NEVER be treated as article photos
REJECT_URL_PATTERNS = [
    r'(?i)\.svg($|\?)',
    r'(?i)\.ico($|\?)',
    r'(?i)format=svg',
    r'(?i)data:image',
    r'(?i)google\.com/s2/favicons',
    r'(?i)[/_.-](logo|logos|site[-_]?logo|brand|masthead|avatar|avatars|badge|badges|button|buttons|icon|icons|touch[-_]?icon|apple[-_]?touch|favicon|ad[-_]|advertisement|banner|banners|sponsor|promoted|spinner|loader|placeholder|user[-_]?pic|author[-_]?pic|profile[-_]?pic|social[-_]?share|share[-_]?btn|reaction)[/_.-]',
    r'(?i)[/_.-](16x16|32x32|48x48|64x64|20px|40px|50px|80px|100px|thumb_mini|sz=128|sz=64|sz=32|sz=16)[/_.-]?',
    r'(?i)\b(tracking|beacon|spacer\.gif|blank\.gif|clear\.gif|pixel\.gif)\b',
]

REJECT_ALT_PATTERNS = [
    r'(?i)\b(logo|advertisement|scan the qr code|pixel|banner|sponsor|profile|avatar|author|icon)\b',
]

DESKTOP_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)


def is_valid_article_image(url: str, alt: str = "") -> bool:
    """Checks whether an image URL points to a legitimate article photo."""
    if not url or not isinstance(url, str):
        return False
    url = url.strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        return False

    for pat in REJECT_URL_PATTERNS:
        if re.search(pat, url):
            return False

    if alt:
        for pat in REJECT_ALT_PATTERNS:
            if re.search(pat, alt):
                return False

    return True


def score_image_candidate(url: str, alt: str = "") -> int:
    """Scores an image candidate: editorial hero photos receive higher priority."""
    score = 10
    lower_url = url.lower()

    # Preferred image extensions
    if any(lower_url.endswith(ext) or f"{ext}?" in lower_url for ext in [".jpg", ".jpeg", ".webp", ".png"]):
        score += 15

    # High-signal editorial / lead image naming
    for kw in ["ogimage", "cover", "featured", "hero", "lead", "upload", "article", "media", "story", "post"]:
        if kw in lower_url:
            score += 20

    # High-resolution indicators
    if any(dim in lower_url for dim in ["1200", "1920", "1080", "1280", "width=", "w="]):
        score += 15

    # Substantive descriptive alt text adds confidence
    if alt and len(alt.strip()) > 10:
        score += 10

    return score


def extract_image_from_markdown(markdown_text: str) -> Optional[str]:
    """Extracts the best editorial image from article markdown before cleanup."""
    if not markdown_text:
        return None

    candidates: List[Tuple[int, str]] = []

    # 1. ![Alt](url)
    for match in re.finditer(r'!\[([^\]]*)\]\(([^\)\s]+)[^\)]*\)', markdown_text):
        alt = match.group(1).strip()
        url = match.group(2).strip().strip('"\'')
        if is_valid_article_image(url, alt):
            candidates.append((score_image_candidate(url, alt), url))

    # 2. HTML <img src="url"> tags embedded in markdown
    for match in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\'][^>]*>', markdown_text, re.I):
        url = match.group(1).strip()
        if is_valid_article_image(url):
            candidates.append((score_image_candidate(url), url))

    if candidates:
        candidates.sort(key=lambda x: x[0], reverse=True)
        return candidates[0][1]

    return None


def extract_og_image_from_url(page_url: str, timeout: float = 3.0) -> Optional[str]:
    """
    Lightweight fast-stream extractor for OpenGraph/Twitter Card meta images.
    Streams only the first 64KB (sufficient for the HTML <head>) to minimize latency.
    """
    if not page_url or not (page_url.startswith("http://") or page_url.startswith("https://")):
        return None

    headers = {
        "User-Agent": DESKTOP_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }

    try:
        resp = requests.get(page_url, headers=headers, timeout=timeout, stream=True)
        if resp.status_code != 200:
            return None

        content_chunk = b""
        for chunk in resp.iter_content(chunk_size=8192):
            content_chunk += chunk
            if b"</head>" in content_chunk.lower() or len(content_chunk) >= 65536:
                break
        resp.close()

        html_text = content_chunk.decode("utf-8", errors="ignore")
        soup = BeautifulSoup(html_text, "html.parser")

        meta_tags = [
            ("property", "og:image"),
            ("property", "og:image:url"),
            ("property", "og:image:secure_url"),
            ("name", "twitter:image"),
            ("name", "twitter:image:src"),
            ("itemprop", "image"),
        ]

        candidates: List[Tuple[int, str]] = []
        for attr, val in meta_tags:
            tag = soup.find("meta", attrs={attr: val})
            if tag and tag.get("content"):
                img_url = urllib.parse.urljoin(page_url, tag["content"].strip())
                if is_valid_article_image(img_url):
                    candidates.append((score_image_candidate(img_url), img_url))

        # Check Schema.org JSON-LD if present in <head>
        for script in soup.find_all("script", attrs={"type": "application/ld+json"}):
            script_text = script.string or ""
            # Quick regex scan for image URLs inside JSON without full parsing overhead
            img_matches = re.findall(r'"image":\s*(?:\[\s*)?"([^"]+)"', script_text)
            for raw_m in img_matches:
                full_m = urllib.parse.urljoin(page_url, raw_m.strip())
                if is_valid_article_image(full_m):
                    candidates.append((score_image_candidate(full_m), full_m))

        if candidates:
            candidates.sort(key=lambda x: x[0], reverse=True)
            return candidates[0][1]

    except Exception as e:
        logger.debug("[ImageExtractor] Fast OG extraction failed for %s: %s", page_url, e)

    return None


def resolve_article_image(
    raw_markdown: str = "",
    tavily_images: Optional[List[Union[str, dict]]] = None,
    page_url: Optional[str] = None,
    fetch_og_fallback: bool = True
) -> Tuple[Optional[str], str]:
    """
    Unified entrypoint to resolve an article cover image with strict validation.
    
    Returns:
        (image_url, image_status):
        - If genuine image found: (image_url, "resolved")
        - If no genuine image found: (None, "gradient_fallback")
        NEVER returns a favicon or logo.
    """
    candidates: List[Tuple[int, str]] = []

    # 1. Filter and score candidate images from Tavily Search / Extract
    if tavily_images:
        for item in tavily_images:
            url = item.get("url") if isinstance(item, dict) else str(item)
            if is_valid_article_image(url):
                candidates.append((score_image_candidate(url), url))

    # 2. Extract embedded images from raw Markdown body
    if raw_markdown:
        md_img = extract_image_from_markdown(raw_markdown)
        if md_img:
            candidates.append((score_image_candidate(md_img) + 5, md_img))

    if candidates:
        candidates.sort(key=lambda x: x[0], reverse=True)
        return candidates[0][1], "resolved"

    # 3. Fallback: Fast OpenGraph / Twitter Card check on source URL
    if fetch_og_fallback and page_url:
        og_img = extract_og_image_from_url(page_url)
        if og_img:
            return og_img, "resolved"

    return None, "gradient_fallback"
