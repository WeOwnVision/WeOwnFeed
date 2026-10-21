import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_models.dart';

/// SharedPreferences (localStorage on web) backed article cache.
///
/// Keeps articles minimal: only the feed list is stored. When the API responds
/// successfully the cache is replaced entirely; when the server is down the
/// last real feed is served instead. Sample stories (data/seed_articles.dart)
/// are never shown as news; they are kept for the planned offline mode.
class LocalCache {
  LocalCache(this._prefs);

  static const _kArticles = 'cached_articles';
  static const _kSource = 'cache_source';

  final SharedPreferences _prefs;

  /// Whether the current cache comes from the real API.
  bool get isFromServer => _prefs.getString(_kSource) == 'server';

  /// Load cached articles; empty when nothing was cached yet.
  List<Article> loadArticles() {
    final raw = _prefs.getStringList(_kArticles);
    if (raw == null || raw.isEmpty) return [];
    try {
      return raw
          .map((s) => Article.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Replace the entire cache with fresh server data.
  Future<void> saveArticles(List<Article> articles) async {
    final encoded = articles.map((a) => jsonEncode(a.toJson())).toList();
    await _prefs.setStringList(_kArticles, encoded);
    await _prefs.setString(_kSource, 'server');
  }

  /// Clear cached articles (e.g. on sign-out, so the next user never sees
  /// the previous user's feed).
  Future<void> clear() async {
    await _prefs.remove(_kArticles);
    await _prefs.remove(_kSource);
  }
}
