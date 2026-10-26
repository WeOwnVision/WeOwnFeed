import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'local_store.dart';
import 'ranking.dart';
import 'snapshot.dart';

/// The WeOwnFeed API answered inside the app, for sessions without a server.
///
/// Given to `ApiService` as its `http.Client`, it serves the endpoints the app
/// calls with the same JSON shapes and rules as the server: stories from the
/// bundled [OfflineSnapshot] (plus stories a live server sent earlier), and
/// accounts, picks, likes and comments from the [LocalStore]. AI and Tavily
/// endpoints answer 503; the UI hides their controls in offline sessions.
class OfflineBackend extends http.BaseClient {
  OfflineBackend({
    Future<OfflineSnapshot>? snapshot,
    Future<LocalStore>? store,
    DateTime Function()? clock,
  }) : _snapshotFuture = snapshot ?? OfflineSnapshot.load(),
       _storeFuture = store ?? LocalStore.open(),
       _clock = clock ?? DateTime.now;

  /// Prefix of offline session tokens; a live server never issues it.
  static const tokenPrefix = 'off.';

  /// Fresh server stories kept on the device: newest N, at most this old.
  static const freshLimit = 1500;
  static const freshMaxAge = Duration(days: 30);

  static const _offlineDetail = 'Not available in the offline demo.';

  final Future<OfflineSnapshot> _snapshotFuture;
  final Future<LocalStore> _storeFuture;
  final DateTime Function() _clock;
  final _random = Random.secure();

  late OfflineSnapshot _snapshot;
  late LocalStore _store;

  /// Snapshot stories with the fresh server stories laid over them.
  Map<String, Map<String, dynamic>>? _articles;
  Future<void>? _ready;

  Future<void> get ready => _ready ??= _init();

  Future<void> _init() async {
    _snapshot = await _snapshotFuture;
    _store = await _storeFuture;
    _articles = {
      ..._snapshot.articles,
      ..._store.all(LocalStore.freshArticles),
    };
  }

  /// Saves stories a live server sent, newest kept (see [freshLimit] and
  /// [freshMaxAge]). Fields that belong to one user's feed are dropped.
  Future<void> addFresh(Iterable<Map<String, dynamic>> items) async {
    final store = await _storeFuture;
    final docs = <String, Map<String, dynamic>>{};
    for (final raw in items) {
      final id = raw['id'];
      if (id is! String || id.isEmpty) continue;
      final clean = Map<String, dynamic>.of(raw)
        ..removeWhere((k, _) => _personalFields.contains(k));
      // A list item has no full text: keep the one saved earlier.
      final previous =
          store.get(LocalStore.freshArticles, id) ?? _articles?[id];
      docs[id] = {...?previous, ...clean};
    }
    if (docs.isEmpty) return;
    await store.putAll(LocalStore.freshArticles, docs);
    _articles?.addAll(docs);
    // Pruning reads every saved story, so it runs at most once a minute.
    final now = _clock();
    if (_lastPrune == null || now.difference(_lastPrune!) > pruneInterval) {
      _lastPrune = now;
      await _prune(store);
    }
  }

  static const pruneInterval = Duration(minutes: 1);
  DateTime? _lastPrune;

  static const _personalFields = {
    'personal_score',
    'is_liked',
    'matched_follows',
    'matched_sites',
    'relevance_score',
    'match_tier',
    'possibility',
    'explore_angle',
  };

  Future<void> _prune(LocalStore store) async {
    final fresh = store.all(LocalStore.freshArticles);
    final cutoff = _clock().subtract(freshMaxAge);
    final ordered = fresh.values.toList()..sort(compareByDate);
    final drop = <String>{
      for (var i = 0; i < ordered.length; i++)
        if (i >= freshLimit ||
            (publishedAtOf(ordered[i])?.isBefore(cutoff) ?? false))
          '${ordered[i]['id']}',
    };
    if (drop.isEmpty) return;
    await store.deleteAll(LocalStore.freshArticles, drop);
    // Not loaded yet (live session): the next load reads the store anyway.
    if (_articles == null) return;
    // The bundled copy (if any) shows again in place of the dropped one.
    for (final id in drop) {
      final bundled = _snapshot.articles[id];
      if (bundled != null) {
        _articles![id] = bundled;
      } else {
        _articles!.remove(id);
      }
    }
  }

  // ==========================================================================
  // http.Client
  // ==========================================================================

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await ready;
    final body = request is http.Request ? request.body : '';
    final auth = request.headers['Authorization'] ?? '';
    final token = auth.startsWith('Bearer ') ? auth.substring(7) : null;
    _Reply reply;
    try {
      reply = await _route(request.method, request.url, body, token);
    } catch (e) {
      reply = _Reply.error(500, 'Offline backend error: $e');
    }
    final bytes = utf8.encode(reply.body);
    return http.StreamedResponse(
      Stream.value(bytes),
      reply.status,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': reply.contentType},
    );
  }

  Future<_Reply> _route(
    String method,
    Uri url,
    String rawBody,
    String? token,
  ) async {
    final p = url.pathSegments;
    final q = url.queryParameters;
    Map<String, dynamic> body() {
      if (rawBody.isEmpty) return const {};
      final json = jsonDecode(rawBody);
      return json is Map<String, dynamic> ? json : const {};
    }

    bool at(List<String> pattern, [String? verb]) {
      if (verb != null && verb != method) return false;
      if (pattern.length != p.length) return false;
      for (var i = 0; i < pattern.length; i++) {
        if (pattern[i] != '*' && pattern[i] != p[i]) return false;
      }
      return true;
    }

    if (at(['api', 'taxonomy'], 'GET')) return _Reply.json(_snapshot.taxonomy);

    // --- auth ---------------------------------------------------------------
    if (at(['api', 'auth', 'login'], 'POST') ||
        at(['api', 'auth', 'register'], 'POST')) {
      return _signIn(body());
    }
    if (at(['api', 'auth', 'me'], 'GET')) {
      final user = _sessionUser(token);
      return user == null
          ? _Reply.error(401, 'Not signed in')
          : _Reply.json(_userJson(user));
    }
    if (at(['api', 'auth', 'logout'], 'POST')) {
      if (token != null) await _store.delete(LocalStore.sessions, token);
      return _Reply.noContent;
    }

    // --- stories ------------------------------------------------------------
    if (at(['api', 'articles'], 'GET')) return _articleList(q);
    if (at(['api', 'articles', '*'], 'GET')) {
      final a = _articles![p[2]];
      return a == null
          ? _Reply.error(404, 'Article not found')
          : _Reply.json(a);
    }
    if (at(['api', 'articles', '*', 'comments'], 'GET')) {
      return _Reply.json(_comments(p[2]));
    }
    if (at(['api', 'articles', '*', 'comments'], 'POST')) {
      return _addComment(p[2], body());
    }
    if (at(['api', 'articles', '*', 'interactions'], 'POST')) {
      return _interaction(p[2], body());
    }
    if (at(['api', 'articles', '*', 'deep-inspect'], 'POST')) {
      return _factCheck(p[2]);
    }
    if (at(['api', 'articles', '*', 'deep-inspect', 'research'])) {
      final r = _snapshot.research[p[2]];
      if (r != null) return _Reply.json(r);
      return method == 'GET'
          ? _Reply.json({'status': 'none'})
          : _Reply.error(503, _offlineDetail);
    }
    if (at(['api', 'search'], 'GET')) return _search(q);

    // --- personalization ----------------------------------------------------
    if (at(['api', 'feed', 'personalized'], 'GET')) return _feed(q);
    if (p.length >= 4 && p[0] == 'api' && p[1] == 'users') {
      final user = _user(p[2]);
      if (user == null) return _Reply.error(404, 'User not found');
      if (at(['api', 'users', '*', 'preferences'], 'GET')) {
        return _Reply.json(_userJson(user));
      }
      if (at(['api', 'users', '*', 'preferences'], 'PUT')) {
        return _savePreferences(user, body());
      }
      if (at(['api', 'users', '*', 'follows'], 'GET')) {
        return _Reply.json(_follows(user));
      }
      if (at(['api', 'users', '*', 'follows'], 'POST')) {
        return _addFollow(user, body());
      }
      if (at(['api', 'users', '*', 'follows', '*'], 'DELETE')) {
        user['follows'] = [
          for (final f in _follows(user))
            if (f['id'] != p[4]) f,
        ];
        await _saveUser(user);
        return _Reply.json({'status': 'removed', 'id': p[4]});
      }
      if (at(['api', 'users', '*', 'sites'], 'GET')) return _Reply.json([]);
      if (at(['api', 'users', '*', 'sites', 'articles'], 'GET')) {
        return _Reply.json({'counts': {}, 'articles': []});
      }
      if (at(['api', 'users', '*', 'latest-developments'], 'GET')) {
        return _latest(user);
      }
    }
    if (at(['api', 'intelligence', 'daily-digest'], 'GET')) return _digest(q);

    // --- Tavily terminal ----------------------------------------------------
    if (at(['api', 'tavily', 'calls'], 'GET')) return _tavilyCalls(q);
    if (at(['api', 'ingestion', 'status'], 'GET')) {
      return _Reply.json(_snapshot.ingestionStatus);
    }
    if (at(['api', 'system', 'telemetry'], 'GET')) {
      return _Reply.json(_snapshot.telemetry);
    }

    // Chat, WAI, synthesis, live search, site follows: need the server.
    return _Reply.error(503, _offlineDetail);
  }

  // ==========================================================================
  // Accounts
  // ==========================================================================

  Future<_Reply> _signIn(Map<String, dynamic> body) async {
    final username = '${body['username'] ?? ''}'.trim();
    final password = '${body['password'] ?? ''}';
    if (username.isEmpty || username.length > 50 || password.isEmpty) {
      return _Reply.error(400, 'Enter a username (up to 50 characters).');
    }
    var user = _store
        .all(LocalStore.users)
        .values
        .where((u) => u['username'] == username)
        .firstOrNull;
    if (user == null) {
      user = {
        'id': _uuid(),
        'username': username,
        'avatar_url': null,
        'created_at': _clock().toUtc().toIso8601String(),
        'onboarding_completed': false,
        'preferred_macro_tags': <String>[],
        'preferred_micro_tags': <String>[],
        'interest_context': null,
      };
      await _saveUser(user);
    }
    final token = '$tokenPrefix${_hex(24)}';
    await _store.put(LocalStore.sessions, token, {'user_id': user['id']});
    return _Reply.json({'token': token, 'user': _userJson(user)});
  }

  Map<String, dynamic>? _sessionUser(String? token) {
    if (token == null) return null;
    final session = _store.get(LocalStore.sessions, token);
    final id = session?['user_id'];
    return id is String ? _store.get(LocalStore.users, id) : null;
  }

  /// An offline account, or a user a live server sent earlier (read-only).
  Map<String, dynamic>? _user(String id) {
    final local = _store.get(LocalStore.users, id);
    if (local != null) return Map.of(local);
    final live = _store.get(LocalStore.liveUsers, id);
    return live == null ? null : {...live, '_live': true};
  }

  Future<void> _saveUser(Map<String, dynamic> user) async {
    if (user['_live'] == true) return;
    await _store.put(LocalStore.users, '${user['id']}', user);
  }

  static Map<String, dynamic> _userJson(Map<String, dynamic> u) => {
    'id': u['id'],
    'username': u['username'],
    'avatar_url': u['avatar_url'],
    'created_at': u['created_at'],
    'onboarding_completed': u['onboarding_completed'] == true,
    'preferred_macro_tags': _strings(u['preferred_macro_tags']),
    'preferred_micro_tags': _strings(u['preferred_micro_tags']),
    'interest_context': u['interest_context'],
  };

  Future<_Reply> _savePreferences(
    Map<String, dynamic> user,
    Map<String, dynamic> body,
  ) async {
    final known = [
      for (final c in _snapshot.taxonomy)
        if (c['macro'] is String) c['macro'] as String,
    ];
    final asked = _strings(body['preferred_macro_tags']);
    final macros = <String>[];
    for (final m in asked) {
      for (final k in known) {
        if (k.toLowerCase() == m.trim().toLowerCase() && !macros.contains(k)) {
          macros.add(k);
        }
      }
    }
    if (macros.isEmpty && asked.isNotEmpty && known.isNotEmpty) {
      macros.add(known.first);
    }
    final micros = <String>[];
    for (final t in _strings(body['preferred_micro_tags'])) {
      final tag = t.trim();
      if (tag.isNotEmpty && !micros.contains(tag)) micros.add(tag);
      if (micros.length == 12) break;
    }
    // interest_context: absent = keep, empty = clear, text = set.
    if (body.containsKey('interest_context')) {
      final text = '${body['interest_context'] ?? ''}'.trim();
      user['interest_context'] = text.isEmpty
          ? null
          : (text.length > 200 ? text.substring(0, 200) : text);
    }
    user
      ..['preferred_macro_tags'] = macros
      ..['preferred_micro_tags'] = micros
      ..['onboarding_completed'] = true;
    await _saveUser(user);
    final context = user['interest_context'] as String?;
    return _Reply.json({
      ..._userJson(user),
      'interest_summary': context ?? _standardInterestText(macros, micros),
    });
  }

  /// Same sentence the server builds when there is no context sentence.
  static String _standardInterestText(
    List<String> macros,
    List<String> micros,
  ) {
    var text = 'Technical news and updates in ${macros.join(', ')}';
    if (micros.isNotEmpty) {
      String title(String t) => t
          .replaceAll('_', ' ')
          .split(' ')
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
      text += ', specifically focused on ${micros.map(title).join(', ')}';
    }
    return '$text.';
  }

  static List<Map<String, dynamic>> _follows(Map<String, dynamic> user) =>
      (user['follows'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
      [];

  Future<_Reply> _addFollow(
    Map<String, dynamic> user,
    Map<String, dynamic> body,
  ) async {
    final name = '${body['name'] ?? ''}'.trim();
    final macro = '${body['macro'] ?? ''}'.trim();
    if (name.isEmpty) return _Reply.error(400, 'Enter what to follow.');
    final follows = _follows(user);
    final existing = follows
        .where((f) => '${f['name']}'.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (existing != null) return _Reply.json(existing);
    if (follows.length >= 3) {
      return _Reply.error(400, 'You can follow up to 3 things.');
    }
    final follow = {'id': _uuid(), 'name': name, 'macro': macro};
    user['follows'] = [...follows, follow];
    await _saveUser(user);
    return _Reply.json(follow);
  }

  // ==========================================================================
  // Stories
  // ==========================================================================

  Iterable<Map<String, dynamic>> get _showable =>
      _articles!.values.where(isShowable);

  static Map<String, dynamic> _listItem(Map<String, dynamic> a) =>
      Map.of(a)..remove('clean_text');

  static List<T> _page<T>(List<T> items, Map<String, String> q) {
    final size = (int.tryParse(q['page_size'] ?? '') ?? 20).clamp(1, 100);
    final page = max(1, int.tryParse(q['page'] ?? '') ?? 1);
    return items.skip((page - 1) * size).take(size).toList();
  }

  _Reply _articleList(Map<String, String> q) {
    final macro = q['macro'];
    final list =
        _showable
            .where((a) => macro == null || macroTagsOf(a).contains(macro))
            .toList()
          ..sort(compareByDate);
    return _Reply.json(_page(list, q).map(_listItem).toList());
  }

  RankProfile _rankProfile(Map<String, dynamic> user) {
    final interactions = _interactions(user);
    final liked = interactions['like'] ?? const [];
    final tags = <String, int>{};
    for (final id in liked) {
      final a = _articles![id];
      if (a == null) continue;
      for (final t in microTagsOf(a)) {
        tags[t] = (tags[t] ?? 0) + 1;
      }
    }
    return RankProfile(
      macros: _strings(user['preferred_macro_tags']),
      micros: _strings(user['preferred_micro_tags']),
      follows: [for (final f in _follows(user)) '${f['name']}'],
      likedTags: tags,
      hidden: {...?interactions['dislike'], ...?interactions['skip']},
    );
  }

  _Reply _feed(Map<String, String> q) {
    final user = _user(q['user_id'] ?? '');
    if (user == null) return _Reply.error(404, 'User not found');
    final profile = _rankProfile(user);
    final liked = (_interactions(user)['like'] ?? const []).toSet();
    final fallback = profile.isEmpty;
    final ranked = fallback
        ? [
            for (final a in _showable.toList()..sort(compareByDate))
              RankedArticle(a, 0, const []),
          ]
        : rankFeed(_showable, profile, now: _clock());
    final best = ranked.isEmpty ? 0.0 : ranked.first.score;
    return _Reply.json({
      'is_fallback': fallback,
      'articles': [
        for (final r in _page(ranked, q))
          {
            ..._listItem(r.json),
            'personal_score': fallback ? 50 : matchPercent(r.score, best),
            'is_liked': liked.contains(r.json['id']),
            'matched_follows': r.matchedFollows,
            'matched_sites': <String>[],
          },
      ],
    });
  }

  _Reply _search(Map<String, String> q) {
    final query = (q['q'] ?? '').trim();
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toList();
    final scored = <(Map<String, dynamic>, double)>[];
    for (final a in _showable) {
      final title = '${a['title'] ?? ''}'.toLowerCase();
      final tldr = '${a['tldr'] ?? ''}'.toLowerCase();
      final tags = [
        ...macroTagsOf(a),
        ...microTagsOf(a).map((t) => t.replaceAll('_', ' ')),
      ].join(' ').toLowerCase();
      final text = '${a['clean_text'] ?? ''}'.toLowerCase();
      var s = title.contains(query.toLowerCase()) ? 30.0 : 0.0;
      for (final t in terms) {
        if (title.contains(t)) s += 6;
        if (tldr.contains(t)) s += 3;
        if (tags.contains(t)) s += 4;
        if (text.contains(t)) s += 1;
      }
      if (s >= 6) scored.add((a, s));
    }
    scored.sort((x, y) {
      final c = y.$2.compareTo(x.$2);
      return c != 0 ? c : compareByDate(x.$1, y.$1);
    });
    final best = scored.isEmpty ? 1.0 : scored.first.$2;
    final hits = [
      for (final (a, s) in scored.take(20))
        {
          ..._listItem(a),
          'match_tier': 'direct',
          'relevance_score': (40 + 59 * s / best).round().clamp(40, 99),
          'possibility': 'Direct Focus',
        },
    ];
    if (q['grouped'] != 'true') return _Reply.json(hits);
    return _Reply.json({
      'query': query,
      'direct': hits,
      'explore': <Object>[],
      // Nothing more will arrive, so the page does not ask again.
      'semantic': true,
    });
  }

  List<Map<String, dynamic>> _comments(String articleId) => [
    ...?_snapshot.comments[articleId],
    ...?(_store.get(LocalStore.comments, articleId)?['items'] as List?)
        ?.whereType<Map<String, dynamic>>(),
  ];

  Future<_Reply> _addComment(
    String articleId,
    Map<String, dynamic> body,
  ) async {
    final text = '${body['comment_text'] ?? ''}'.trim();
    if (text.isEmpty) return _Reply.error(400, 'Comment cannot be empty');
    final user = _user('${body['user_id'] ?? ''}');
    final comment = {
      'id': _uuid(),
      'comment_text': text,
      'username': user?['username'] ?? '',
      'avatar_url': user?['avatar_url'],
      'selected_text': body['selected_text'],
      'created_at': _clock().toUtc().toIso8601String(),
    };
    final saved = _store.get(LocalStore.comments, articleId)?['items'];
    await _store.put(LocalStore.comments, articleId, {
      'items': [...?(saved as List?), comment],
    });
    return _Reply.json({
      'id': comment['id'],
      'created_at': comment['created_at'],
    });
  }

  static Map<String, List<String>> _interactions(Map<String, dynamic> user) {
    final raw = user['interactions'];
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        '${e.key}': e.value is List
            ? (e.value as List).whereType<String>().toList()
            : <String>[],
    };
  }

  /// The server's toggle rules (`POST /api/articles/{id}/interactions`).
  Future<_Reply> _interaction(
    String articleId,
    Map<String, dynamic> body,
  ) async {
    final user = _user('${body['user_id'] ?? ''}');
    if (user == null) return _Reply.error(404, 'User not found');
    final type = '${body['interaction_type'] ?? ''}';
    if (!const ['like', 'dislike', 'skip', 'bookmark', 'read'].contains(type)) {
      return _Reply.error(400, 'Invalid interaction type');
    }
    final all = _interactions(user);
    final list = all.putIfAbsent(type, () => []);
    if (list.contains(articleId)) {
      list.remove(articleId);
      user['interactions'] = all;
      await _saveUser(user);
      return _Reply.json({'active': false});
    }
    if (type == 'like') {
      all['dislike']?.remove(articleId);
      all['skip']?.remove(articleId);
    } else if (type == 'dislike' || type == 'skip') {
      all['like']?.remove(articleId);
    }
    list.add(articleId);
    user['interactions'] = all;

    List<String>? macros, micros;
    final article = _articles![articleId];
    if (article != null && const ['like', 'dislike', 'skip'].contains(type)) {
      macros = _strings(user['preferred_macro_tags']);
      micros = _strings(user['preferred_micro_tags']);
      final artMacro = article['macro_tag'];
      final artMicros = microTagsOf(article).take(2).toList();
      if (type == 'like') {
        if (artMacro is String &&
            artMacro != 'Off-Topic' &&
            !macros.contains(artMacro)) {
          macros.add(artMacro);
        }
        for (final t in artMicros) {
          if (t != 'off_topic' && !micros.contains(t)) micros.insert(0, t);
        }
        if (micros.length > 15) micros = micros.sublist(0, 15);
      } else {
        final remaining = micros.where((t) => !artMicros.contains(t)).toList();
        if (remaining.isNotEmpty) micros = remaining;
      }
      user
        ..['preferred_macro_tags'] = macros
        ..['preferred_micro_tags'] = micros;
    }
    await _saveUser(user);
    return _Reply.json({
      'active': true,
      'updated_preferred_macro_tags': macros,
      'updated_preferred_micro_tags': micros,
    });
  }

  /// The server's cached Fact Check stream: one status line, the result.
  _Reply _factCheck(String articleId) {
    final saved = _articles![articleId]?['fact_check_cache'];
    if (saved is! Map) {
      final error = jsonEncode({
        'message':
            'Fact Check is not available for this story in the offline demo.',
      });
      return _Reply('event: error\ndata: $error\n\n', contentType: _sse);
    }
    final result = {...saved, 'is_cached': true};
    return _Reply(
      'event: status\ndata: Retrieved verified receipts from local PostgreSQL cache\n\n'
      'event: final\ndata: ${jsonEncode(result)}\n\n'
      'data: [DONE]\n\n',
      contentType: _sse,
    );
  }

  static const _sse = 'text/event-stream';

  // ==========================================================================
  // Briefs
  // ==========================================================================

  _Reply _latest(Map<String, dynamic> user) {
    final macros = _strings(user['preferred_macro_tags']);
    final micros = _strings(user['preferred_micro_tags']);
    if (macros.isEmpty && micros.isEmpty) {
      return _Reply.error(409, 'Pick your interests first.');
    }
    final profiles = _snapshot.profiles
        .where((p) => p.latest.isNotEmpty)
        .toList();
    final i = closestProfile(macros, micros, [
      for (final p in profiles) (macros: p.macros, micros: p.micros),
    ]);
    if (i < 0) return _Reply.error(404, 'No latest developments yet.');
    return _Reply.json({...profiles[i].latest, 'refreshing': false});
  }

  _Reply _digest(Map<String, String> q) {
    var macro = q['macro'];
    if (macro == null && q['user_id'] != null) {
      final first = _strings(_user(q['user_id']!)?['preferred_macro_tags']);
      if (first.isNotEmpty) macro = first.first;
    }
    final digest =
        _snapshot.digests[macro] ??
        _snapshot.digests['_all'] ??
        _snapshot.digests.values.firstOrNull;
    return digest == null
        ? _Reply.error(404, 'No brief yet.')
        : _Reply.json({...digest, 'is_cached': true});
  }

  _Reply _tavilyCalls(Map<String, String> q) {
    final calls = _snapshot.tavilyCalls;
    final after = int.tryParse(q['after_id'] ?? '');
    final limit = (int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 500);
    int idOf(Map<String, dynamic> c) => (c['id'] as num?)?.toInt() ?? 0;
    final picked = after != null
        ? calls.where((c) => idOf(c) > after).toList()
        : calls.skip(max(0, calls.length - limit)).toList();
    final latest = calls.isEmpty ? (after ?? 0) : idOf(calls.last);
    return _Reply.json({'calls': picked, 'latest_id': max(latest, after ?? 0)});
  }

  // ==========================================================================
  // Helpers
  // ==========================================================================

  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toList() : <String>[];

  String _hex(int bytes) => [
    for (var i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// Random UUID v4 (the app checks ids look like the server's).
  String _uuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

class _Reply {
  const _Reply(this.body, {this.contentType = 'application/json'})
    : status = 200;

  const _Reply._(this.status, this.body, this.contentType);

  static const noContent = _Reply._(204, '', 'application/json');

  factory _Reply.json(Object? value, [int status = 200]) =>
      _Reply._(status, jsonEncode(value), 'application/json');

  factory _Reply.error(int status, String detail) =>
      _Reply._(status, jsonEncode({'detail': detail}), 'application/json');

  final int status;
  final String body;
  final String contentType;
}
