/// Offline personal ranking by tags (the server ranks with vectors, which the
/// browser cannot compute). Works on the server's article JSON.
library;

/// What a user's feed is ranked by.
class RankProfile {
  const RankProfile({
    this.macros = const [],
    this.micros = const [],
    this.follows = const [],
    this.likedTags = const {},
    this.hidden = const {},
  });

  final List<String> macros;
  final List<String> micros;

  /// "+" follow names, matched in the title and summary.
  final List<String> follows;

  /// Subtopic tags of liked stories → how many liked stories carry them.
  final Map<String, int> likedTags;

  /// Disliked story ids: never shown in the personal feed.
  final Set<String> hidden;

  bool get isEmpty => macros.isEmpty && micros.isEmpty && follows.isEmpty;
}

/// A ranked story and the server-like fields the feed sends with it.
class RankedArticle {
  const RankedArticle(this.json, this.score, this.matchedFollows);

  final Map<String, dynamic> json;
  final double score;
  final List<String> matchedFollows;
}

List<String> macroTagsOf(Map<String, dynamic> a) {
  final tags = a['macro_tags'];
  final list = tags is List ? tags.whereType<String>().toList() : <String>[];
  final primary = a['macro_tag'];
  if (primary is String && primary.isNotEmpty && !list.contains(primary)) {
    list.insert(0, primary);
  }
  return list;
}

List<String> microTagsOf(Map<String, dynamic> a) {
  final tags = a['micro_tags'];
  return tags is List ? tags.whereType<String>().toList() : const [];
}

DateTime? publishedAtOf(Map<String, dynamic> a) =>
    DateTime.tryParse('${a['published_at'] ?? a['created_at'] ?? ''}');

/// Newest first; stories without a date last.
int compareByDate(Map<String, dynamic> a, Map<String, dynamic> b) {
  final da = publishedAtOf(a), db = publishedAtOf(b);
  if (da == null || db == null) return da == null ? (db == null ? 0 : 1) : -1;
  return db.compareTo(da);
}

/// Can the story be shown at all (enriched, on topic)?
bool isShowable(Map<String, dynamic> a) {
  final tldr = a['tldr'];
  return tldr is String &&
      tldr.trim().isNotEmpty &&
      !macroTagsOf(a).contains('Off-Topic');
}

List<String> matchedFollows(Map<String, dynamic> a, List<String> follows) {
  if (follows.isEmpty) return const [];
  final text = '${a['title'] ?? ''} ${a['tldr'] ?? ''}'.toLowerCase();
  return [
    for (final f in follows)
      if (f.trim().isNotEmpty &&
          RegExp(
            '\\b${RegExp.escape(f.trim().toLowerCase())}\\b',
          ).hasMatch(text))
        f,
  ];
}

/// Topic score: subtopic > follow > category, plus likes and freshness.
/// 0 means the story matches none of the picks.
double topicScore(
  Map<String, dynamic> a,
  RankProfile p, {
  required DateTime now,
  List<String>? follows,
}) {
  final micros = microTagsOf(a);
  final macros = macroTagsOf(a);
  final microHits = micros.where(p.micros.contains).length;
  final macroHit = macros.any(p.macros.contains);
  final followHits = (follows ?? matchedFollows(a, p.follows)).length;
  if (microHits == 0 && !macroHit && followHits == 0) return 0;
  var score = microHits * 12.0 + followHits * 15.0 + (macroHit ? 8.0 : 0);
  for (final t in micros) {
    score += (p.likedTags[t] ?? 0).clamp(0, 3) * 3.0;
  }
  final date = publishedAtOf(a);
  if (date != null) {
    final days = now.difference(date).inHours / 24;
    score += (10 - days).clamp(0, 10);
  }
  return score;
}

/// The personal feed: matching stories by score (then date). If fewer than
/// [minMatches] match, the newest other stories follow so the feed is never
/// thin.
List<RankedArticle> rankFeed(
  Iterable<Map<String, dynamic>> articles,
  RankProfile p, {
  DateTime? now,
  int minMatches = 30,
}) {
  final at = now ?? DateTime.now();
  final matched = <RankedArticle>[];
  final rest = <RankedArticle>[];
  for (final a in articles) {
    if (!isShowable(a) || p.hidden.contains(a['id'])) continue;
    final follows = matchedFollows(a, p.follows);
    final score = topicScore(a, p, now: at, follows: follows);
    (score > 0 ? matched : rest).add(RankedArticle(a, score, follows));
  }
  matched.sort((x, y) {
    final s = y.score.compareTo(x.score);
    return s != 0 ? s : compareByDate(x.json, y.json);
  });
  if (matched.length >= minMatches) return matched;
  rest.sort((x, y) => compareByDate(x.json, y.json));
  return [...matched, ...rest];
}

/// `personal_score` for the "76% match" badge: 50–99 relative to the best.
int matchPercent(double score, double best) {
  if (score <= 0 || best <= 0) return 50;
  return (50 + 49 * (score / best)).round().clamp(50, 99);
}

/// The index of the profile whose picks are closest to [macros]/[micros]
/// (shared categories weigh most); -1 when [profiles] is empty.
int closestProfile(
  List<String> macros,
  List<String> micros,
  List<({List<String> macros, List<String> micros})> profiles,
) {
  var best = -1;
  var bestScore = -1.0;
  for (var i = 0; i < profiles.length; i++) {
    final p = profiles[i];
    final shared = p.macros.where(macros.contains).length;
    final sharedMicro = p.micros.where(micros.contains).length;
    final extra = p.macros.where((m) => !macros.contains(m)).length;
    // The user's first category decides ties: it is their main interest.
    final first = macros.isNotEmpty && p.macros.contains(macros.first) ? 1 : 0;
    final score = shared * 10.0 + sharedMicro * 2 + first * 3 - extra * 4;
    if (score > bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return best;
}
