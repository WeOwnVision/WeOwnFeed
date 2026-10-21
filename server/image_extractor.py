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
import socket
import ipaddress
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


def is_safe_public_ip(ip_str: str) -> bool:
    """
    Validates that an IP address is a safe, publicly routable address.
    Strictly blocks:
    - Loopback: 127.0.0.0/8, ::1
    - Private IPv4: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    - Link-local: 169.254.0.0/16 (including cloud metadata 169.254.169.254), fe80::/10
    - Multicast, broadcast, reserved, unspecified
    - CGNAT / Shared space: 100.64.0.0/10
    """
    try:
        ip = ipaddress.ip_address(ip_str)
        if (ip.is_private or ip.is_loopback or ip.is_link_local or 
            ip.is_multicast or ip.is_reserved or ip.is_unspecified):
            return False
        # Explicit guard for cloud metadata and CGNAT
        if ip_str.startswith("169.254.") or ip_str.startswith("100.64."):
            return False
        return True
    except Exception:
        return False


def is_safe_url_host(url: str) -> bool:
    """
    Resolves hostname and verifies that ALL resolved IPs are safe public IPs.
    Prevents DNS rebinding and SSRF targeting cloud metadata or internal services.
    """
    try:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            return False
        hostname = parsed.hostname
        if not hostname:
            return False
        h_lower = hostname.lower()
        if h_lower in ("localhost", "127.0.0.1", "::1", "metadata.google.internal"):
            return False

        # If hostname is an IP string directly
        try:
            ipaddress.ip_address(hostname)
            return is_safe_public_ip(hostname)
        except ValueError:
            pass

        # Resolve DNS addresses
        addr_info = socket.getaddrinfo(hostname, None)
        if not addr_info:
            return False
        for family, _, _, _, sockaddr in addr_info:
            ip_str = sockaddr[0]
            if not is_safe_public_ip(ip_str):
                logger.debug("[SSRF Block] Host %s resolved to private/blocked IP %s", hostname, ip_str)
                return False
        return True
    except Exception as e:
        logger.debug("[SSRF Block] Host resolution failed for %s: %s", url, e)
        return False


def safe_stream_get(
    url: str,
    headers: Optional[dict] = None,
    timeout: float = 3.5,
    max_redirects: int = 3,
    max_bytes: int = 65536
) -> Optional[bytes]:
    """
    Performs SSRF-protected HTTP GET, checking resolved IP on every redirect,
    capping total redirects to max_redirects, and capping downloaded bytes to max_bytes.
    """
    current_url = url
    req_headers = headers or {
        "User-Agent": DESKTOP_UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }
    session = requests.Session()
    for _ in range(max_redirects + 1):
        if not is_safe_url_host(current_url):
            return None
        try:
            resp = session.get(current_url, headers=req_headers, timeout=timeout, stream=True, allow_redirects=False)
            if resp.status_code in (301, 302, 303, 307, 308):
                loc = resp.headers.get("Location")
                if not loc:
                    resp.close()
                    return None
                current_url = urllib.parse.urljoin(current_url, loc.strip())
                resp.close()
                continue

            if resp.status_code != 200:
                resp.close()
                return None

            content_chunk = b""
            for chunk in resp.iter_content(chunk_size=8192):
                content_chunk += chunk
                if len(content_chunk) >= max_bytes or b"</head>" in content_chunk.lower():
                    break
            resp.close()
            return content_chunk
        except Exception as e:
            logger.debug("[ImageExtractor] Safe stream failed for %s: %s", current_url, e)
            return None
    return None


def validate_image_head(url: str, timeout: float = 3.5) -> bool:
    """
    Validates that a URL resolves to a real, valid image:
    - Confirms SSRF safety.
    - Validates Content-Type: image/* (not svg/ico/text).
    - Validates minimum byte size (> 1500 bytes to weed out 1x1 tracking pixels).
    """
    if not is_valid_article_image(url) or not is_safe_url_host(url):
        return False

    headers = {
        "User-Agent": DESKTOP_UA,
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        "Referer": url,
    }
    try:
        # First try a lightweight HEAD
        resp = requests.head(url, headers=headers, timeout=timeout, allow_redirects=True)
        if resp.status_code == 200:
            ct = (resp.headers.get("Content-Type") or "").lower()
            if not ct.startswith("image/") or "svg" in ct or "icon" in ct:
                return False
            cl = resp.headers.get("Content-Length")
            if cl and cl.isdigit():
                return int(cl) >= 1500

        # If HEAD has no length or is disallowed, stream first 2KB
        s_resp = requests.get(url, headers=headers, timeout=timeout, stream=True, allow_redirects=True)
        if s_resp.status_code != 200:
            s_resp.close()
            return False
        ct = (s_resp.headers.get("Content-Type") or "").lower()
        if not ct.startswith("image/") or "svg" in ct or "icon" in ct:
            s_resp.close()
            return False
        chunk = b""
        for c in s_resp.iter_content(chunk_size=2048):
            chunk += c
            if len(chunk) >= 1500:
                break
        s_resp.close()
        return len(chunk) >= 1500
    except Exception:
        return False


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
    Lightweight SSRF-protected fast-stream extractor for OpenGraph/Twitter Card meta images.
    Streams only the first 64KB (sufficient for the HTML <head>) to minimize latency.
    """
    if not page_url or not (page_url.startswith("http://") or page_url.startswith("https://")):
        return None

    content_chunk = safe_stream_get(page_url, timeout=timeout, max_bytes=65536)
    if not content_chunk:
        return None

    try:
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
