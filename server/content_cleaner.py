import re
import html
import logging
from typing import Tuple

logger = logging.getLogger("content_cleaner")

# Universal stop words for title relevance checking
STOP_WORDS = {
    "the", "a", "an", "and", "or", "in", "on", "at", "to", "for", "of", "with",
    "by", "is", "it", "its", "from", "as", "that", "this", "are", "was", "were",
    "be", "has", "have", "had", "will", "would", "can", "could", "should", "not"
}

# 1. Strong Tail Headings: Full-line editorial exit headers
# Requires minimum depth (>= 500 chars and >= 45% of document)
STRONG_TAIL_PATTERN = (
    r'^\s*(?:#{1,4}\s*|\*{1,2}\s*)?'
    r'(?:comments?(?:\s*\(\d+\))?|discussion|leave a reply|join the conversation|'
    r'related (?:stories|articles|posts|content|reading|coverage|topics)|further reading|'
    r'recommended (?:stories|articles|reading)|(?:most\s+)?popular(?:\s+(?:stories|articles|posts|now))?|'
    r'trending (?:stories|now|articles)|more from [a-z0-9\s\.\-_]+|'
    r'download the [a-z0-9\s\.\-_]+app|retrieve your password|'
    r'channels|subscribe to our newsletter|sign up for our newsletter|newsletter signup|'
    r'loading the next article)'
    r'[:\s]*$'
)
STRONG_TAIL_REGEX = re.compile(STRONG_TAIL_PATTERN, flags=re.IGNORECASE | re.MULTILINE)

# 2. Weak Tail Markers: Closing markers requiring depth (>= 500 chars and >= 50% of document)
WEAK_TAIL_PATTERN = (
    r'^\s*(?:\*{0,2}|_{0,2})'
    r'(?:about the (?:\[?(?:writer|author|reporter)\]?(?:\([^\)]+\))?|team)|'
    r'author bio|contributor bio|'
    r'copyright\b|all rights reserved|©\s*\d{4}|\(c\)\s*\d{4}|'
    r'privacy policy|cookie policy|terms of service|'
    r'disclaimer:?|the views expressed|investment disclaimer)'
)
WEAK_TAIL_REGEX = re.compile(WEAK_TAIL_PATTERN, flags=re.IGNORECASE | re.MULTILINE)

# 3. Inline Promotional & Boilerplate Lines: Removed line-by-line without truncating the document
INLINE_BOILERPLATE_PATTERN = (
    r'^\s*(?:'
    r'(?:sign up for|subscribe to) (?:our |the )?newsletter.*|'
    r'delivered (?:directly )?to your inbox.*|'
    r'get our (?:daily|weekly) (?:newsletter|briefing|roundup).*|'
    r'follow\s+.*?on\s+(?:google|twitter|x|linkedin|facebook|instagram|threads|youtube).*|'
    r'follow\s+us\s+on\s+.*|'
    r'share (?:this|on)\s+(?:twitter|x|linkedin|facebook|reddit|email|whatsapp).*|'
    r'share\s*:\s*\[.*|'
    r'\[read all\s+comments\b.*|'
    r'\[skip to\b.*|'
    r'(?:advertisement|sponsored content|promoted story|promoted post)\s*|'
    r'\[?\s*#{0,5}\s*\*{0,2}\s*(?:read more|see also|also read|related (?:story|article|reading|coverage)):?\s*\*{0,2}\s*.*?\]\(https?://[^\)]+\)|'
    r'read\s+(?:more|next)\s*:.*|'
    r'(?:get |save )\d+% off.*|'
    r'last day to save.*'
    r')\s*$'
)
INLINE_BOILERPLATE_REGEX = re.compile(INLINE_BOILERPLATE_PATTERN, flags=re.IGNORECASE | re.MULTILINE)

# Cookie, Privacy, and GDPR banner patterns
COOKIE_BANNER_PATTERN = (
    r'(?i)^\s*(?:'
    r'.{0,40}(?:we use cookies|this (?:site|website) uses cookies|by using (?:our|this) site, you (?:consent|agree) to cookies).*|'
    r'.{0,40}(?:cookie policy|manage (?:cookie )?preferences|accept (?:all )?cookies).*'
    r')\s*$'
)
COOKIE_BANNER_REGEX = re.compile(COOKIE_BANNER_PATTERN, flags=re.MULTILINE)

# Paywall pitch patterns at block level
PAYWALL_BLOCK_PATTERN = (
    r'(?i)^\s*(?:'
    r'#{0,4}\s*go unlimited with .*|'
    r'get unlimited access to .*|'
    r'\[try (?:gold|premium|pro) - free\].*|'
    r'\$\d+(?:\.\d+)?(?:/year|/month)?|'
    r'subscribe to (?:read|unlock) (?:the |this )?(?:full )?(?:article|story|analysis).*|'
    r'already a subscriber\? (?:log in|sign in).*'
    r')\s*$'
)
PAYWALL_BLOCK_REGEX = re.compile(PAYWALL_BLOCK_PATTERN, flags=re.MULTILINE)

# Tracking pixel domains / analytics beacons
TRACKING_PIXEL_REGEX = re.compile(
    r'(?i)\b(?:analytics\.[a-z0-9\-]+\.[a-z]+/(?:piwik|matomo)\.php|'
    r'pixel\.(?:quantserve|wp)\.com|ids\.ad\.gt|moatads\.com|'
    r'scorecardresearch\.com|doubleclick\.net|pub\.network)/[^\s\)\"\']+'
)


def _is_error_or_bot_page(text: str) -> bool:
    """Detects bot challenges or 404 error pages while protecting news articles reporting on outages."""
    challenge_phrases = [
        "please enable javascript",
        "verify you are a human",
        "just a moment...",
        "404 page not found",
        "access to this page has been denied"
    ]
    text_lower = text.lower()
    lead_350 = text_lower[:350]
    for phrase in challenge_phrases:
        if phrase in lead_350 or (len(text) < 1500 and phrase in text_lower):
            return True
    return False


def _is_paywall_stub(text: str) -> bool:
    """Detects shallow paywall gates while allowing long articles that mention subscriptions."""
    if len(text) >= 2500:
        return False
    paywall_phrases = [
        "subscribe to read",
        "subscribers only",
        "already a subscriber? log in",
        "unlock this story with a subscription"
    ]
    text_lower = text.lower()
    return any(p in text_lower for p in paywall_phrases)


def _is_ui_or_sidebar_dump(text: str, title: str = "") -> bool:
    """
    Detects navigation menus, stock ticker lists, or sidebar aggregator dumps
    that lack genuine editorial prose.
    """
    non_code = re.sub(r'```[\s\S]*?```', '', text)
    lines = [l.strip() for l in non_code.split('\n') if l.strip()]
    if len(lines) >= 6:
        avg_line_len = sum(len(l) for l in lines) / len(lines)
        punct_count = sum(1 for l in lines if re.search(r'[.,!?:;]', l))
        punct_ratio = punct_count / len(lines)
        if avg_line_len < 35 and punct_ratio < 0.35:
            return True

    # Title word relevance: If title has >= 3 significant words and NONE appear in text
    if title:
        sig_words = [
            w for w in re.findall(r'\b[a-z0-9]+\b', title.lower())
            if len(w) >= 3 and w not in STOP_WORDS
        ]
        if len(sig_words) >= 3:
            text_lower = text.lower()
            if not any(w in text_lower for w in sig_words):
                return True

    return False


def _clean_unicode_and_html(text: str) -> str:
    """Removes invisible unicode characters, unescapes entities, and strips raw HTML tags."""
    # Zero-width spaces, joiners, BOM
    text = re.sub(r'[\u200b\u200c\u200d\uFEFF]', '', text)
    # Non-breaking space to regular space
    text = text.replace('\u00a0', ' ')

    # Unescape HTML entities (&amp;, &nbsp;, &#39;, etc.)
    text = html.unescape(text)

    # Strip script, style, iframe, svg, button tags and their contents
    text = re.sub(r'(?is)<(script|style|iframe|svg|button)[^>]*>.*?</\1>', '', text)
    # Strip standalone HTML tags but keep line breaks and inner text
    text = re.sub(r'<br\s*/?>', '\n', text, flags=re.I)
    text = re.sub(r'</?(?:p|div|section|article|main|header|footer|nav|span|aside|figure|figcaption)[^>]*>', '\n', text, flags=re.I)
    text = re.sub(r'</?[a-zA-Z][^>]*>', ' ', text)

    return text


def _strip_markdown_images(text: str) -> str:
    """
    Strips markdown image tags and linked images since the reader modal
    renders plain text. Retains any editorial alt-text if useful, or removes entirely.
    """
    # 1. Linked images: [![Alt](image_url)](link_url) -> remove or retain alt
    text = re.sub(r'\[!\[([^\]]*)\]\([^\)]+\)\]\([^\)]+\)', r'\1', text)
    # 2. Standalone images: ![Alt](url) -> remove or retain alt if substantial
    def _img_replace(match):
        alt = match.group(1).strip()
        url = match.group(2).strip()
        if url.startswith('data:image') or TRACKING_PIXEL_REGEX.search(url):
            return ''
        if re.search(r'(?i)\b(logo|advertisement|scan the qr code|pixel|banner|image \d+)\b', alt):
            return ''
        return ''

    text = re.sub(r'!\[([^\]]*)\]\(([^\)]+)\)', _img_replace, text)
    return text


def _is_nav_or_link_line(line: str) -> bool:
    """Detects lines composed entirely of markdown links, breadcrumbs, or nav buttons."""
    s = line.strip()
    if not s:
        return False
    # Single standalone markdown link: [Text](url)
    if re.match(r'^\[[^\][]+\]\([^\(\)]+\)$', s):
        return True
    # Series of links separated by pipes, bullets, spaces, or slashes:
    if re.match(r'^(?:\[[^\][]+\]\([^\(\)]+\)\s*[•·|\-*\s/]*\s*)+$', s):
        non_link_text = re.sub(r'\[[^\][]+\]\([^\(\)]+\)', '', s).strip()
        if len(non_link_text) <= 15:
            return True
    # Common UI button words
    if s.lower() in {
        'translate', 'share', 'change font size', 'print', 'back to top',
        'log in', 'sign in', 'sign up', 'join', 'home', 'menu', 'channels',
        'read more', 'click here', 'leave a comment', 'watchlist', 'market data',
        'oops, something went wrong', 'skip to main content', 'skip to content',
        'write for us', 'email signup', 'close', 'search', 'submit',
        'site search toggle', 'mega menu toggle'
    }:
        return True
    # Ticker bar junk e.g. [SPY 770.32+0.09%](...)
    if re.search(r'\b(?:spy|qqq|dia|btc/usd|eth/usd)\s*[-+0-9\.\%]+', s, re.I):
        return True
    return False


def _is_boilerplate_lead_block(block: str) -> bool:
    """Checks if a paragraph block at the start of an article is boilerplate."""
    b = block.strip()
    if not b:
        return True
    if b.startswith('# '):
        return False
    if COOKIE_BANNER_REGEX.search(b):
        return True
    if PAYWALL_BLOCK_REGEX.search(b):
        return True
    # Standalone date line
    if re.match(r'^(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)?,?\s*(?:january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2},?\s+\d{4}$', b, re.I):
        return True
    # Event banner callout e.g. "Last day to save up to $200..."
    if re.search(r'(?i)\b(?:last day to save|register now|summit on|disrupt doors open)\b', b):
        return True
    lines = [l.strip() for l in b.split('\n') if l.strip()]
    if lines and all(_is_nav_or_link_line(l) for l in lines):
        return True
    if lines and all(re.match(r'^[*\-+•]\s*\[[^\]]+\]\(', l) for l in lines):
        return True
    if re.match(r'^(?:by\s+)?\[[^\]]+\]\([^\)]+\)\s*[•·|\-]\s*\[?[^\]]+\]?(?:\([^\)]+\))?$', b, re.I):
        return True
    if re.match(r'(?i)^(?:by|author|posted by|published by):?\s*\[.*?\]\(.*?\)$', b):
        return True
    if re.match(r'(?i)^\s*(\*{1,2}|_{1,2})?image credits?:?.*$', b):
        return True
    return False


def _strip_leading_boilerplate(text: str, title: str = "") -> str:
    """
    Robust leading boilerplate stripper that evaluates blocks iteratively
    until true editorial prose is reached. Supports finding the headline if present.
    """
    if title and len(title.strip()) > 10:
        clean_title = re.escape(title.strip())
        m = re.search(r'(?m)^\s*#+\s*' + clean_title, text[:6000], re.I)
        if not m:
            words = [re.escape(w) for w in re.findall(r'\b[a-zA-Z0-9]+\b', title) if w.lower() not in STOP_WORDS][:6]
            if len(words) >= 3:
                pat = r'(?m)^\s*#+\s*.*?' + r'.*?'.join(words[:4])
                m = re.search(pat, text[:6000], re.I)

        if m and m.start() > 100:
            text = text[m.start():].strip()

    paragraphs = text.split('\n\n')
    idx = 0
    title_preserved = None

    while idx < len(paragraphs):
        p = paragraphs[idx].strip()
        if not p:
            idx += 1
            continue

        if p.startswith('# ') and title_preserved is None:
            title_preserved = p
            idx += 1
            continue

        if _is_boilerplate_lead_block(p):
            idx += 1
            continue

        break

    remaining = paragraphs[idx:]
    if title_preserved:
        remaining.insert(0, title_preserved)

    return '\n\n'.join(remaining).strip()


def _is_high_link_density_list(lines: list[str]) -> bool:
    """Evaluates whether a group of bullet items is an aggregator link widget (> 60% link chars)."""
    return _is_high_link_density_block(lines)


def _is_high_link_density_block(lines: list[str]) -> bool:
    """Evaluates whether a group of lines is a link aggregator / menu widget."""
    if not lines:
        return False
    total_chars = sum(len(l.strip()) for l in lines)
    if total_chars == 0:
        return False
    link_chars = sum(len(m.group(0)) for l in lines for m in re.finditer(r'\[.*?\]\(.*?\)', l))
    if (link_chars / total_chars) > 0.50:
        return True
    link_lines = sum(1 for l in lines if _is_nav_or_link_line(l) or re.search(r'^[*\-+•]?\s*\[[^\]]+\]\(', l.strip()))
    if len(lines) >= 2 and (link_lines / len(lines)) >= 0.70:
        return True
    return False


def _prune_link_density_lists(text: str) -> str:
    """Detects and prunes list blocks and link clumps that are overwhelmingly links."""
    paragraphs = text.split('\n\n')
    cleaned_paragraphs = []
    for p in paragraphs:
        lines = [l.strip() for l in p.split('\n') if l.strip()]
        if _is_high_link_density_block(lines):
            continue
        cleaned_paragraphs.append(p)
    return '\n\n'.join(cleaned_paragraphs).strip()


def _strip_trailing_boilerplate_blocks(text: str) -> str:
    """Removes trailing UI buttons, tracking pixels, and copyright blocks from the bottom up."""
    paragraphs = text.split('\n\n')
    while paragraphs:
        last = paragraphs[-1].strip()
        if not last:
            paragraphs.pop()
            continue
        if TRACKING_PIXEL_REGEX.search(last):
            paragraphs.pop()
            continue
        if last.lower() in {
            'translate', 'share', 'change font size', 'print', 'back to top',
            'write for us', 'email signup', 'channels', 'download the app',
            'loading the next article', 'error loading the next article', '✕', 'close',
            'submit'
        }:
            paragraphs.pop()
            continue
        if re.search(r'(?i)^(?:copyright\s*©|©\s*\d{4}|all rights reserved|.*© copyright \d{4}.*all rights reserved\.?)$', last):
            paragraphs.pop()
            continue
        break
    return '\n\n'.join(paragraphs).strip()


def _deduplicate_paragraphs(text: str) -> str:
    """
    Code-safe paragraph deduplication: drops duplicate text blocks while
    preserving all code fences, markdown headings, and short lines.
    """
    paragraphs = text.split('\n\n')
    retained = []
    in_code_block = False

    for p in paragraphs:
        p_stripped = p.strip()
        lines = p_stripped.split('\n')
        code_fence_count = sum(1 for l in lines if l.strip().startswith('```'))
        if in_code_block:
            retained.append(p)
            if code_fence_count % 2 == 1:
                in_code_block = False
            continue

        if code_fence_count % 2 == 1:
            in_code_block = True
            retained.append(p)
            continue

        # Bypass deduplication for headings and short items
        if p_stripped.startswith('#') or len(p_stripped) < 40:
            retained.append(p)
            continue

        p_lower = p_stripped.lower()
        is_dup = False
        for prev in retained[-5:]:
            prev_lower = prev.strip().lower()
            if p_lower == prev_lower or (len(p_stripped) > 80 and p_lower in prev_lower):
                is_dup = True
                break

        if not is_dup:
            retained.append(p)

    return '\n\n'.join(retained).strip()


def extract_normalized_shingles(text: str, k: int = 5) -> set[tuple[str, ...]]:
    """
    Tokenizes text into k-word shingles after stripping links and markdown syntax.
    Used for syndicated wire deduplication via Jaccard similarity.
    """
    stripped = re.sub(r'\[([^\]]+)\]\([^\)]+\)', r'\1', text)
    stripped = re.sub(r'[`#*_]', '', stripped)
    words = re.findall(r'\b[a-z0-9]+\b', stripped.lower())[:300]
    if len(words) < k:
        return set()
    return {tuple(words[i:i + k]) for i in range(len(words) - k + 1)}


def clean_markdown_article(raw_markdown: str, title: str = "") -> Tuple[str, bool]:
    """
    Cleans raw Markdown content by removing CMS widgets, promo callouts, images, and link lists.
    Signature: raw_markdown is 1st argument, title is 2nd argument.
    Returns (cleaned_text, was_truncated).
    """
    if not raw_markdown or len(raw_markdown.strip()) == 0:
        return "", False

    original_length = len(raw_markdown)
    processed = raw_markdown.strip()

    # Pre-cleaning Context-Safe Rejection Gates
    if _is_error_or_bot_page(processed):
        logger.info("[Sanitizer] Rejected bot challenge or error page: %s", title[:40])
        return "", False

    if _is_paywall_stub(processed):
        logger.info("[Sanitizer] Rejected paywall stub: %s", title[:40])
        return "", False

    # Pass 0: Unicode Normalization, Raw HTML Stripping & Markdown Image Pruning
    processed = _clean_unicode_and_html(processed)
    processed = _strip_markdown_images(processed)

    # Pass 1: Strip leading bylines, standalone links, cookie notices, and nav remnants
    processed = _strip_leading_boilerplate(processed, title=title)

    # Pass 2: Two-Tier Tail Truncation
    was_truncated = False
    earliest_tail_start = None

    # Tier 2A: Strong exit headings (>= 500 chars AND >= 45% of document depth)
    for m in STRONG_TAIL_REGEX.finditer(processed):
        min_depth = min(500, int(len(processed) * 0.45))
        if m.start() >= min_depth and m.start() >= (len(processed) * 0.45):
            if earliest_tail_start is None or m.start() < earliest_tail_start:
                earliest_tail_start = m.start()
            break

    # Tier 2B: Weak closing markers (>= 500 chars AND >= 50% document depth)
    for m in WEAK_TAIL_REGEX.finditer(processed):
        if m.start() >= 500 and m.start() >= (len(processed) * 0.50):
            if earliest_tail_start is None or m.start() < earliest_tail_start:
                earliest_tail_start = m.start()
            break

    if earliest_tail_start is not None:
        processed = processed[:earliest_tail_start].strip()
        was_truncated = True

    # Pass 3: Strip inline promotional banners line-by-line
    processed = INLINE_BOILERPLATE_REGEX.sub('', processed)
    processed = COOKIE_BANNER_REGEX.sub('', processed)
    processed = PAYWALL_BLOCK_REGEX.sub('', processed)

    # Pass 4: Prune high-density link lists and clumps
    processed = _prune_link_density_lists(processed)

    # Pass 5: Strip trailing boilerplate blocks from bottom up
    processed = _strip_trailing_boilerplate_blocks(processed)

    # Pass 6: Code-safe paragraph deduplication
    processed = _deduplicate_paragraphs(processed)

    # Normalize excessive newlines
    processed = re.sub(r'\n{3,}', '\n\n', processed).strip()

    # Post-cleaning UI / Sidebar Dump Rejection Gate
    if _is_ui_or_sidebar_dump(processed, title=title):
        logger.info("[Sanitizer] Rejected UI/sidebar dump lacking prose: %s", title[:40])
        return "", False

    # Safety Guardrail: Prevent catastrophic over-truncation
    if len(processed) < 250 and original_length >= 600:
        if earliest_tail_start is not None and earliest_tail_start >= 400:
            return raw_markdown[:earliest_tail_start].strip(), True
        if len(processed) >= 80:
            return processed, was_truncated
        logger.warning(
            "[Sanitizer] Cleaning resulted in excessively short article (%d chars from %d). Reverting safely.",
            len(processed), original_length
        )
        return raw_markdown.strip(), False

    return processed, was_truncated


def clean_article_markdown(title: str, text: str) -> str:
    """
    Backward-compatible helper returning cleaned text string.
    Signature: title is 1st argument, text is 2nd argument.
    """
    cleaned, _ = clean_markdown_article(text, title=title)
    return cleaned
