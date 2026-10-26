import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weownfeed/models/api_models.dart';
import 'package:weownfeed/offline/backend_client.dart';
import 'package:weownfeed/offline/local_store.dart';
import 'package:weownfeed/offline/offline_backend.dart';
import 'package:weownfeed/offline/ranking.dart';
import 'package:weownfeed/offline/snapshot.dart';
import 'package:weownfeed/services/api_service.dart';

final _now = DateTime.utc(2026, 10, 26, 12);

Map<String, dynamic> _story(
  String id, {
  String macro = 'AI',
  List<String> micros = const [],
  int hoursAgo = 1,
  String? title,
  Map<String, dynamic>? factCheck,
}) => {
  'id': id,
  'source': 'Source $id',
  'title': title ?? 'Story $id',
  'url': 'https://example.com/$id',
  'published_at': _now.subtract(Duration(hours: hoursAgo)).toIso8601String(),
  'macro_tag': macro,
  'macro_tags': [macro],
  'micro_tags': micros,
  'tldr': 'Summary of $id.',
  'clean_text': 'Full text of $id.',
  'fact_check_cache': ?factCheck,
};

OfflineSnapshot _snapshot() => OfflineSnapshot(
  taxonomy: const [
    {
      'macro': 'AI',
      'micro_tags': [
        {'tag': 'llm_agents', 'label': 'LLM Agents'},
      ],
    },
    {
      'macro': 'Finance',
      'micro_tags': [
        {'tag': 'crypto', 'label': 'Crypto'},
      ],
    },
  ],
  articles: {
    for (final a in [
      _story('a1', micros: ['llm_agents'], hoursAgo: 30),
      _story('a2', hoursAgo: 2, title: 'OpenAI ships a new agent'),
      _story(
        'f1',
        macro: 'Finance',
        micros: ['crypto'],
        hoursAgo: 1,
        factCheck: {
          'executive_synthesis': 'Checked.',
          'fact_check_verdict': 'Supported',
        },
      ),
      {..._story('x1'), 'tldr': null},
      _story('o1', macro: 'Off-Topic'),
    ])
      a['id'] as String: a,
  },
  digests: {
    'AI': {'macro_tag': 'AI', 'cluster_title': 'AI today', 'articles': []},
    '_all': {'macro_tag': '', 'cluster_title': 'All', 'articles': []},
  },
  profiles: const [
    SnapshotProfile(
      username: 'demo_ai',
      macros: ['AI'],
      micros: ['llm_agents'],
      latest: {'headline': 'AI headline', 'paragraph': 'p', 'articles': []},
    ),
    SnapshotProfile(
      username: 'demo_finance',
      macros: ['Finance'],
      micros: ['crypto'],
      latest: {
        'headline': 'Finance headline',
        'paragraph': 'p',
        'articles': [],
      },
    ),
  ],
  tavilyCalls: const [
    {'id': 1, 'endpoint': 'search', 'purpose': 'seed_ingestion'},
    {'id': 2, 'endpoint': 'search', 'purpose': 'seed_ingestion'},
  ],
);

({ApiService api, OfflineBackend backend, LocalStore store}) _offline() {
  final store = LocalStore.memory();
  final backend = OfflineBackend(
    snapshot: Future.value(_snapshot()),
    store: Future.value(store),
    clock: () => _now,
  );
  return (
    api: ApiService(baseUrl: '', client: backend),
    backend: backend,
    store: store,
  );
}

Future<AppUser> _signIn(ApiService api, [String name = 'visitor']) async {
  final session = await api.login(name, 'any password');
  api.authToken = session.token;
  return session.user;
}

void main() {
  group('OfflineBackend', () {
    test('sign-in creates an account that onboarding completes', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      expect(user.onboardingCompleted, isFalse);
      expect(o.api.authToken, startsWith(OfflineBackend.tokenPrefix));
      expect((await o.api.me()).id, user.id);

      final result = await o.api.updatePreferences(
        user.id,
        macroTags: ['ai'],
        microTags: ['llm_agents'],
        interestContext: 'I build agents.',
      );
      expect(result.user.onboardingCompleted, isTrue);
      expect(result.user.preferredMacroTags, ['AI']);
      expect(result.interestSummary, 'I build agents.');

      // Same username again: same account, picks kept.
      o.api.authToken = null;
      final again = await _signIn(o.api);
      expect(again.id, user.id);
      expect(again.preferredMicroTags, ['llm_agents']);
    });

    test('unknown token is 401 (the app signs out quietly)', () async {
      final o = _offline();
      o.api.authToken = 'server-token';
      await expectLater(
        o.api.me(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.unauthorized,
          ),
        ),
      );
    });

    test('personal feed ranks by picks and hides unshowable stories', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      await o.api.updatePreferences(
        user.id,
        macroTags: ['AI'],
        microTags: ['llm_agents'],
      );
      final feed = await o.api.getPersonalizedFeed(user.id, pageSize: 50);
      final ids = feed.articles.map((a) => a.id).toList();
      expect(feed.isFallback, isFalse);
      // a1 matches the subtopic, a2 only the category; f1 fills the feed.
      expect(ids, ['a1', 'a2', 'f1']);
      expect(feed.articles.first.personalScore, 99);
      expect(feed.articles.first.cleanText, isNull, reason: 'list item');
    });

    test('feed without picks is the date-ordered fallback', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      final feed = await o.api.getPersonalizedFeed(user.id);
      expect(feed.isFallback, isTrue);
      expect(feed.articles.map((a) => a.id), ['f1', 'a2', 'a1']);
    });

    test('like follows the server rules and dislike hides the story', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      await o.api.updatePreferences(user.id, macroTags: ['AI']);

      final like = await o.api.toggleInteraction(
        'f1',
        userId: user.id,
        type: InteractionType.like,
      );
      expect(like.active, isTrue);
      expect(like.preferredMacroTags, ['AI', 'Finance']);
      expect(like.preferredMicroTags, ['crypto']);

      final undo = await o.api.toggleInteraction(
        'f1',
        userId: user.id,
        type: InteractionType.like,
      );
      expect(undo.active, isFalse);

      await o.api.toggleInteraction(
        'a2',
        userId: user.id,
        type: InteractionType.dislike,
      );
      final feed = await o.api.getPersonalizedFeed(user.id, pageSize: 50);
      expect(feed.articles.map((a) => a.id), isNot(contains('a2')));
    });

    test('story detail has the full text; list and category filter', () async {
      final o = _offline();
      final a = await o.api.getArticle('a1');
      expect(a.cleanText, 'Full text of a1.');
      final finance = await o.api.getArticles(macro: 'Finance');
      expect(finance.map((a) => a.id), ['f1']);
    });

    test('saved Fact Check replays as the server cache stream', () async {
      final o = _offline();
      final events = await o.api.deepInspectStream('f1').toList();
      expect(events.map((e) => e.event), ['status', 'final']);
      final result = FactCheckResult.fromJson(
        jsonDecode(events.last.data) as Map<String, dynamic>,
      );
      expect(result.isCached, isTrue);
      expect(result.factCheckVerdict, 'Supported');

      final none = await o.api.deepInspectStream('a1').toList();
      expect(none.single.event, 'error');
    });

    test('latest developments come from the closest profile', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      await o.api.updatePreferences(
        user.id,
        macroTags: ['Finance', 'AI'],
        microTags: ['crypto'],
      );
      final latest = await o.api.getLatestDevelopments(user.id);
      expect(latest.headline, 'Finance headline');
      expect(latest.refreshing, isFalse);
    });

    test('latest developments without picks is 409 like the server', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      await expectLater(
        o.api.getLatestDevelopments(user.id),
        throwsA(isA<ApiException>()),
      );
    });

    test('daily digest by category, then the general one', () async {
      final o = _offline();
      expect(
        (await o.api.getDailyDigest(macro: 'AI')).clusterTitle,
        'AI today',
      );
      expect(
        (await o.api.getDailyDigest(macro: 'Science')).clusterTitle,
        'All',
      );
    });

    test('search finds title words and never asks again', () async {
      final o = _offline();
      final r = await o.api.searchGrouped('openai agent');
      expect(r.direct.first.article.id, 'a2');
      expect(r.semantic, isTrue);
    });

    test('comments and follows are kept on the device', () async {
      final o = _offline();
      final user = await _signIn(o.api);
      await o.api.postComment('a1', user: user, commentText: 'Nice');
      final comments = await o.api.getComments('a1');
      expect(comments.single.comment, 'Nice');
      expect(comments.single.username, 'visitor');

      for (final name in ['A', 'B', 'C']) {
        await o.api.addFollow(user.id, name: name, macro: 'AI');
      }
      await expectLater(
        o.api.addFollow(user.id, name: 'D', macro: 'AI'),
        throwsA(isA<ApiException>()),
      );
      final follows = await o.api.getFollows(user.id);
      await o.api.removeFollow(user.id, follows.first.id!);
      expect((await o.api.getFollows(user.id)).length, 2);
    });

    test('Tavily calls page like the server', () async {
      final o = _offline();
      final all = await o.api.getTavilyCalls(limit: 100);
      expect(all.calls.length, 2);
      expect(all.latestId, 2);
      expect((await o.api.getTavilyCalls(afterId: 2)).calls, isEmpty);
    });

    test('AI endpoints answer 503', () async {
      final o = _offline();
      await expectLater(
        o.api.synthesizeArticles(['a1', 'a2']),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.unavailable,
          ),
        ),
      );
    });

    test('fresh server stories overlay the bundle and are pruned', () async {
      final o = _offline();
      await o.backend.ready;
      await o.backend.addFresh([
        {..._story('a1'), 'title': 'Updated a1', 'personal_score': 80}
          ..remove('clean_text'),
        _story('old', hoursAgo: 24 * 40),
      ]);
      final a1 = await o.api.getArticle('a1');
      expect(a1.title, 'Updated a1');
      expect(a1.cleanText, 'Full text of a1.', reason: 'kept from bundle');
      final fresh = o.store.all(LocalStore.freshArticles);
      expect(fresh.keys, ['a1'], reason: 'older than 30 days dropped');
      expect(fresh['a1']!.containsKey('personal_score'), isFalse);
    });
  });

  group('BackendClient', () {
    BackendClient client(
      http.Client inner, {
      String base = 'https://api.test',
      LocalStore? store,
      Duration writeTimeout = const Duration(seconds: 90),
    }) {
      final s = Future.value(store ?? LocalStore.memory());
      return BackendClient(
        baseUrl: base,
        inner: inner,
        store: s,
        writeTimeout: writeTimeout,
        offline: OfflineBackend(
          snapshot: Future.value(_snapshot()),
          store: s,
          clock: () => _now,
        ),
      );
    }

    test('empty API_BASE_URL never calls the network', () async {
      var calls = 0;
      final c = client(
        MockClient((_) async {
          calls++;
          return http.Response('[]', 200);
        }),
        base: '',
      );
      final api = ApiService(baseUrl: '', client: c);
      expect((await api.getTaxonomy()).length, 2);
      expect(await c.mode, BackendMode.offline);
      expect(c.isLive, isFalse);
      expect(calls, 0);
    });

    test('unreachable server: offline session', () async {
      final c = client(
        MockClient((_) async => throw http.ClientException('x')),
      );
      expect(await c.mode, BackendMode.offline);
    });

    MockClient liveServer(http.Response Function(http.Request) answer) =>
        MockClient((r) async {
          if (r.url.path == '/api/taxonomy') return http.Response('[]', 200);
          return answer(r);
        });

    test('live: a hung write fails with an error and is not stored', () async {
      final hang = Completer<http.Response>();
      final c = client(
        MockClient((r) async {
          if (r.url.path == '/api/taxonomy') return http.Response('[]', 200);
          return hang.future;
        }),
        writeTimeout: const Duration(milliseconds: 50),
      );
      final api = ApiService(baseUrl: 'https://api.test', client: c);
      await expectLater(
        api.postComment('a1', user: _liveUser, commentText: 'Hi'),
        throwsA(isA<ApiException>()),
      );
      final local = ApiService(baseUrl: '', client: c.offline);
      expect(await local.getComments('a1'), isEmpty);
    });

    test('live: 5xx and network errors fall back, 4xx passes', () async {
      final c = client(
        liveServer((r) {
          if (r.url.path == '/api/articles/a1') return http.Response('', 502);
          if (r.url.path == '/api/articles/a2') throw http.ClientException('x');
          return http.Response('{"detail":"nope"}', 404);
        }),
      );
      final api = ApiService(baseUrl: 'https://api.test', client: c);
      expect((await api.getArticle('a1')).cleanText, 'Full text of a1.');
      expect((await api.getArticle('a2')).id, 'a2');
      expect(c.isLive, isTrue);
      await expectLater(
        api.getArticle('zz'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.notFound,
          ),
        ),
      );
    });

    test(
      'live: an offline token is refused without calling the server',
      () async {
        var hits = 0;
        final c = client(
          liveServer((_) {
            hits++;
            return http.Response('{}', 200);
          }),
        );
        final api = ApiService(baseUrl: 'https://api.test', client: c)
          ..authToken = '${OfflineBackend.tokenPrefix}abc';
        await expectLater(
          api.me(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.kind,
              'kind',
              ApiErrorKind.unauthorized,
            ),
          ),
        );
        expect(hits, 0);
      },
    );

    test('live: stories the server sends are kept on the device', () async {
      final store = LocalStore.memory();
      final c = client(
        liveServer((_) => http.Response(jsonEncode([_story('n1')]), 200)),
        store: store,
      );
      final api = ApiService(baseUrl: 'https://api.test', client: c);
      expect((await api.getArticles()).single.id, 'n1');
      await pumpEventQueue();
      expect(store.all(LocalStore.freshArticles).keys, contains('n1'));
    });
  });

  group('ranking', () {
    test('closest profile prefers shared categories, then the first', () {
      final profiles = [
        (macros: ['AI', 'Tech'], micros: <String>[]),
        (macros: ['Finance'], micros: ['crypto']),
        (macros: ['AI'], micros: ['llm_agents']),
      ];
      expect(closestProfile(['AI'], ['llm_agents'], profiles), 2);
      expect(closestProfile(['Finance', 'AI'], [], profiles), 1);
      expect(closestProfile([], [], const []), -1);
    });

    test('follow names match whole words only', () {
      final a = {'title': 'Intel cuts prices', 'tldr': ''};
      expect(matchedFollows(a, ['Intel', 'Int']), ['Intel']);
    });
  });
}

const _liveUser = AppUser(
  id: '00000000-0000-4000-8000-000000000001',
  username: 'someone',
);
