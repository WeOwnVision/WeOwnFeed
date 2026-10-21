import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_models.dart';

/// Client for the WeOwnFeed API.
///
/// Does not depend on Flutter, so the scripts under `bin/` can use it with
/// `dart run` too. The default address is the local server on this machine;
/// another address (e.g. a tunnel or the deployed API) is given at build time:
///
///     flutter run -d chrome --dart-define=API_BASE_URL=https://xyz.loca.lt
class ApiService {
  ApiService({
    String baseUrl = defaultBaseUrl,
    http.Client? client,
    this.logger,
    this.timeout = const Duration(seconds: 30),
    this.slowTimeout = const Duration(seconds: 90),
    this.digestTimeout = const Duration(seconds: 180),
  }) : baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _client = client ?? http.Client();

  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // "localhost" tries IPv6 first; the server only listens on IPv4.
    defaultValue: 'http://127.0.0.1:8000',
  );

  /// Test records on the server; never shown in the feed or search.
  static const hiddenSources = {'Benchmark News'};

  /// Shortest query the server accepts for `/api/search`.
  static const minSearchLength = 2;

  final String baseUrl;
  final http.Client _client;

  /// If set, every request and response code is written here (e.g. `debugPrint`).
  final void Function(String message)? logger;

  /// Fast endpoints (lists, details, sign-in, comments).
  final Duration timeout;

  /// Endpoints that use AI (search, chat, synthesize). The first search can
  /// take ~45 s while the server loads the model.
  final Duration slowTimeout;

  /// Daily brief: the first build runs Tavily verification + a long model reply.
  final Duration digestTimeout;

  /// Bearer token of the signed-in user, sent with every request.
  String? authToken;

  /// Called when the server rejects [authToken] (expired or revoked).
  void Function()? onUnauthorized;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    // Skips the localtunnel "warning page".
    'bypass-tunnel-reminder': 'true',
    if (authToken != null) 'Authorization': 'Bearer $authToken',
  };

  ApiException _fail(int statusCode, String body) {
    if (statusCode == 401 && authToken != null) onUnauthorized?.call();
    return ApiException.fromResponse(statusCode, body);
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  // ==========================================================================
  // GET
  // ==========================================================================

  /// One page of the story feed. [page] starts at 1. [macro] filters by
  /// category (e.g. "Tech").
  ///
  /// Test records are hidden, so a page can come back empty while the next
  /// one has stories; use [ArticlePage.hasMore] to decide whether to go on.
  Future<ArticlePage> getArticlePage({
    int page = 1,
    int pageSize = 20,
    String? macro,
  }) async {
    final size = pageSize.clamp(1, 100);
    final query = {
      'page': '${page < 1 ? 1 : page}',
      'page_size': '$size',
      if (macro != null && macro.isNotEmpty) 'macro': macro,
    };
    final raw = _list(await _getJson(_uri('/api/articles', query)));
    return ArticlePage(
      items: _visible(raw.map(Article.fromJson)),
      hasMore: raw.length >= size,
    );
  }

  /// Only the stories of [getArticlePage].
  Future<List<Article>> getArticles({
    int page = 1,
    int pageSize = 20,
    String? macro,
  }) async => (await getArticlePage(
    page: page,
    pageSize: pageSize,
    macro: macro,
  )).items;

  /// One story's details (including the full text `cleanText`).
  Future<Article> getArticle(String articleId) async {
    final json = await _getJson(_uri('/api/articles/${_id(articleId)}'));
    return Article.fromJson(_map(json));
  }

  /// Natural-language search; direct matches come first.
  Future<List<SearchHit>> searchArticles(String query) async {
    final q = query.trim();
    if (q.length < minSearchLength) return const [];
    final json = await _getJson(
      _uri('/api/search', {'q': q}),
      timeout: slowTimeout,
    );
    return _list(json)
        .map(SearchHit.fromJson)
        .where((h) => !hiddenSources.contains(h.article.source))
        .toList();
  }

  /// Natural-language search; results split into "direct" and "explore".
  Future<GroupedSearch> searchGrouped(String query) async {
    final q = query.trim();
    if (q.length < minSearchLength) return GroupedSearch.empty;
    final json = await _getJson(
      _uri('/api/search', {'q': q, 'grouped': 'true'}),
      timeout: slowTimeout,
    );
    final result = GroupedSearch.fromJson(_map(json));
    bool shown(SearchHit h) => !hiddenSources.contains(h.article.source);
    return GroupedSearch(
      query: result.query,
      direct: result.direct.where(shown).toList(),
      explore: result.explore.where(shown).toList(),
    );
  }

  /// A story's comments (oldest first).
  Future<List<ArticleComment>> getComments(String articleId) async {
    final json = await _getJson(
      _uri('/api/articles/${_id(articleId)}/comments'),
    );
    return _list(json).map(ArticleComment.fromJson).toList();
  }

  // ==========================================================================
  // Personalization
  // ==========================================================================

  /// Pickable categories and their subtopic tags. The list is fixed in the
  /// server's code and skips the database, so it returns fast.
  Future<List<TaxonomyCategory>> getTaxonomy() async {
    final json = await _getJson(_uri('/api/taxonomy'));
    return _list(json).map(TaxonomyCategory.fromJson).toList();
  }

  /// The user's saved interests.
  Future<AppUser> getPreferences(String userId) async {
    final json = await _getJson(_uri('/api/users/${_id(userId)}/preferences'));
    return AppUser.fromJson(_map(json));
  }

  /// Saves the interests and completes onboarding.
  ///
  /// The server rebuilds the interest vector from the `interestContext`
  /// sentence (translated to English if needed), or from a standard sentence
  /// built from the picks; the profile learned from likes is reset.
  Future<PreferencesResult> updatePreferences(
    String userId, {
    required List<String> macroTags,
    List<String> microTags = const [],
    String? interestContext,
  }) async {
    if (macroTags.isEmpty) {
      throw const ApiException(
        ApiErrorKind.badRequest,
        'Pick at least one topic',
      );
    }
    final json = _map(
      await _send(
        'PUT',
        _uri('/api/users/${_id(userId)}/preferences'),
        body: {
          'preferred_macro_tags': macroTags,
          'preferred_micro_tags': microTags,
          // null: the server keeps its sentence; '': deletes it.
          if (interestContext != null) 'interest_context': interestContext,
        },
        timeout: slowTimeout,
      ),
    );
    return PreferencesResult(
      user: AppUser.fromJson(json),
      interestSummary: json['interest_summary'] as String?,
    );
  }

  /// Longest "why" sentence the server accepts.
  static const maxContextChars = 200;

  /// Most "+" follows the server accepts.
  static const maxFollows = 3;

  /// What the user follows with "+" (in the order added).
  Future<List<UserFollow>> getFollows(String userId) async {
    final json = await _getJson(_uri('/api/users/${_id(userId)}/follows'));
    return _list(json).map(UserFollow.fromJson).toList();
  }

  /// Adds a follow. The first time something is followed the server fetches
  /// it once right away (1 Tavily credit), then refreshes it every 2 days with
  /// a shared query. If it is already followed the existing record returns.
  Future<UserFollow> addFollow(
    String userId, {
    required String name,
    required String macro,
  }) async {
    final json = await _postJson(_uri('/api/users/${_id(userId)}/follows'), {
      'name': name.trim(),
      'macro': macro,
    });
    return UserFollow.fromJson(_map(json));
  }

  Future<void> removeFollow(String userId, String followId) async {
    await _send(
      'DELETE',
      _uri('/api/users/${_id(userId)}/follows/${_id(followId)}'),
    );
  }

  /// Most followed sites the server accepts.
  static const maxSites = 5;

  /// Sites the user follows (newest first).
  Future<List<FollowedSite>> getSites(String userId) async {
    final json = await _getJson(_uri('/api/users/${_id(userId)}/sites'));
    return _list(json).map(FollowedSite.fromJson).toList();
  }

  /// Follows a site. In the background the server maps the site with Tavily
  /// Map and fetches the newest posts with Crawl; progress is in
  /// [FollowedSite.status]. An invalid address or the limit of 5 returns
  /// [ApiErrorKind.badRequest].
  Future<FollowedSite> addSite(String userId, String url) async {
    final json = await _postJson(_uri('/api/users/${_id(userId)}/sites'), {
      'url': url.trim(),
    });
    return FollowedSite.fromJson(_map(json));
  }

  Future<void> removeSite(String userId, String siteId) async {
    await _send(
      'DELETE',
      _uri('/api/users/${_id(userId)}/sites/${_id(siteId)}'),
    );
  }

  /// One page of the personal feed; the best match comes first.
  ///
  /// If the user picked no interests the server returns a date-ordered feed
  /// ([PersonalizedFeed.isFallback]).
  Future<PersonalizedFeed> getPersonalizedFeed(
    String userId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final size = pageSize.clamp(1, 100);
    final json = _map(
      await _getJson(
        _uri('/api/feed/personalized', {
          'user_id': userId,
          'page': '${page < 1 ? 1 : page}',
          'page_size': '$size',
        }),
        timeout: slowTimeout,
      ),
    );
    final raw = json['articles'];
    final items = raw is List
        ? raw.whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
    return PersonalizedFeed(
      articles: _visible(items.map(Article.fromJson)),
      hasMore: items.length >= size,
      isFallback: json['is_fallback'] == true,
    );
  }

  /// Changes the like / dislike / save state.
  ///
  /// The server treats this endpoint as a toggle. A like moves the user's
  /// interest vector toward the story and adds its category to the
  /// preferences; a dislike moves the vector away and drops the story from
  /// the feed.
  Future<InteractionResult> toggleInteraction(
    String articleId, {
    required String userId,
    required InteractionType type,
  }) async {
    final json = _map(
      await _postJson(_uri('/api/articles/${_id(articleId)}/interactions'), {
        'user_id': userId,
        'interaction_type': type.name,
      }),
    );
    return InteractionResult.fromJson(json);
  }

  /// Brings an interaction to the wanted state. The server toggles, so if the
  /// response differs from the wanted state the request is sent once more.
  Future<InteractionResult> setInteraction(
    String articleId, {
    required String userId,
    required InteractionType type,
    required bool active,
  }) async {
    final result = await toggleInteraction(
      articleId,
      userId: userId,
      type: type,
    );
    if (result.active == active) return result;
    return toggleInteraction(articleId, userId: userId, type: type);
  }

  /// The day's verified brief for the user's first category.
  ///
  /// Built once per day and category (Tavily + AI, ~1 min); later calls
  /// return quickly from the cache.
  Future<DailyDigest> getDailyDigest({String? userId, String? macro}) async {
    final json = await _getJson(
      _uri('/api/intelligence/daily-digest', {
        if (userId != null) 'user_id': userId,
        if (macro != null) 'macro': macro,
      }),
      timeout: digestTimeout,
    );
    return DailyDigest.fromJson(_map(json));
  }

  /// The home page "Latest developments" card: headline, paragraph and the
  /// stories it was written from. ~2 s the first time, then instant from the
  /// cache. Without chosen interests the server returns 409.
  Future<LatestDevelopments> getLatestDevelopments(String userId) async {
    final json = await _getJson(
      _uri('/api/users/${_id(userId)}/latest-developments'),
      timeout: slowTimeout,
    );
    return LatestDevelopments.fromJson(_map(json));
  }

  // ==========================================================================
  // POST
  // ==========================================================================

  /// Signs in with username and password (`POST /api/auth/login`).
  Future<AuthSession> login(String username, String password) =>
      _authenticate('/api/auth/login', username, password);

  /// Creates an account and signs it in (`POST /api/auth/register`).
  Future<AuthSession> register(String username, String password) =>
      _authenticate('/api/auth/register', username, password);

  Future<AuthSession> _authenticate(
    String path,
    String username,
    String password,
  ) async {
    final trimmed = username.trim();
    if (trimmed.isEmpty || password.isEmpty) {
      throw const ApiException(
        ApiErrorKind.badRequest,
        'Enter your username and password.',
      );
    }
    final json = _map(
      await _postJson(_uri(path), {'username': trimmed, 'password': password}),
    );
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw ApiException(ApiErrorKind.invalidResponse, 'No token from $path');
    }
    return AuthSession(
      user: AppUser.fromJson(_map(json['user'])),
      token: token,
    );
  }

  /// The user behind [authToken] (`GET /api/auth/me`).
  Future<AppUser> me() async =>
      AppUser.fromJson(_map(await _getJson(_uri('/api/auth/me'))));

  /// Revokes [authToken] on the server. Errors are ignored: the app forgets
  /// the token either way.
  Future<void> logout() async {
    if (authToken == null) return;
    try {
      await _client
          .post(_uri('/api/auth/logout'), headers: _headers)
          .timeout(timeout);
    } catch (_) {}
  }

  /// Adds a comment to a story. The server only returns `id` and
  /// `created_at`, so the rest of the comment is filled from the sent values.
  Future<ArticleComment> postComment(
    String articleId, {
    required AppUser user,
    required String commentText,
    String? selectedText,
  }) async {
    final text = commentText.trim();
    if (text.isEmpty) {
      throw const ApiException(
        ApiErrorKind.badRequest,
        'Comment cannot be empty',
      );
    }
    final selected = selectedText?.trim();
    final json = await _postJson(
      _uri('/api/articles/${_id(articleId)}/comments'),
      {
        'user_id': user.id,
        'comment_text': text,
        if (selected != null && selected.isNotEmpty) 'selected_text': selected,
      },
    );
    final res = _map(json);
    return ArticleComment(
      id: res['id'] as String,
      comment: text,
      username: user.username,
      avatarUrl: user.avatarUrl,
      selectedText: selected,
      createdAt: DateTime.tryParse('${res['created_at']}'),
    );
  }

  /// WAI chat about a story; the reply streams in chunks.
  ///
  /// The server streams plain text. On mobile chunks arrive as they come; on
  /// the web (the browser `http` client) the reply arrives in one piece once
  /// it is complete. If no text arrives, [ApiErrorKind.emptyResponse] is thrown.
  Stream<String> chatStream(
    String articleId, {
    required String question,
    List<ChatTurn> history = const [],
  }) {
    return _postTextStream(_uri('/api/articles/${_id(articleId)}/chat'), {
      'question': question.trim(),
      // The server only uses the last 4 turns; no need to send more.
      'history': [
        for (final t in history.skip(
          history.length > 4 ? history.length - 4 : 0,
        ))
          t.toJson(),
      ],
    });
  }

  /// Opens a WAI chat. [mode]: `story` (the story's full text), `latest`
  /// (the home page latest developments) or `area` (the latest stories of a
  /// chosen category or subtopic). WAI reads the scope and writes the first
  /// message itself.
  Future<WaiOpening> openWai({
    required String userId,
    required String mode,
    String? articleId,
    String? area,
  }) async {
    final json = await _send(
      'POST',
      _uri('/api/wai/open'),
      body: {
        'user_id': userId,
        'mode': mode,
        if (articleId != null) 'article_id': articleId,
        if (area != null) 'area': area,
      },
      timeout: slowTimeout,
    );
    return WaiOpening.fromJson(_map(json));
  }

  /// A question in a chat opened with [openWai]; the reply streams like
  /// [chatStream]. [sourceIds]: the stories the chat opened with (so the
  /// numbers stay the same).
  Stream<String> waiChatStream({
    required String userId,
    required String mode,
    String? articleId,
    String? area,
    List<String> sourceIds = const [],
    required String question,
    List<ChatTurn> history = const [],
  }) {
    return _postTextStream(_uri('/api/wai/chat'), {
      'user_id': userId,
      'mode': mode,
      if (articleId != null) 'article_id': articleId,
      if (area != null) 'area': area,
      'source_ids': sourceIds,
      'question': question.trim(),
      // The server uses the last 6 turns (including WAI's opening message).
      'history': [
        for (final t in history.skip(
          history.length > 6 ? history.length - 6 : 0,
        ))
          t.toJson(),
      ],
    });
  }

  /// The completed reply of [chatStream].
  Future<String> chatWithArticle(
    String articleId, {
    required String question,
    List<ChatTurn> history = const [],
  }) => chatStream(articleId, question: question, history: history).join();

  /// Compares several stories (common ground, contradictions, unverified
  /// claims). The reply is Markdown and streams.
  Stream<String> synthesizeStream(List<String> articleIds) {
    if (articleIds.length < 2) {
      return Stream.error(
        const ApiException(
          ApiErrorKind.badRequest,
          'At least 2 articles are required',
        ),
      );
    }
    return _postTextStream(_uri('/api/intelligence/synthesize'), {
      'article_ids': articleIds.map(_id).toList(),
    });
  }

  /// The completed reply of [synthesizeStream].
  Future<String> synthesizeArticles(List<String> articleIds) =>
      synthesizeStream(articleIds).join();

  /// System telemetry: Nebius Token Factory, Nemotron models and Tavily quota/usage.
  Future<Map<String, dynamic>> getTelemetry() async {
    final json = await _getJson(_uri('/api/system/telemetry'));
    return _map(json);
  }

  /// Tavily calls the server made, oldest first. With [afterId], only those
  /// after it; otherwise the last [limit] calls.
  Future<TavilyCallPage> getTavilyCalls({int? afterId, int limit = 50}) async {
    final json = _map(
      await _getJson(
        _uri('/api/tavily/calls', {
          'limit': '$limit',
          if (afterId != null) 'after_id': '$afterId',
        }),
      ),
    );
    return TavilyCallPage(
      calls: _list(json['calls']).map(TavilyCall.fromJson).toList(),
      latestId: (json['latest_id'] as num?)?.toInt() ?? afterId ?? 0,
    );
  }

  /// Remaining Tavily credits (sum over all keys); `null` if unknown.
  Future<int?> getTavilyCreditsRemaining() async {
    final json = _map(await _getJson(_uri('/api/ingestion/status')));
    return (json['credits_remaining'] as num?)?.toInt();
  }

  /// Starts Tavily Research for a story (or returns the saved result). The
  /// server builds the question from the story's title and claims and may
  /// wait ~25 s. If it does not finish it returns `running`; poll the result
  /// with [getResearch].
  Future<ArticleResearch> startResearch(String articleId) async {
    final json = await _send(
      'POST',
      _uri('/api/articles/${_id(articleId)}/deep-inspect/research'),
      body: const {},
      timeout: slowTimeout,
    );
    return ArticleResearch.fromJson(_map(json));
  }

  /// The story's saved Research result or the status of the running job.
  Future<ArticleResearch> getResearch(String articleId) async {
    final json = await _getJson(
      _uri('/api/articles/${_id(articleId)}/deep-inspect/research'),
      timeout: slowTimeout,
    );
    return ArticleResearch.fromJson(_map(json));
  }

  /// Deep Inspect: live verification stream with Tavily Search + Extract (SSE).
  Stream<DeepInspectEvent> deepInspectStream(String articleId) async* {
    final uri = _uri('/api/articles/${_id(articleId)}/deep-inspect');
    final req = http.Request('POST', uri)..headers.addAll(_headers);
    final res = await _client.send(req).timeout(digestTimeout);

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final text = await res.stream.bytesToString().catchError((_) => '');
      throw _fail(res.statusCode, text);
    }

    final textStream = res.stream
        .transform(utf8.decoder)
        .timeout(digestTimeout);
    var buffer = '';
    var event = '';
    final data = <String>[];

    await for (final chunk in textStream) {
      buffer += chunk;
      var nl = buffer.indexOf('\n');
      while (nl != -1) {
        var line = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 1);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            final payload = data.join('\n');
            if (payload.trim() != '[DONE]') {
              yield DeepInspectEvent(
                event: event.isEmpty ? 'data' : event,
                data: payload,
              );
            }
          }
          event = '';
          data.clear();
        } else if (line.startsWith('data:')) {
          data.add(_sseValue(line.substring(5)));
        } else if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        }
        nl = buffer.indexOf('\n');
      }
    }
  }

  /// Asks a question in the context of the verified story (/api/articles/{id}/ask).
  Future<String> askArticle(
    String articleId, {
    required String question,
    List<Map<String, String>> history = const [],
  }) async {
    final json = await _postJson(_uri('/api/articles/${_id(articleId)}/ask'), {
      'question': question.trim(),
      'history': history,
    });
    final map = _map(json);
    return (map['answer'] as String?) ?? '';
  }

  void dispose() => _client.close();

  // ==========================================================================
  // Internal helpers
  // ==========================================================================

  /// Encodes an id for a path segment (spaces, "/" and so on).
  String _id(String id) => Uri.encodeComponent(id.trim());

  List<Article> _visible(Iterable<Article> articles) =>
      articles.where((a) => !hiddenSources.contains(a.source)).toList();

  Future<Object?> _getJson(Uri uri, {Duration? timeout}) =>
      _send('GET', uri, timeout: timeout);

  Future<Object?> _postJson(Uri uri, Object body) =>
      _send('POST', uri, body: body);

  Future<Object?> _send(
    String method,
    Uri uri, {
    Object? body,
    Duration? timeout,
  }) async {
    final sw = Stopwatch()..start();
    logger?.call('[$method] $uri');
    final http.Response res;
    try {
      final req = switch (method) {
        'GET' => _client.get(uri, headers: _headers),
        'PUT' => _client.put(uri, headers: _headers, body: jsonEncode(body)),
        'DELETE' => _client.delete(uri, headers: _headers),
        _ => _client.post(uri, headers: _headers, body: jsonEncode(body)),
      };
      res = await req.timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout, 'Request timed out: $uri');
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    logger?.call('  └─ ${res.statusCode} (${sw.elapsedMilliseconds} ms)');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _fail(res.statusCode, text);
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiException(
        ApiErrorKind.invalidResponse,
        'Expected JSON from $uri',
        statusCode: res.statusCode,
      );
    }
  }

  Stream<String> _postTextStream(Uri uri, Object body) async* {
    final sw = Stopwatch()..start();
    logger?.call('[POST/stream] $uri');
    final req = http.Request('POST', uri)
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);

    final http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(slowTimeout);
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout, 'Request timed out: $uri');
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final text = await res.stream.bytesToString().catchError((_) => '');
      logger?.call('  └─ ${res.statusCode} (${sw.elapsedMilliseconds} ms)');
      throw _fail(res.statusCode, text);
    }

    final isSse = (res.headers['content-type'] ?? '').contains(
      'text/event-stream',
    );
    final text = res.stream.transform(utf8.decoder).timeout(slowTimeout);
    var received = false;
    try {
      await for (final chunk in isSse ? _sseTokens(text) : text) {
        if (chunk.isEmpty) continue;
        if (!received && chunk.trim().isEmpty) continue;
        received = true;
        yield chunk;
      }
    } on TimeoutException {
      throw ApiException(ApiErrorKind.timeout, 'Response stalled: $uri');
    } on http.ClientException catch (e) {
      throw ApiException(ApiErrorKind.network, e.message);
    }
    logger?.call(
      '  └─ ${res.statusCode} stream (${sw.elapsedMilliseconds} ms)',
    );

    // On an AI error the server may return 200 with an empty body.
    if (!received) {
      throw ApiException(
        ApiErrorKind.emptyResponse,
        'Empty response from $uri',
        statusCode: res.statusCode,
      );
    }
  }

  /// Turns an SSE body into text chunks.
  ///
  /// Server format: `data: {"token": "..."}` events, ending with
  /// `data: [DONE]`. An event with `{"error": ...}` / `{"detail": ...}` or
  /// an `event: error` throws [ApiErrorKind.server].
  static Stream<String> _sseTokens(Stream<String> text) async* {
    var buffer = '';
    var event = '';
    final data = <String>[];

    await for (final chunk in text) {
      buffer += chunk;
      var nl = buffer.indexOf('\n');
      while (nl != -1) {
        var line = buffer.substring(0, nl);
        buffer = buffer.substring(nl + 1);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        if (line.isEmpty) {
          // Empty line: the event is complete.
          final result = _sseEvent(event, data);
          event = '';
          data.clear();
          if (result == null) return; // [DONE]
          if (result.isNotEmpty) yield result;
        } else if (line.startsWith('data:')) {
          data.add(_sseValue(line.substring(5)));
        } else if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        }
        nl = buffer.indexOf('\n');
      }
    }
    if (buffer.startsWith('data:')) data.add(_sseValue(buffer.substring(5)));
    final result = _sseEvent(event, data);
    if (result != null && result.isNotEmpty) yield result;
  }

  static String _sseValue(String raw) =>
      raw.startsWith(' ') ? raw.substring(1) : raw;

  /// Text of one SSE event; `null` for `[DONE]`.
  static String? _sseEvent(String event, List<String> data) {
    if (data.isEmpty) return '';
    final payload = data.join('\n');
    if (payload.trim() == '[DONE]') return null;
    Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      json = null;
    }
    final error = json is Map ? (json['error'] ?? json['detail']) : null;
    if (event == 'error' || error != null) {
      throw ApiException(ApiErrorKind.server, '${error ?? payload}');
    }
    if (json is Map) {
      final token = json['token'] ?? json['content'] ?? json['text'];
      return token is String ? token : '';
    }
    return json is String ? json : payload;
  }

  static List<Map<String, dynamic>> _list(Object? json) {
    if (json is List) return json.whereType<Map<String, dynamic>>().toList();
    throw const ApiException(
      ApiErrorKind.invalidResponse,
      'Expected a JSON list',
    );
  }

  static Map<String, dynamic> _map(Object? json) {
    if (json is Map<String, dynamic>) return json;
    throw const ApiException(
      ApiErrorKind.invalidResponse,
      'Expected a JSON object',
    );
  }
}

/// A signed-in user and the bearer token for their requests.
class AuthSession {
  const AuthSession({required this.user, required this.token});

  final AppUser user;
  final String token;
}

enum ApiErrorKind {
  /// No internet, DNS/CORS error and so on.
  network,

  /// Timed out.
  timeout,

  /// Tunnel down or the server is not responding (502/503/504).
  unavailable,

  /// 401/403: not signed in, wrong password or expired session.
  unauthorized,

  /// 429: too many requests; the message says when to retry.
  rateLimited,

  /// 404.
  notFound,

  /// 400/422: bad request.
  badRequest,

  /// Other 5xx errors.
  server,

  /// Returned 200 but the content is empty (chat/synthesize).
  emptyResponse,

  /// The response is not in the expected shape.
  invalidResponse,
}

class ApiException implements Exception {
  const ApiException(this.kind, this.message, {this.statusCode});

  factory ApiException.fromResponse(int statusCode, String body) {
    final kind = switch (statusCode) {
      401 || 403 => ApiErrorKind.unauthorized,
      404 => ApiErrorKind.notFound,
      429 => ApiErrorKind.rateLimited,
      400 || 422 => ApiErrorKind.badRequest,
      502 || 503 || 504 => ApiErrorKind.unavailable,
      >= 500 => ApiErrorKind.server,
      _ => ApiErrorKind.badRequest,
    };
    return ApiException(kind, _detail(body), statusCode: statusCode);
  }

  final ApiErrorKind kind;

  /// Details for developers (the server's `detail` field etc.).
  final String message;
  final int? statusCode;

  /// English message shown in the UI.
  String get userMessage => switch (kind) {
    ApiErrorKind.network || ApiErrorKind.unavailable =>
      'Server unavailable. Please try again in a moment.',
    ApiErrorKind.timeout => 'The server is taking too long to respond.',
    ApiErrorKind.notFound => 'This content could not be found.',
    ApiErrorKind.badRequest ||
    ApiErrorKind.unauthorized ||
    ApiErrorKind.rateLimited => message,
    ApiErrorKind.server ||
    ApiErrorKind.emptyResponse ||
    ApiErrorKind.invalidResponse => 'Something went wrong. Please try again.',
  };

  static String _detail(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map && json['detail'] != null) {
        final detail = json['detail'];
        // FastAPI validation errors: [{"msg": "...", ...}]
        if (detail is List && detail.isNotEmpty && detail.first is Map) {
          return '${(detail.first as Map)['msg']}';
        }
        return '$detail';
      }
    } on FormatException {
      // Plain-text body (e.g. "503 - Tunnel Unavailable").
    }
    final trimmed = body.trim();
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
  }

  @override
  String toString() =>
      'ApiException(${kind.name}${statusCode != null ? ', $statusCode' : ''}): $message';
}
