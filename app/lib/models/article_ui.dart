import 'api_models.dart';

/// Derived fields of [Article] used by the UI.
extension ArticleUi on Article {
  /// Primary category shown on the badge.
  String get category =>
      macroTags.isNotEmpty ? macroTags.first : (macroTag ?? 'News');

  /// Card summary: the TL;DR, otherwise the start of the full text.
  String get summary {
    final t = tldr?.trim();
    if (t != null && t.isNotEmpty) return t;
    final text = cleanText?.trim() ?? '';
    return text.length > 280 ? '${text.substring(0, 280)}…' : text;
  }

  /// "5 min ago", "3 hr ago", "2 days ago", "Oct 8".
  String get timeAgo {
    final p = publishedAt;
    if (p == null) return '';
    final diff = DateTime.now().difference(p.toLocal());
    if (diff.isNegative || diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    if (diff.inDays < 7) {
      return diff.inDays == 1 ? '1 day ago' : '${diff.inDays} days ago';
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final l = p.toLocal();
    return '${months[l.month - 1]} ${l.day}';
  }

  /// Estimated reading time (minutes) if there is full text; otherwise `null`.
  int? get readMinutes {
    final text = cleanText;
    if (text == null || text.trim().isEmpty) return null;
    final words = text.trim().split(RegExp(r'\s+')).length;
    return (words / 220).ceil().clamp(1, 99);
  }

  /// Whether other outlets covered this same story.
  bool get hasAlsoPublished =>
      alsoPublishedByCount > 0 && alsoPublishedBy.isNotEmpty;

  /// Single standardized line: "Also published by IGN, Kotaku and 5 more".
  String get alsoPublishedLine {
    if (alsoPublishedByCount <= 0 || alsoPublishedBy.isEmpty) return '';
    final outlets = <String>[];
    for (final item in alsoPublishedBy) {
      final s = item.source.trim();
      if (s.isNotEmpty && s != source && !outlets.contains(s)) {
        outlets.add(s);
      }
    }
    if (outlets.isEmpty) return '';
    if (outlets.length == 1) {
      return 'Also published by ${outlets[0]}';
    }
    if (outlets.length == 2 && alsoPublishedByCount <= 2) {
      return 'Also published by ${outlets[0]} and ${outlets[1]}';
    }
    final remaining = alsoPublishedByCount - 2;
    if (remaining > 0) {
      return 'Also published by ${outlets[0]}, ${outlets[1]} and $remaining more';
    }
    return 'Also published by ${outlets[0]} and ${outlets[1]}';
  }

  /// Relative offset compared to the primary article (+12m, +1h, 15m earlier).
  String formatSiblingOffset(DateTime? siblingDate) {
    if (siblingDate == null || publishedAt == null) return '';
    final diff = siblingDate.difference(publishedAt!);
    if (diff.isNegative) {
      final m = diff.inMinutes.abs();
      if (m < 60) return '${m}m earlier';
      final h = diff.inHours.abs();
      if (h < 24) return '${h}h earlier';
      return '${diff.inDays.abs()}d earlier';
    }
    final m = diff.inMinutes;
    if (m < 60) return '+${m}m';
    final h = diff.inHours;
    if (h < 24) return '+${h}h';
    return '+${diff.inDays}d';
  }

  /// The resolved real image; otherwise a placeholder for the category.
  String get image {
    final netImg = imageUrl?.trim();
    if (netImg != null && netImg.startsWith('http') && !_isFavicon(netImg)) {
      return netImg;
    }
    final options = _placeholders[category] ?? _fallback;
    final hash = id.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff);
    return options[hash % options.length];
  }

  bool get hasNetworkImage {
    final netImg = imageUrl?.trim();
    return netImg != null && netImg.startsWith('http') && !_isFavicon(netImg);
  }

  bool _isFavicon(String url) {
    if (imageStatus == 'favicon' || imageStatus == 'gradient_fallback') {
      return true;
    }
    final lower = url.toLowerCase();
    return lower.contains('google.com/s2/favicons') ||
        lower.endsWith('.ico') ||
        lower.contains('format=svg') ||
        lower.endsWith('.svg');
  }
}

const _dir = 'assets/images/news';

const _placeholders = <String, List<String>>{
  'Tech': ['$_dir/quantum_chip.jpg', '$_dir/smart_city.jpg'],
  'AI': ['$_dir/ai_law.jpg', '$_dir/medical_ai.jpg'],
  'Hardware': ['$_dir/quantum_chip.jpg', '$_dir/smart_city.jpg'],
  'Automotive': ['$_dir/smart_city.jpg', '$_dir/wind_energy.jpg'],
  'Gaming': ['$_dir/stadium.jpg', '$_dir/art_biennial.jpg'],
  'Finance': ['$_dir/central_bank.jpg'],
  'Science': ['$_dir/exoplanet.jpg', '$_dir/moon_rocket.jpg'],
};

const _fallback = [
  'assets/images/headline.jpg',
  '$_dir/wind_energy.jpg',
  '$_dir/art_biennial.jpg',
];
