import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// JSON documents on the device (Hive CE: IndexedDB on the web).
///
/// Each box maps a string key to one JSON object. When storage cannot be
/// opened (private tab, blocked site data, tests) everything is kept in
/// memory for the session instead, so callers never see an error.
class LocalStore {
  LocalStore._(this._boxes);

  /// A store that never touches the disk (tests, storage unavailable).
  LocalStore.memory() : _boxes = {};

  /// Offline accounts: user id → user JSON + follows + interactions.
  static const users = 'offline_users';

  /// Offline sessions: token → `{"user_id": …}`.
  static const sessions = 'offline_sessions';

  /// Comments written offline: article id → `{"items": [...]}`.
  static const comments = 'offline_comments';

  /// Stories the live server sent: article id → article JSON.
  static const freshArticles = 'fresh_articles';

  /// Users the live server sent (so a live session can fall back): id → JSON.
  static const liveUsers = 'live_users';

  static const _all = [users, sessions, comments, freshArticles, liveUsers];

  /// Opened Hive boxes; a missing name means that box lives in [_memory].
  final Map<String, Box<String>> _boxes;
  final Map<String, Map<String, Map<String, dynamic>>> _memory = {};

  static Future<LocalStore>? _opening;

  /// The device store, opened once.
  static Future<LocalStore> open() => _opening ??= _open();

  static Future<LocalStore> _open() async {
    final boxes = <String, Box<String>>{};
    try {
      await Hive.initFlutter();
      for (final name in _all) {
        boxes[name] = await Hive.openBox<String>(name);
      }
    } catch (_) {
      // Storage unavailable: the boxes that did not open stay in memory.
    }
    return LocalStore._(boxes);
  }

  Map<String, Map<String, dynamic>> _mem(String box) =>
      _memory.putIfAbsent(box, () => {});

  Map<String, dynamic>? get(String box, String key) {
    // Memory first: it also holds writes that failed to reach the disk.
    final kept = _mem(box)[key];
    if (kept != null) return kept;
    final raw = _boxes[box]?.get(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  /// Every document of [box].
  Map<String, Map<String, dynamic>> all(String box) {
    final out = <String, Map<String, dynamic>>{};
    for (final key in _boxes[box]?.keys ?? const []) {
      final doc = get(box, '$key');
      if (doc != null) out['$key'] = doc;
    }
    return out..addAll(_mem(box));
  }

  Future<void> put(String box, String key, Map<String, dynamic> value) async {
    final hive = _boxes[box];
    if (hive == null) {
      _mem(box)[key] = value;
      return;
    }
    try {
      await hive.put(key, jsonEncode(value));
      _mem(box).remove(key);
    } catch (_) {
      // Quota or a closed box: keep it for this session at least.
      _mem(box)[key] = value;
    }
  }

  Future<void> putAll(
    String box,
    Map<String, Map<String, dynamic>> docs,
  ) async {
    final hive = _boxes[box];
    if (hive == null) {
      _mem(box).addAll(docs);
      return;
    }
    try {
      await hive.putAll({
        for (final e in docs.entries) e.key: jsonEncode(e.value),
      });
      _mem(box).removeWhere((k, _) => docs.containsKey(k));
    } catch (_) {
      _mem(box).addAll(docs);
    }
  }

  Future<void> delete(String box, String key) async {
    _mem(box).remove(key);
    try {
      await _boxes[box]?.delete(key);
    } catch (_) {}
  }

  Future<void> deleteAll(String box, Iterable<String> keys) async {
    final list = keys.toList();
    _mem(box).removeWhere((k, _) => list.contains(k));
    try {
      await _boxes[box]?.deleteAll(list);
    } catch (_) {}
  }
}
