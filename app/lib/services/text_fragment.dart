/// Links that open a page scrolled to a quote, with the quote highlighted
/// (URL text fragments, `#:~:text=`; Chrome, Edge, Safari and current
/// Firefox). A browser that finds no match just opens the page.
library;

/// [url] opened at [quote]. Long quotes use the `start,end` form (first and
/// last words), which tolerates small differences in the middle, such as
/// quotes or spacing the page renders differently.
String quoteLink(String url, String quote) {
  final words = _clean(quote).split(' ').where((w) => w.isNotEmpty).toList();
  final base = url.split('#').first;
  if (words.isEmpty) return base;
  const edge = 4;
  final fragment = words.length <= edge * 2
      ? _encode(words.join(' '))
      : '${_encode(words.take(edge).join(' '))},'
            '${_encode(words.skip(words.length - edge).join(' '))}';
  return '$base#:~:text=$fragment';
}

/// The quote inside an evidence line such as
/// `Corroborated by cnbc.com: "…" (2 independent origin(s))`; older Fact
/// Check results have no separate quote field.
String? quoteFromSummary(String summary) {
  final m = RegExp(r'"([^"]{12,})"').firstMatch(summary);
  return m?.group(1)?.trim();
}

/// Markdown marks and links out; the server cuts quotes at 150 characters,
/// so a cut-off last word is dropped (a fragment must match whole words).
String _clean(String quote) {
  // Spans come from the page's Markdown, so a quote can start inside a link
  // or table ("] The percentage…", "| Claim |"); the page shows neither.
  var t = quote
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[*_`#>\[\]|]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  if (quote.trim().length >= 150 && t.contains(' ')) {
    t = t.substring(0, t.lastIndexOf(' '));
  }
  return t.replaceAll(RegExp(r'[\s.,;:…]+$'), '');
}

/// Percent-encodes a fragment term; `-`, `,` and `&` have a meaning in the
/// fragment syntax, so they are encoded too.
String _encode(String s) => Uri.encodeComponent(
  s,
).replaceAll('-', '%2D').replaceAll(',', '%2C').replaceAll('&', '%26');
