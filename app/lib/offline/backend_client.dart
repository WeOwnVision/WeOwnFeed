import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../services/api_service.dart';
import 'local_store.dart';
import 'offline_backend.dart';

enum BackendMode { live, offline }

/// The `http.Client` behind `ApiService`: the live server first, the
/// [OfflineBackend] when there is none.
///
/// The mode is decided once per app load and never changes during it, so a
/// session never mixes server and offline user ids:
/// - empty `API_BASE_URL` → offline, no network call at all;
/// - otherwise `GET /api/taxonomy` within [probeTimeout] → live, else offline.
///
/// In a live session a GET that fails (network error, timeout, 5xx) is
/// answered offline without a message; 4xx answers pass through, as do
/// writes. Stories and users the server sends are kept on the device so a
/// later offline session shows them.
class BackendClient extends http.BaseClient {
  BackendClient({
    String baseUrl = ApiService.defaultBaseUrl,
    http.Client? inner,
    OfflineBackend? offline,
    Future<LocalStore>? store,
    this.probeTimeout = const Duration(seconds: 4),
    this.readTimeout = const Duration(seconds: 25),
    this.writeTimeout = const Duration(seconds: 90),
  }) : baseUrl = baseUrl.trim(),
       _inner = inner ?? http.Client(),
       _store = store ?? LocalStore.open(),
       offline = offline ?? OfflineBackend(store: store);

  /// The app's client (`AppState` builds its `ApiService` with it).
  static final instance = BackendClient();

  final String baseUrl;
  final http.Client _inner;
  final Future<LocalStore> _store;
  final OfflineBackend offline;
  final Duration probeTimeout;

  /// How long a live GET may take before the offline answer is used. Slow
  /// AI endpoints (see [_slowPaths]) are exempt.
  final Duration readTimeout;

  /// How long a live write may wait for the server's first byte. Long
  /// enough for AI and Tavily writes (site add, Research start); streamed
  /// answers start well before it.
  final Duration writeTimeout;

  Future<BackendMode>? _mode;
  BackendMode? _current;
  bool _reportedFallback = false;

  /// The session's mode, decided on first use.
  Future<BackendMode> get mode => _mode ??= _decide();

  /// `true` once a live server answered; `false` before [mode] completes.
  bool get isLive => _current == BackendMode.live;

  /// `true` once the session is known to run without a server.
  bool get isOffline => _current == BackendMode.offline;

  Future<BackendMode> _decide() async {
    var mode = BackendMode.offline;
    if (baseUrl.isNotEmpty) {
      try {
        final res = await _inner
            .get(
              Uri.parse('${_base()}/api/taxonomy'),
              headers: const {'bypass-tunnel-reminder': 'true'},
            )
            .timeout(probeTimeout);
        if (res.statusCode == 200) mode = BackendMode.live;
      } catch (_) {
        // Unreachable, CORS, DNS, timeout: offline session.
      }
    }
    _current = mode;
    debugPrint(
      '[WOF] backend: ${mode.name}'
      '${baseUrl.isEmpty ? ' (no API_BASE_URL)' : ' ($baseUrl)'}',
    );
    if (mode == BackendMode.offline) unawaited(offline.ready);
    return mode;
  }

  String _base() => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (await mode == BackendMode.offline) return offline.send(request);

    final auth = request.headers['Authorization'] ?? '';
    if (auth.startsWith('Bearer ${OfflineBackend.tokenPrefix}')) {
      // A session from an earlier offline load: the app signs out quietly.
      return _json(request, 401, {'detail': 'Please sign in again.'});
    }
    if (request.method != 'GET') return _passWrite(request);

    final copy = _copy(request);
    final http.StreamedResponse res;
    try {
      final sending = _inner.send(request);
      res = _slowPaths.any(request.url.path.contains)
          ? await sending
          : await sending.timeout(readTimeout);
    } catch (_) {
      return _fallBack(copy);
    }
    if (res.statusCode >= 500) {
      unawaited(res.stream.drain<void>().catchError((_) {}));
      return _fallBack(copy);
    }
    if (res.statusCode != 200 || !_keeps(request.url)) return res;
    final bytes = await res.stream.toBytes();
    _remember(request.url, bytes);
    return _replay(res, bytes);
  }

  /// Paths whose first answer legitimately takes long (AI, Tavily).
  static const _slowPaths = [
    '/daily-digest',
    '/deep-inspect',
    '/api/search',
    '/latest-developments',
  ];

  Future<http.StreamedResponse> _fallBack(http.BaseRequest copy) {
    if (!_reportedFallback) {
      _reportedFallback = true;
      debugPrint('[WOF] live read failed; answering from local data');
    }
    return offline.send(copy);
  }

  /// Writes go to the server as they are; a failure reaches the app's own
  /// error handling and is neither stored nor sent again. Sign-in and
  /// preference answers carry the user, which is kept for fallback reads.
  Future<http.StreamedResponse> _passWrite(http.BaseRequest request) async {
    final path = request.url.path;
    final keepsUser =
        path.endsWith('/auth/login') ||
        path.endsWith('/auth/register') ||
        path.endsWith('/preferences');
    final res = await _inner.send(request).timeout(writeTimeout);
    if (!keepsUser || res.statusCode != 200) return res;
    final bytes = await res.stream.toBytes();
    _remember(request.url, bytes);
    return _replay(res, bytes);
  }

  bool _keeps(Uri url) {
    final p = url.pathSegments;
    if (p.length < 2 || p[0] != 'api') return false;
    return (p[1] == 'articles' && p.length <= 3) ||
        (p[1] == 'feed') ||
        (p[1] == 'auth' && p.length == 3 && p[2] == 'me') ||
        (p[1] == 'users' &&
            p.length == 4 &&
            (p[3] == 'preferences' || p[3] == 'latest-developments'));
  }

  /// Saves the stories / user of a live answer (never blocks the answer).
  void _remember(Uri url, List<int> bytes) {
    unawaited(() async {
      try {
        final json = jsonDecode(utf8.decode(bytes));
        final p = url.pathSegments;
        if (p[1] == 'auth' || p[1] == 'users' && p[3] == 'preferences') {
          final user = json is Map && json['user'] is Map ? json['user'] : json;
          if (user is Map<String, dynamic> && user['id'] is String) {
            final store = await _store;
            await store.put(
              LocalStore.liveUsers,
              user['id'] as String,
              {...user}..remove('interest_summary'),
            );
          }
          return;
        }
        final items = json is List
            ? json
            : (json is Map
                  ? (json['articles'] ?? (json['id'] != null ? [json] : null))
                  : null);
        if (items is List) {
          await offline.addFresh(items.whereType<Map<String, dynamic>>());
        }
      } catch (_) {
        // Not JSON or storage failed: nothing to keep.
      }
    }());
  }

  static http.Request _copy(http.BaseRequest r) =>
      http.Request(r.method, r.url)..headers.addAll(r.headers);

  static http.StreamedResponse _replay(
    http.StreamedResponse res,
    List<int> bytes,
  ) => http.StreamedResponse(
    Stream.value(bytes),
    res.statusCode,
    contentLength: bytes.length,
    request: res.request,
    headers: res.headers,
    reasonPhrase: res.reasonPhrase,
  );

  static http.StreamedResponse _json(
    http.BaseRequest request,
    int status,
    Object body,
  ) {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      contentLength: bytes.length,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
