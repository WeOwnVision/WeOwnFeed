import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:weownfeed/models/api_models.dart';
import 'package:weownfeed/services/api_service.dart';

const _article = {
  'id': '82a5ecf9-e6ab-4152-afae-5ca536361bd5',
  'source': 'Wired',
  'title': 'Automakers Accelerate Next-Gen Solid-State Battery Roadmaps',
  'url': 'https://wired.com/x',
  'author': 'Steven Levy',
  'published_at': '2026-10-08T10:00:00+00:00',
  'macro_tag': 'Tech',
  'macro_tags': ['Tech', 'Hardware'],
  'micro_tags': ['solid_state_battery'],
  'tldr': 'Batteries are getting better.',
};

const _benchmark = {
  'id': 'dc5c5475-1427-4e29-a486-d9fcb771daff',
  'source': 'Benchmark News',
  'title': 'Automated Pipeline Integrity Verification Article',
  'url': 'https://eval.example.com/x',
  'author': 'QA Bot',
  'published_at': '2026-10-10T12:00:00+00:00',
  'macro_tag': null,
  'macro_tags': <String>[],
  'micro_tags': null,
  'tldr': null,
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

ApiService _api(MockClientHandler handler) =>
    ApiService(baseUrl: 'https://api.test/', client: MockClient(handler));

void main() {
  group('getArticles', () {
    test('sends page/page_size and bypass header, hides test data', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json([_article, _benchmark]);
      });

      final articles = await api.getArticles(
        page: 2,
        pageSize: 5,
        macro: 'Tech',
      );

      expect(sent.url.path, '/api/articles');
      expect(sent.url.queryParameters, {
        'page': '2',
        'page_size': '5',
        'macro': 'Tech',
      });
      expect(sent.headers['bypass-tunnel-reminder'], 'true');
      expect(articles, hasLength(1));
      final a = articles.single;
      expect(a.source, 'Wired');
      expect(a.macroTags, ['Tech', 'Hardware']);
      expect(a.publishedAt, DateTime.utc(2026, 10, 8, 10));
    });

    test('clamps invalid paging values', () async {
      late Uri url;
      final api = _api((req) async {
        url = req.url;
        return _json([]);
      });
      await api.getArticles(page: 0, pageSize: 1000);
      expect(url.queryParameters['page'], '1');
      expect(url.queryParameters['page_size'], '100');
    });

    test('page of only test data still reports hasMore', () async {
      final api = _api((_) async => _json([_benchmark, _benchmark]));
      final page = await api.getArticlePage(pageSize: 2);
      expect(page.items, isEmpty);
      expect(page.hasMore, isTrue);
    });

    test('null macro_tags falls back to macro_tag', () {
      final a = Article.fromJson({..._article, 'macro_tags': null});
      expect(a.macroTags, ['Tech']);
    });
  });

  group('errors', () {
    test('tunnel down (503 plain text) -> unavailable', () async {
      final api = _api(
        (_) async => http.Response('503 - Tunnel Unavailable', 503),
      );
      await expectLater(
        api.getArticles(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.unavailable)
              .having(
                (e) => e.userMessage,
                'userMessage',
                contains('Server unavailable'),
              ),
        ),
      );
    });

    test('500 -> server with generic English message', () async {
      final api = _api(
        (_) async => http.Response('Internal Server Error', 500),
      );
      await expectLater(
        api.getArticle('abc'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.server)
              .having(
                (e) => e.userMessage,
                'userMessage',
                'Something went wrong. Please try again.',
              ),
        ),
      );
    });

    test('422 validation detail is surfaced', () async {
      final api = _api(
        (_) async => _json({
          'detail': [
            {'msg': 'String should have at least 2 characters'},
          ],
        }, 422),
      );
      await expectLater(
        api.getComments('a1'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'String should have at least 2 characters',
          ),
        ),
      );
    });

    test('network failure -> network', () async {
      final api = _api(
        (_) async => throw http.ClientException('XMLHttpRequest error'),
      );
      await expectLater(
        api.getArticles(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.network,
          ),
        ),
      );
    });

    test('non-JSON 200 -> invalidResponse', () async {
      final api = _api((_) async => http.Response('<html>tunnel</html>', 200));
      await expectLater(
        api.getArticles(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.invalidResponse,
          ),
        ),
      );
    });
  });

  group('search', () {
    test('short query does not hit the server', () async {
      var calls = 0;
      final api = _api((_) async {
        calls++;
        return _json([]);
      });
      expect(await api.searchArticles(' a '), isEmpty);
      expect((await api.searchGrouped('a')).isEmpty, isTrue);
      expect(calls, 0);
    });

    test('grouped search parses direct/explore', () async {
      late Uri url;
      final api = _api((req) async {
        url = req.url;
        return _json({
          'query': 'battery',
          'total_direct': 1,
          'total_explore': 1,
          'direct': [
            {..._article, 'match_tier': 'direct', 'relevance_score': 91},
          ],
          'explore': [
            {
              ..._article,
              'id': 'other',
              'match_tier': 'explore',
              'relevance_score': 62,
              'possibility': 'Adjacent Horizon',
              'explore_angle': 'Energy & Materials',
            },
            {..._benchmark, 'match_tier': 'explore'},
          ],
        });
      });

      final r = await api.searchGrouped('battery');
      expect(url.queryParameters, {'q': 'battery', 'grouped': 'true'});
      expect(r.direct.single.isDirect, isTrue);
      expect(r.direct.single.relevanceScore, 91);
      expect(r.explore, hasLength(1));
      expect(r.explore.single.exploreAngle, 'Energy & Materials');
    });
  });

  group('chat', () {
    test('sends question + last 4 history turns, returns text', () async {
      late Map<String, dynamic> body;
      final api = _api((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode('Solid‑state batteries charge in 10 minutes.'),
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      });

      final answer = await api.chatWithArticle(
        'id-1',
        question: ' Why? ',
        history: [for (var i = 0; i < 6; i++) ChatTurn.user('q$i')],
      );

      expect(answer, 'Solid‑state batteries charge in 10 minutes.');
      expect(body['question'], 'Why?');
      expect((body['history'] as List).map((t) => t['content']), [
        'q2',
        'q3',
        'q4',
        'q5',
      ]);
    });

    test('empty 200 body -> emptyResponse', () async {
      final api = _api((_) async => http.Response('', 200));
      await expectLater(
        api.chatWithArticle('id-1', question: 'hi'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.emptyResponse)
              .having(
                (e) => e.userMessage,
                'userMessage',
                'Something went wrong. Please try again.',
              ),
        ),
      );
    });

    test('whitespace-only body -> emptyResponse', () async {
      final api = _api((_) async => http.Response('  \n ', 200));
      await expectLater(
        api.chatWithArticle('id-1', question: 'hi'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.emptyResponse,
          ),
        ),
      );
    });
  });

  group('sse', () {
    ApiService sse(List<String> chunks) => ApiService(
      baseUrl: 'https://api.test',
      client: MockClient.streaming(
        (req, _) async => http.StreamedResponse(
          Stream.fromIterable(chunks.map(utf8.encode)),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        ),
      ),
    );

    test('joins tokens split across chunks and stops at [DONE]', () async {
      final api = sse([
        'data: {"token": "Hel',
        'lo"}\n\ndata: {"token": " wor',
        'ld"}\r\n\r\ndata: {"token": "\u202f!"}\n\ndata: [DONE]\n\n',
        'data: {"token": "ignored"}\n\n',
      ]);
      expect(
        await api.chatWithArticle('a', question: 'q'),
        'Hello world\u202f!',
      );
    });

    test('waiChatStream sends the scope, sources and recent history', () async {
      late http.Request sent;
      final api = ApiService(
        baseUrl: 'https://api.test',
        client: MockClient.streaming((req, body) async {
          sent = http.Request(req.method, req.url)
            ..bodyBytes = await body.toBytes();
          return http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('data: {"token": "Yes [1]."}\n\ndata: [DONE]\n\n'),
            ]),
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      final text = await api
          .waiChatStream(
            userId: 'u1',
            mode: 'area',
            area: 'AI',
            sourceIds: ['a1', 'a2'],
            question: ' Yes please ',
            history: [
              for (var i = 0; i < 8; i++) ChatTurn.assistant('turn $i'),
            ],
          )
          .join();
      expect(text, 'Yes [1].');
      expect(sent.url.path, '/api/wai/chat');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['mode'], 'area');
      expect(body['area'], 'AI');
      expect(body.containsKey('article_id'), isFalse);
      expect(body['source_ids'], ['a1', 'a2']);
      expect(body['question'], 'Yes please');
      expect((body['history'] as List).length, 6);
      expect((body['history'] as List).first['content'], 'turn 2');
    });

    test('error event -> server error', () async {
      final api = sse([
        'data: {"token": "Hi"}\n\n',
        'data: {"error": "model crashed"}\n\n',
      ]);
      await expectLater(
        api.chatWithArticle('a', question: 'q'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.server)
              .having((e) => e.message, 'message', 'model crashed'),
        ),
      );
    });

    test('only [DONE] -> emptyResponse', () async {
      final api = sse(['data: [DONE]\n\n']);
      await expectLater(
        api.chatWithArticle('a', question: 'q'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.emptyResponse,
          ),
        ),
      );
    });

    test('synthesize stream yields markdown tokens', () async {
      final api = sse([
        'data: {"token": "**1."}\n\ndata: {"token": " Shared**"}\n\n',
        'data: [DONE]\n\n',
      ]);
      expect(await api.synthesizeArticles(['a', 'b']), '**1. Shared**');
    });
  });

  group('synthesize', () {
    test('needs at least 2 ids', () async {
      final api = _api((_) async => fail('should not be called'));
      await expectLater(
        api.synthesizeArticles(['one']),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.badRequest,
          ),
        ),
      );
    });

    test('returns markdown text', () async {
      final api = _api(
        (_) async => http.Response('**1. Shared Consensus**', 200),
      );
      expect(
        await api.synthesizeArticles(['a', 'b']),
        '**1. Shared Consensus**',
      );
    });
  });

  group('users & comments', () {
    const user = AppUser(
      id: 'u1',
      username: 'can_test',
      avatarUrl: 'https://a/x',
    );

    test('login trims the username and returns user + token', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'user': {
            'id': 'u1',
            'username': 'can_test',
            'avatar_url': 'https://a/x',
          },
          'token': 'token-1',
        });
      });
      final session = await api.login('  can_test ', 'secret-pass');
      expect(sent.url.path, '/api/auth/login');
      expect(jsonDecode(sent.body), {
        'username': 'can_test',
        'password': 'secret-pass',
      });
      expect(session.user.id, 'u1');
      expect(session.token, 'token-1');
    });

    test('register posts to /api/auth/register', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'user': {'id': 'u2', 'username': 'new_one'},
          'token': 'token-2',
        }, 201);
      });
      final session = await api.register('new_one', 'secret-pass');
      expect(sent.url.path, '/api/auth/register');
      expect(session.token, 'token-2');
    });

    test('empty username or password is rejected locally', () async {
      final api = _api((_) async => fail('should not be called'));
      await expectLater(api.login('  ', 'x'), throwsA(isA<ApiException>()));
      await expectLater(api.login('can', ''), throwsA(isA<ApiException>()));
    });

    test('401 and 429 keep the server message', () async {
      for (final (code, kind) in [
        (401, ApiErrorKind.unauthorized),
        (429, ApiErrorKind.rateLimited),
      ]) {
        final api = _api((_) async => _json({'detail': 'Nope ($code)'}, code));
        await expectLater(
          api.login('can', 'secret-pass'),
          throwsA(
            isA<ApiException>()
                .having((e) => e.kind, 'kind', kind)
                .having((e) => e.userMessage, 'userMessage', 'Nope ($code)'),
          ),
        );
      }
    });

    test('postComment fills the comment from the response id', () async {
      late Map<String, dynamic> body;
      final api = _api((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({'id': 'c1', 'created_at': '2026-10-12T10:00:00+00:00'});
      });
      final c = await api.postComment(
        'a1',
        user: user,
        commentText: ' Nice ',
        selectedText: '',
      );
      expect(body, {'user_id': 'u1', 'comment_text': 'Nice'});
      expect(c.id, 'c1');
      expect(c.username, 'can_test');
      expect(c.comment, 'Nice');
    });

    test('getComments maps the "comment" field', () async {
      final api = _api(
        (_) async => _json([
          {
            'id': 'c1',
            'selected_text': 'Steam Deck 2',
            'comment': 'Great',
            'created_at': '2026-10-12T10:00:00+00:00',
            'username': 'alice',
            'avatar_url': null,
          },
        ]),
      );
      final c = (await api.getComments('a1')).single;
      expect(c.comment, 'Great');
      expect(c.selectedText, 'Steam Deck 2');
    });

    test('login parses onboarding state and preferences', () async {
      final api = _api(
        (_) async => _json({
          'user': {
            'id': 'u1',
            'username': 'can_test',
            'avatar_url': null,
            'onboarding_completed': true,
            'preferred_macro_tags': ['AI', 'Gaming'],
            'preferred_micro_tags': ['llm_agents'],
          },
          'token': 'token-1',
        }),
      );
      final u = (await api.login('can_test', 'secret-pass')).user;
      expect(u.onboardingCompleted, isTrue);
      expect(u.preferredMacroTags, ['AI', 'Gaming']);
      expect(u.preferredMicroTags, ['llm_agents']);
    });

    test('login without onboarding fields means onboarding needed', () async {
      final api = _api(
        (_) async => _json({
          'user': {'id': 'u1', 'username': 'x'},
          'token': 't',
        }),
      );
      final u = (await api.login('x', 'secret-pass')).user;
      expect(u.onboardingCompleted, isFalse);
      expect(u.preferredMacroTags, isEmpty);
    });
  });

  group('personalization', () {
    test('getTaxonomy parses categories and labelled topics', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json([
          {
            'macro': 'AI',
            'display_name': 'Artificial Intelligence',
            'description': 'Large language models',
            'micro_tags': [
              {'tag': 'llm_agents', 'label': 'LLM Agents'},
            ],
          },
        ]);
      });
      final t = (await api.getTaxonomy()).single;
      expect(sent.url.path, '/api/taxonomy');
      expect(t.macro, 'AI');
      expect(t.displayName, 'Artificial Intelligence');
      expect(t.microTags.single.tag, 'llm_agents');
      expect(t.microTags.single.label, 'LLM Agents');
    });

    test('updatePreferences sends PUT with tags', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'id': 'u1',
          'username': 'can',
          'avatar_url': null,
          'onboarding_completed': true,
          'preferred_macro_tags': ['AI'],
          'preferred_micro_tags': ['llm_agents'],
          'interest_summary': 'Technical news and updates in Ai.',
        });
      });
      final r = await api.updatePreferences(
        'u1',
        macroTags: ['AI'],
        microTags: ['llm_agents'],
      );
      expect(sent.method, 'PUT');
      expect(sent.url.path, '/api/users/u1/preferences');
      expect(jsonDecode(sent.body), {
        'preferred_macro_tags': ['AI'],
        'preferred_micro_tags': ['llm_agents'],
      });
      expect(r.user.onboardingCompleted, isTrue);
      expect(r.user.interestContext, isNull);
      expect(r.interestSummary, 'Technical news and updates in Ai.');
    });

    test(
      'updatePreferences sends the context sentence, empty clears',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final api = _api((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          bodies.add(body);
          return _json({
            'id': 'u1',
            'username': 'can',
            'onboarding_completed': true,
            'preferred_macro_tags': ['Finance'],
            'preferred_micro_tags': <String>[],
            'interest_context': body['interest_context'] == ''
                ? null
                : 'Yatırım yapıyorum',
            'interest_summary': "I'm investing.",
          });
        });
        final r = await api.updatePreferences(
          'u1',
          macroTags: ['Finance'],
          interestContext: 'Yatırım yapıyorum',
        );
        expect(bodies.last['interest_context'], 'Yatırım yapıyorum');
        expect(r.user.interestContext, 'Yatırım yapıyorum');

        final cleared = await api.updatePreferences(
          'u1',
          macroTags: ['Finance'],
          interestContext: '',
        );
        expect(bodies.last['interest_context'], '');
        expect(cleared.user.interestContext, isNull);
      },
    );

    test('updatePreferences without a category is rejected locally', () async {
      final api = _api((_) async => fail('should not be called'));
      await expectLater(
        api.updatePreferences('u1', macroTags: const []),
        throwsA(isA<ApiException>()),
      );
    });

    test('getPersonalizedFeed sends user/page, parses score and fallback', () {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'user_id': 'u1',
          'is_fallback': false,
          'total': 2,
          'page': 2,
          'page_size': 2,
          'articles': [
            {..._article, 'personal_score': 76, 'is_liked': true},
            {..._benchmark, 'personal_score': 50, 'is_liked': false},
          ],
        });
      });
      return api.getPersonalizedFeed('u1', page: 2, pageSize: 2).then((feed) {
        expect(sent.url.path, '/api/feed/personalized');
        expect(sent.url.queryParameters, {
          'user_id': 'u1',
          'page': '2',
          'page_size': '2',
        });
        expect(feed.isFallback, isFalse);
        // The test record is hidden but the page was full, so more may follow.
        expect(feed.articles.single.personalScore, 76);
        expect(feed.articles.single.isLiked, isTrue);
        expect(feed.hasMore, isTrue);
      });
    });

    test('fallback feed is flagged', () async {
      final api = _api(
        (_) async => _json({
          'is_fallback': true,
          'articles': [
            {..._article, 'personal_score': 50, 'is_liked': false},
          ],
        }),
      );
      final feed = await api.getPersonalizedFeed('u1');
      expect(feed.isFallback, isTrue);
      expect(feed.hasMore, isFalse);
    });

    test('setInteraction toggles again if the server state differs', () async {
      final bodies = <Map<String, dynamic>>[];
      var serverLiked = true; // Already liked on the server.
      final api = _api((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        serverLiked = !serverLiked;
        return _json({
          'status': serverLiked ? 'recorded' : 'removed',
          'active': serverLiked,
        });
      });
      final active = await api.setInteraction(
        'a1',
        userId: 'u1',
        type: InteractionType.like,
        active: true,
      );
      expect(active.active, isTrue);
      expect(bodies, hasLength(2));
      expect(bodies.first, {'user_id': 'u1', 'interaction_type': 'like'});
    });

    test('setInteraction sends once when the toggle matches', () async {
      var calls = 0;
      late Uri url;
      final api = _api((req) async {
        calls++;
        url = req.url;
        return _json({'status': 'recorded', 'active': true});
      });
      await api.setInteraction(
        'a1',
        userId: 'u1',
        type: InteractionType.bookmark,
        active: true,
      );
      expect(calls, 1);
      expect(url.path, '/api/articles/a1/interactions');
    });

    test('dislike sends its type and returns learned preferences', () async {
      late Map<String, dynamic> body;
      final api = _api((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'status': 'recorded',
          'active': true,
          'interaction_type': 'dislike',
          'ema_updated': true,
          'updated_preferred_macro_tags': ['Tech', 'Finance'],
          'updated_preferred_micro_tags': ['software'],
        });
      });
      final r = await api.toggleInteraction(
        'a1',
        userId: 'u1',
        type: InteractionType.dislike,
      );
      expect(body['interaction_type'], 'dislike');
      expect(r.active, isTrue);
      expect(r.preferredMacroTags, ['Tech', 'Finance']);
      expect(r.preferredMicroTags, ['software']);
    });

    test('removed interaction carries no preference update', () async {
      final api = _api(
        (_) async => _json({'status': 'removed', 'active': false}),
      );
      final r = await api.toggleInteraction(
        'a1',
        userId: 'u1',
        type: InteractionType.like,
      );
      expect(r.active, isFalse);
      expect(r.preferredMacroTags, isNull);
      expect(r.preferredMicroTags, isNull);
    });

    test('follows: list, add (trimmed) and remove', () async {
      final calls = <String>[];
      final api = _api((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.method == 'POST') {
          expect(jsonDecode(req.body), {'name': 'Revolut', 'macro': 'Finance'});
          return _json({'id': 'f1', 'name': 'Revolut', 'macro': 'Finance'});
        }
        if (req.method == 'DELETE') return _json({'status': 'removed'});
        return _json([
          {'id': 'f1', 'name': 'Revolut', 'macro': 'Finance'},
        ]);
      });
      final list = await api.getFollows('u1');
      expect(list.single.name, 'Revolut');
      expect(list.single.key, 'revolut');
      final created = await api.addFollow(
        'u1',
        name: '  Revolut ',
        macro: 'Finance',
      );
      expect(created.id, 'f1');
      await api.removeFollow('u1', 'f1');
      expect(calls, [
        'GET /api/users/u1/follows',
        'POST /api/users/u1/follows',
        'DELETE /api/users/u1/follows/f1',
      ]);
    });

    test('follow limit error is surfaced', () async {
      final api = _api(
        (_) async => _json({'detail': 'You can follow up to 3 things.'}, 400),
      );
      await expectLater(
        api.addFollow('u1', name: 'Wise', macro: 'Finance'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.userMessage,
            'message',
            'You can follow up to 3 things.',
          ),
        ),
      );
    });

    test('feed article carries matched follows', () {
      final a = Article.fromJson({
        ..._article,
        'personal_score': 81,
        'matched_follows': ['Revolut'],
      });
      expect(a.matchedFollows, ['Revolut']);
    });

    test('openWai sends the scope and parses the opening', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'mode': 'story',
          'title': 'Banks block AI agents',
          'subtitle': 'Story chat',
          'opening': 'This story is about banks. Want the key points?',
          'sources': [
            {'id': 'a1', 'title': 'Banks block AI agents', 'tldr': 'They do.'},
          ],
        });
      });
      final o = await api.openWai(userId: 'u1', mode: 'story', articleId: 'a1');
      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/wai/open');
      expect(jsonDecode(sent.body), {
        'user_id': 'u1',
        'mode': 'story',
        'article_id': 'a1',
      });
      expect(o.title, 'Banks block AI agents');
      expect(o.subtitle, 'Story chat');
      expect(o.opening, startsWith('This story is about banks.'));
      expect(o.sources.single.id, 'a1');
    });

    test('getLatestDevelopments parses the card and its stories', () async {
      late http.Request sent;
      final api = _api((req) async {
        sent = req;
        return _json({
          'headline': 'Banks curb AI agents as fintech funding triples',
          'paragraph': 'Schwab and JPMorgan block AI agents.',
          'articles': [
            {'id': 'a1', 'title': 'Banks block AI agents', 'tldr': 'They do.'},
            {'title': 'no id, skipped'},
          ],
          'model': 'deepseek-ai/DeepSeek-V4-Flash-0731',
          'refreshing': true,
        });
      });
      final l = await api.getLatestDevelopments('u1');
      expect(sent.url.path, '/api/users/u1/latest-developments');
      expect(l.headline, 'Banks curb AI agents as fintech funding triples');
      expect(l.paragraph, 'Schwab and JPMorgan block AI agents.');
      expect(l.articles.single.id, 'a1');
      expect(l.refreshing, isTrue);
    });

    test('getDailyDigest parses report and articles', () async {
      late Uri url;
      final api = _api((req) async {
        url = req.url;
        return _json({
          'date': '2026-10-17',
          'macro_tag': 'AI',
          'cluster_title': 'AI Deep Verification Brief: X',
          'cluster_id': 'c1',
          'article_ids': ['a1'],
          'articles': [
            {
              'id': 'a1',
              'source': 'Wired',
              'title': 'X',
              'url': 'https://x',
              'tldr': 'Y',
            },
          ],
          'tavily_sources': [],
          'synthesis_report': '**1. Shared Consensus**',
          'is_cached': true,
        });
      });
      final d = await api.getDailyDigest(userId: 'u1');
      expect(url.path, '/api/intelligence/daily-digest');
      expect(url.queryParameters, {'user_id': 'u1'});
      expect(d.macroTag, 'AI');
      expect(d.report, '**1. Shared Consensus**');
      expect(d.articles.single.source, 'Wired');
      expect(d.isCached, isTrue);
    });
  });
}
