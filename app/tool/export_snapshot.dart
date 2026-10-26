// Writes assets/offline/snapshot.json from a running server (T2.1).
//
//   dart run tool/export_snapshot.dart --profiles=<profiles.json> [--api=http://127.0.0.1:8000] [--digests]
//
// --profiles: the harvest profiles file ({username: {id, token, macros, micros}}).
//   Tokens are used for the calls that need sign-in and are never written out.
// --digests: also asks the server for today's daily digests. Without it the
//   digests of the current snapshot are kept: a digest that is not cached for
//   today makes the server spend Tavily credits.
//
// Everything else is read only and spends no credits: story list and details,
// saved Fact Checks (the cached deep-inspect stream), research, comments,
// latest developments, Tavily calls, ingestion status, telemetry.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _out = 'assets/offline/snapshot.json';
const _macros = [
  'AI',
  'Tech',
  'Hardware',
  'Finance',
  'Science',
  'Automotive',
  'Gaming',
];

Future<void> main(List<String> args) async {
  String? arg(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final api = (arg('api') ?? 'http://127.0.0.1:8000').replaceAll(
    RegExp(r'/$'),
    '',
  );
  final profilesPath = arg('profiles');
  if (profilesPath == null) {
    print('--profiles=<profiles.json> is required');
    exit(64);
  }
  final profiles = (jsonDecode(File(profilesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final tokens = [for (final p in profiles.values) '${p['token']}'];
  final client = _Client(api, tokens);

  final previous = _readPrevious();
  final watch = Stopwatch()..start();

  final taxonomy = await client.get('/api/taxonomy') as List;
  final list = await client.get('/api/articles?page=1&page_size=5000') as List;
  final ids = [
    for (final a in list.cast<Map<String, dynamic>>())
      if ((a['tldr'] ?? '').toString().trim().isNotEmpty) '${a['id']}',
  ];
  print('stories: ${list.length} listed, ${ids.length} with a summary');

  final articles = <String, Map<String, dynamic>>{};
  final research = <String, Map<String, dynamic>>{};
  final comments = <String, List<dynamic>>{};
  var factChecks = 0;
  await _forEach(ids, 8, (id) async {
    final detail =
        await client.get('/api/articles/$id') as Map<String, dynamic>;
    if (detail['fact_check_verdict'] != null) {
      final fc = await client.savedFactCheck(id);
      if (fc != null) {
        detail['fact_check_cache'] = fc;
        factChecks++;
      }
    }
    articles[id] = detail;
    final r = await client.get('/api/articles/$id/deep-inspect/research');
    // The server saves a failed run as a "completed" report that only says
    // "Research failed: …"; those are left out.
    if (r is Map<String, dynamic> &&
        r['status'] == 'completed' &&
        !'${r['report'] ?? ''}'.startsWith('Research failed')) {
      research[id] = r;
    }
    final c = await client.get('/api/articles/$id/comments');
    if (c is List && c.isNotEmpty) comments[id] = c;
  });
  print(
    'details: ${articles.length}, fact checks: $factChecks, '
    'research: ${research.length}, comments: ${comments.length}',
  );

  Map<String, dynamic> digests;
  if (args.contains('--digests')) {
    digests = {};
    for (final m in _macros) {
      digests[m] = await client.get(
        '/api/intelligence/daily-digest?macro=$m',
        auth: true,
      );
    }
    // No category: the first category in the server's default order.
    digests['_all'] = digests[_macros.first];
  } else {
    digests = previous['digests'] is Map
        ? (previous['digests'] as Map).cast<String, dynamic>()
        : {};
  }
  print('digests: ${digests.keys.join(', ')}');

  final outProfiles = <Map<String, dynamic>>[];
  for (final e in profiles.entries) {
    final p = (e.value as Map).cast<String, dynamic>();
    final latest = await client.get(
      '/api/users/${p['id']}/latest-developments',
      token: '${p['token']}',
    );
    outProfiles.add({
      'username': e.key,
      'macros': p['macros'],
      'micros': p['micros'],
      'latest': latest,
    });
  }

  // Cards made before a story was merged can point to the copy, which the
  // list leaves out: its detail is fetched too, so the card opens offline.
  final linked = <String>{
    for (final card in [
      ...digests.values,
      for (final p in outProfiles) p['latest'],
    ])
      if (card is Map && card['articles'] is List)
        for (final a in card['articles'] as List)
          if (a is Map && a['id'] is String) a['id'] as String,
  }..removeAll(articles.keys);
  for (final id in linked) {
    articles[id] =
        await client.get('/api/articles/$id') as Map<String, dynamic>;
  }
  if (linked.isNotEmpty) print('card stories added: ${linked.length}');

  final calls = await client.get('/api/tavily/calls?limit=200') as Map;
  final snapshot = {
    'version': 1,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'taxonomy': taxonomy,
    'articles': articles,
    'research': research,
    'comments': comments,
    'digests': digests,
    'profiles': outProfiles,
    'tavily_calls': calls['calls'] ?? const [],
    'ingestion_status': await client.get('/api/ingestion/status'),
    'telemetry': await client.get('/api/system/telemetry'),
  };
  final text = jsonEncode(snapshot);
  File(_out).writeAsStringSync(text);
  final gz = gzip.encode(utf8.encode(text)).length;
  print(
    'wrote $_out: ${(text.length / 1e6).toStringAsFixed(1)} MB '
    '(${(gz / 1e6).toStringAsFixed(1)} MB gzip) in ${watch.elapsed.inSeconds}s',
  );
  client.close();
}

Map<String, dynamic> _readPrevious() {
  try {
    final json = jsonDecode(File(_out).readAsStringSync());
    return json is Map<String, dynamic> ? json : const {};
  } catch (_) {
    return const {};
  }
}

/// Runs [task] over [items] with at most [width] in flight.
Future<void> _forEach(
  List<String> items,
  int width,
  Future<void> Function(String) task,
) async {
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      await task(items[next++]);
    }
  }

  await Future.wait([for (var i = 0; i < width; i++) worker()]);
}

class _Client {
  _Client(this.api, this.tokens);

  final String api;
  final List<String> tokens;
  final _http = http.Client();
  var _turn = 0;

  /// The server limits some calls per user and hour, so signed-in calls
  /// rotate over the profiles' tokens.
  String _token() => tokens[_turn++ % tokens.length];

  Future<Object?> get(String path, {bool auth = false, String? token}) async {
    final res = await _http
        .get(
          Uri.parse('$api$path'),
          headers: {
            if (auth || token != null)
              'Authorization': 'Bearer ${token ?? _token()}',
          },
        )
        .timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) {
      throw HttpException('GET $path → ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// The saved Fact Check, read from the cached deep-inspect stream (no
  /// credits). `null` when the stream does not come from the cache.
  Future<Map<String, dynamic>?> savedFactCheck(String id) async {
    final res = await _http
        .get(
          Uri.parse('$api/api/articles/$id/deep-inspect'),
          headers: {'Authorization': 'Bearer ${_token()}'},
        )
        .timeout(const Duration(minutes: 2));
    String? event;
    for (final line in const LineSplitter().convert(
      utf8.decode(res.bodyBytes),
    )) {
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (event == 'final' && line.startsWith('data:')) {
        final fc = jsonDecode(line.substring(5)) as Map<String, dynamic>;
        if (fc.remove('is_cached') != true) return null;
        return fc;
      }
    }
    return null;
  }

  void close() => _http.close();
}
