import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Server data bundled with the app (`assets/offline/snapshot.json`), written
/// by `tool/export_snapshot.dart` from a running server. Read-only: the same
/// for every visitor. All values are the server's own JSON.
class OfflineSnapshot {
  const OfflineSnapshot({
    this.generatedAt,
    this.taxonomy = const [],
    this.articles = const {},
    this.research = const {},
    this.comments = const {},
    this.digests = const {},
    this.profiles = const [],
    this.tavilyCalls = const [],
    this.ingestionStatus = const {},
    this.telemetry = const {},
  });

  static const assetPath = 'assets/offline/snapshot.json';

  static const empty = OfflineSnapshot();

  final DateTime? generatedAt;

  /// `GET /api/taxonomy`.
  final List<Map<String, dynamic>> taxonomy;

  /// `GET /api/articles/{id}` by id (full text and saved Fact Check included).
  final Map<String, Map<String, dynamic>> articles;

  /// `GET /api/articles/{id}/deep-inspect/research` by article id.
  final Map<String, Map<String, dynamic>> research;

  /// `GET /api/articles/{id}/comments` by article id.
  final Map<String, List<Map<String, dynamic>>> comments;

  /// `GET /api/intelligence/daily-digest` by category; `_all` = no category.
  final Map<String, Map<String, dynamic>> digests;

  /// The harvest profiles and their "Latest developments" cards.
  final List<SnapshotProfile> profiles;

  /// `GET /api/tavily/calls` items, oldest first.
  final List<Map<String, dynamic>> tavilyCalls;

  /// `GET /api/ingestion/status`.
  final Map<String, dynamic> ingestionStatus;

  /// `GET /api/system/telemetry`.
  final Map<String, dynamic> telemetry;

  static Future<OfflineSnapshot>? _loading;

  /// The bundled snapshot, decoded once. A missing or broken asset gives
  /// [empty], so the app still opens.
  static Future<OfflineSnapshot> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<OfflineSnapshot> _load(AssetBundle bundle) async {
    try {
      final text = await bundle.loadString(assetPath, cache: false);
      final json = jsonDecode(text);
      return json is Map<String, dynamic>
          ? OfflineSnapshot.fromJson(json)
          : empty;
    } catch (_) {
      return empty;
    }
  }

  factory OfflineSnapshot.fromJson(Map<String, dynamic> json) {
    return OfflineSnapshot(
      generatedAt: DateTime.tryParse('${json['generated_at']}'),
      taxonomy: _maps(json['taxonomy']),
      articles: _mapOfMaps(json['articles']),
      research: _mapOfMaps(json['research']),
      comments: {
        for (final e in _map(json['comments']).entries) e.key: _maps(e.value),
      },
      digests: _mapOfMaps(json['digests']),
      profiles: _maps(json['profiles']).map(SnapshotProfile.fromJson).toList(),
      tavilyCalls: _maps(json['tavily_calls']),
      ingestionStatus: _map(json['ingestion_status']),
      telemetry: _map(json['telemetry']),
    );
  }
}

/// A harvest profile: its picks and the server's "Latest developments" card.
class SnapshotProfile {
  const SnapshotProfile({
    required this.username,
    required this.macros,
    required this.micros,
    required this.latest,
  });

  factory SnapshotProfile.fromJson(Map<String, dynamic> json) =>
      SnapshotProfile(
        username: '${json['username'] ?? ''}',
        macros: _strings(json['macros']),
        micros: _strings(json['micros']),
        latest: _map(json['latest']),
      );

  final String username;
  final List<String> macros;
  final List<String> micros;

  /// `GET /api/users/{id}/latest-developments`.
  final Map<String, dynamic> latest;
}

Map<String, dynamic> _map(Object? v) =>
    v is Map<String, dynamic> ? v : const {};

List<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

Map<String, Map<String, dynamic>> _mapOfMaps(Object? v) => {
  for (final e in _map(v).entries)
    if (e.value is Map<String, dynamic>) e.key: e.value as Map<String, dynamic>,
};

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];
