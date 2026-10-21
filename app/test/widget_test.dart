import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:weownfeed/screens/home_page.dart';
import 'package:weownfeed/services/api_service.dart';
import 'package:weownfeed/state/app_state.dart';
import 'package:weownfeed/web/web_gate.dart';
import 'package:weownfeed/web/web_shell.dart';

Map<String, Object?> _article(int i) => {
  'id': 'id-$i',
  'source': 'Source $i',
  'title': 'Story number $i about chips',
  'url': 'https://example.com/$i',
  'author': 'Author $i',
  'published_at': '2026-10-09T1$i:00:00+00:00',
  'macro_tag': 'Tech',
  'macro_tags': ['Tech', 'Hardware'],
  'micro_tags': ['semiconductors', 'gpu'],
  'tldr': 'Short summary of story $i.',
};

String _sse(List<String> tokens) => [
  for (final t in tokens) 'data: ${jsonEncode({'token': t})}\n\n',
  'data: [DONE]\n\n',
].join();

const _taxonomy = [
  {
    'macro': 'AI',
    'display_name': 'Artificial Intelligence',
    'description': 'Large language models, autonomous agents',
    'micro_tags': [
      {'tag': 'llm_agents', 'label': 'LLM Agents'},
      {'tag': 'nvidia', 'label': 'NVIDIA'},
    ],
  },
  {
    'macro': 'Gaming',
    'display_name': 'Gaming & Handhelds',
    'description': 'Video games, consoles, Steam Deck',
    'micro_tags': [
      {'tag': 'steam_deck', 'label': 'Steam Deck'},
    ],
  },
];

/// Requests that reached the fake server (method + path + body).
final _requests = <http.Request>[];

const _password = 'correct-horse';

/// Client that imitates the server. With an empty [chatReply] the chat streams
/// nothing. With [onboarded] `false` the signed-in user has picked no interests.
MockClient _server({
  String chatReply = 'It is about faster chips.',
  bool onboarded = true,
}) {
  var macros = onboarded ? ['AI'] : <String>[];
  var micros = onboarded ? ['llm_agents'] : <String>[];
  String? why = onboarded ? 'I build products' : null;
  // Interactions on the server: "id-0:like", "id-1:dislike", ...
  final interactions = <String>{};
  bool has(String id, String type) => interactions.contains('$id:$type');
  // "+" follows; id-3 is the story that names the followed thing.
  final follows = <Map<String, Object?>>[];
  return MockClient((req) async {
    _requests.add(req);
    final path = req.url.path;
    http.Response json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
    http.Response sse(String body) => http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );

    if (path == '/api/articles') {
      final page = int.parse(req.url.queryParameters['page'] ?? '1');
      return json(page == 1 ? [for (var i = 0; i < 6; i++) _article(i)] : []);
    }
    if (path == '/api/search') {
      final q = req.url.queryParameters['q'];
      return json({
        'query': q,
        'direct': [
          {..._article(1), 'match_tier': 'direct', 'relevance_score': 95},
        ],
        'explore': [
          {
            ..._article(2),
            'match_tier': 'explore',
            'relevance_score': 60,
            'explore_angle': 'Compute & Acceleration',
          },
        ],
      });
    }
    Map<String, Object?> user([String username = 'can_test']) => {
      'id': 'u1',
      'username': username,
      'avatar_url': null,
      'onboarding_completed': macros.isNotEmpty,
      'preferred_macro_tags': macros,
      'preferred_micro_tags': micros,
      'interest_context': why,
    };

    if (path == '/api/auth/login' || path == '/api/auth/register') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return json({
        'user': user(body['username'] as String),
        'token': 'token-1',
      });
    }
    if (path == '/api/auth/me') return json(user());
    if (path == '/api/taxonomy') return json(_taxonomy);
    if (path.startsWith('/api/users/u1/follows')) {
      if (req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final created = {
          'id': 'f${follows.length + 1}',
          'name': body['name'],
          'macro': body['macro'],
        };
        follows.add(created);
        return json(created);
      }
      if (req.method == 'DELETE') {
        follows.removeWhere((f) => path.endsWith('/${f['id']}'));
        return json({'status': 'removed'});
      }
      return json(follows);
    }
    if (path == '/api/users/u1/preferences') {
      if (req.method == 'PUT') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        macros = List<String>.from(body['preferred_macro_tags'] as List);
        micros = List<String>.from(body['preferred_micro_tags'] as List);
        if (body.containsKey('interest_context')) {
          final text = body['interest_context'] as String;
          why = text.isEmpty ? null : text;
        }
        return json({
          ...user(),
          'interest_summary': 'Technical news and updates in Ai.',
        });
      }
      return json(user());
    }
    if (path == '/api/feed/personalized') {
      final page = int.parse(req.url.queryParameters['page'] ?? '1');
      return json({
        'user_id': 'u1',
        'is_fallback': macros.isEmpty,
        'articles': page == 1
            ? [
                for (var i = 0; i < 6; i++)
                  // Disliked stories leave the feed.
                  if (!has('id-$i', 'dislike'))
                    {
                      ..._article(i),
                      'personal_score': 90 - i,
                      'is_liked': has('id-$i', 'like'),
                      'is_disliked': false,
                      if (i == 3 && follows.isNotEmpty)
                        'matched_follows': [follows.first['name']],
                    },
              ]
            : [],
      });
    }
    if (path == '/api/users/u1/latest-developments') {
      if (macros.isEmpty) {
        return http.Response(
          jsonEncode({'detail': 'Pick your interests first'}),
          409,
        );
      }
      return json({
        'headline': 'Chipmakers race ahead as AI demand grows',
        'paragraph':
            'Story three and story four point the same way. '
            'Demand for AI chips keeps rising.',
        'articles': [_article(3), _article(4)],
        'model': 'deepseek-ai/DeepSeek-V4-Flash-0731',
        'refreshing': false,
      });
    }
    if (path == '/api/intelligence/daily-digest') {
      return json({
        'date': '2026-10-17',
        'macro_tag': macros.isEmpty ? 'Gaming' : macros.first,
        'cluster_title': 'Brief',
        'article_ids': ['id-1'],
        'articles': [_article(1)],
        'tavily_sources': [],
        'synthesis_report': '**1. Shared Consensus**\n- Verified.',
        'is_cached': false,
      });
    }
    if (path.endsWith('/interactions')) {
      // The server's behavior: toggles; like and dislike delete each other;
      // a like adds the story's category and first two tags to the preferences.
      final id = path.split('/')[3];
      final type =
          (jsonDecode(req.body) as Map<String, dynamic>)['interaction_type']
              as String;
      if (interactions.remove('$id:$type')) {
        return json({'status': 'removed', 'active': false});
      }
      if (type == 'like') interactions.remove('$id:dislike');
      if (type == 'dislike') interactions.remove('$id:like');
      interactions.add('$id:$type');
      if (type == 'like') {
        if (!macros.contains('Tech')) macros = [...macros, 'Tech'];
        micros = {'semiconductors', 'gpu', ...micros}.toList();
      }
      final learns = type == 'like' || type == 'dislike';
      return json({
        'status': 'recorded',
        'active': true,
        'updated_preferred_macro_tags': learns ? macros : null,
        'updated_preferred_micro_tags': learns ? micros : null,
      });
    }
    if (path == '/api/intelligence/synthesize') {
      return sse(_sse(['**1. Shared Consensus**\n', '- Chips are faster.']));
    }
    if (path == '/api/wai/open') {
      final mode = (jsonDecode(req.body) as Map<String, dynamic>)['mode'];
      return json({
        'mode': mode,
        'title': switch (mode) {
          'latest' => 'Chipmakers race ahead as AI demand grows',
          'area' => 'Artificial Intelligence',
          _ => 'Story number 0 about chips',
        },
        'subtitle': mode == 'story' ? 'Story chat' : '2 stories',
        'opening': mode == 'story'
            ? 'This story is about faster chips. Want the key points?'
            : "I've gone through the latest stories. Would you like me to "
                  'summarize the most striking aspects?',
        'sources': mode == 'story' ? [_article(0)] : [_article(3), _article(4)],
      });
    }
    if (path == '/api/wai/chat') {
      return sse(_sse(['Chip demand ', 'keeps rising [1].']));
    }
    if (path.endsWith('/chat')) {
      return sse(chatReply.isEmpty ? 'data: [DONE]\n\n' : _sse([chatReply]));
    }
    if (path.endsWith('/comments')) return json([]);
    if (path.startsWith('/api/articles/')) {
      return json({..._article(0), 'clean_text': 'Full text of the story.'});
    }
    return http.Response('not found', 404);
  });
}

Future<void> _settle(WidgetTester tester) async {
  // Fake requests finish in microtasks; a few frames are enough.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpAt(WidgetTester tester, Widget home, Size size) async {
  // The test font (Ahem) is much wider than real fonts, so overflow warnings
  // mean nothing here; every other error fails the test.
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: home));
  await _settle(tester);
}

/// Stream-based requests do not finish in the fake-time zone, so this
/// prepares the data in real time before the screen is drawn.
Future<void> _prime(WidgetTester tester) => tester.runAsync(() async {
  await AppState.instance.ensureFeed();
  await AppState.instance.loadBrief();
});

void _useServer(MockClient client) {
  AppState.instance = AppState(
    api: ApiService(baseUrl: 'https://api.test', client: client),
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _requests.clear();
    _useServer(_server());
  });

  testWidgets('mobile home shows the top story and the brief', (tester) async {
    await _prime(tester);
    await _pumpAt(tester, const HomePage(), const Size(400, 1600));
    expect(find.text('Story number 0 about chips'), findsOneWidget);
    expect(find.text('Cross-Source Brief'), findsOneWidget);
  });

  for (final size in const [
    Size(1200, 700),
    Size(1440, 900),
    Size(1920, 1080),
  ]) {
    for (var page = 0; page < WebShell.pages.length; page++) {
      testWidgets(
        'web page $page @ ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          AppState.instance.goTo(page);
          await _prime(tester);
          await _pumpAt(tester, const WebShell(), size);
          expect(find.text(WebShell.pages[page].label), findsWidgets);
        },
      );
    }
  }

  testWidgets('home renders live data and the cross-source brief', (
    tester,
  ) async {
    await _prime(tester);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));
    expect(find.text('Story number 0 about chips'), findsOneWidget);
    expect(find.textContaining('Shared Consensus'), findsOneWidget);
  });

  testWidgets('login screen signs the user in', (tester) async {
    await _pumpAt(tester, const WebGate(), const Size(1440, 900));
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'can_test');
    await tester.enterText(find.byType(TextField).at(1), _password);
    await tester.tap(find.text('Sign in'));
    await _settle(tester);
    expect(AppState.instance.user?.username, 'can_test');
    final signIn = _requests.singleWhere(
      (r) => r.url.path == '/api/auth/login',
    );
    expect(jsonDecode(signIn.body), {
      'username': 'can_test',
      'password': _password,
    });
    expect(find.text('WOF Feed'), findsWidgets);
  });

  testWidgets('WAI answers a question about a story', (tester) async {
    final state = AppState.instance;
    await _prime(tester);
    state.askAbout(state.feed.first);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    await tester.runAsync(() => state.send('What is it about?'));
    await _settle(tester);
    // Shown in the bubble and in the chat list preview. Without a server
    // user WAI opens the chat with a fixed opening (+ reply: two WAI messages).
    expect(find.text('It is about faster chips.'), findsWidgets);
    expect(
      find.text("I've read this story. What would you like to know?"),
      findsOneWidget,
    );
    expect(find.text('Helpful'), findsNWidgets(2));
  });

  testWidgets('WAI tab: areas in three sizes; WAI opens the area chat', (
    tester,
  ) async {
    final state = AppState.instance;
    await tester.runAsync(() => state.login('can_test', _password));
    state.goTo(AppState.navChat);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    expect(find.text('What do you want to talk about?'), findsOneWidget);
    expect(find.text('YOUR AREAS'), findsOneWidget);
    expect(find.text('YOUR TOPICS'), findsOneWidget);
    expect(find.text('MORE AREAS'), findsOneWidget);
    Size box(String label) => tester.getSize(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    // The user's area > the user's subtopic > other areas / subtopics.
    final mine = box('Artificial Intelligence');
    final myTopic = box('LLM Agents');
    expect(mine.height, greaterThan(myTopic.height));
    expect(myTopic.height, greaterThan(box('NVIDIA').height));
    expect(box('NVIDIA').height, box('Gaming & Handhelds').height);

    await tester.tap(find.text('Artificial Intelligence'));
    await _settle(tester);
    final open = _requests.singleWhere((r) => r.url.path == '/api/wai/open');
    expect(jsonDecode(open.body), {
      'user_id': 'u1',
      'mode': 'area',
      'area': 'AI',
    });
    // WAI opens the chat; the stories it read are numbered on the right.
    expect(
      find.textContaining('summarize the most striking aspects'),
      findsWidgets,
    );
    expect(find.text('WHAT WAI READ'), findsOneWidget);
    expect(find.text('Summarize the most striking'), findsOneWidget);

    await tester.runAsync(() => state.send('Yes please'));
    await _settle(tester);
    expect(find.textContaining('keeps rising [1].'), findsWidgets);
    final chat = _requests.singleWhere((r) => r.url.path == '/api/wai/chat');
    final body = jsonDecode(chat.body) as Map<String, dynamic>;
    expect(body['source_ids'], ['id-3', 'id-4']);
    expect(body['question'], 'Yes please');
    // The opening is in the history so "Yes" is read against WAI's opening question.
    expect((body['history'] as List).single['role'], 'assistant');
  });

  testWidgets('Latest developments card opens a WAI chat about it', (
    tester,
  ) async {
    final state = AppState.instance;
    await tester.runAsync(() async {
      await state.login('can_test', _password);
      await state.ensureFeed();
      await state.loadBrief();
    });
    state.goTo(AppState.navHome);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    await tester.tap(find.text('Ask WAI about this'));
    await _settle(tester);
    expect(state.navIndex, AppState.navChat);
    expect(state.activeThread?.mode, WaiMode.latest);
    final open = _requests.singleWhere((r) => r.url.path == '/api/wai/open');
    expect((jsonDecode(open.body) as Map)['mode'], 'latest');
    expect(
      find.textContaining('summarize the most striking aspects'),
      findsWidgets,
    );

    // A chat opened from a story is separate: WAI reads the story's text.
    state.askAbout(state.feed.first);
    await _settle(tester);
    final story = _requests.lastWhere((r) => r.url.path == '/api/wai/open');
    expect(jsonDecode(story.body), {
      'user_id': 'u1',
      'mode': 'story',
      'article_id': state.feed.first.id,
    });
    expect(state.threads.keys, ['latest', 'story:${state.feed.first.id}']);
    expect(
      find.text('This story is about faster chips. Want the key points?'),
      findsWidgets,
    );
  });

  testWidgets('empty WAI answer shows an English error with Retry', (
    tester,
  ) async {
    _useServer(_server(chatReply: ''));
    final state = AppState.instance;
    await _prime(tester);
    state.askAbout(state.feed.first);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    await tester.runAsync(() => state.send('What is it about?'));
    await _settle(tester);
    expect(find.text('Something went wrong. Please try again.'), findsWidgets);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('onboarding: pick → taste check → your feed is ready', (
    tester,
  ) async {
    _useServer(_server(onboarded: false));
    await _pumpAt(tester, const WebGate(), const Size(1440, 900));
    await tester.tap(find.text('New here? Create an account'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'new_reader');
    await tester.enterText(find.byType(TextField).at(1), _password);
    await tester.tap(find.text('Create account'));
    await _settle(tester);
    expect(
      _requests.where((r) => r.url.path == '/api/auth/register'),
      hasLength(1),
    );
    final state = AppState.instance;

    Future<void> tap(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.tap(find.text(text));
      await _settle(tester);
    }

    // 1a. Categories (from /api/taxonomy).
    expect(state.onboardingStep, OnboardingStep.pick);
    expect(find.text('What do you want to read about?'), findsOneWidget);
    expect(find.text('Pick at least one category to continue.'), findsOne);
    await tap('Artificial Intelligence');
    await tap('Next');

    // 1b. Topics and "+" follows.
    expect(find.text('Narrow it down'), findsOneWidget);
    await tap('LLM Agents');

    // "+" follow: something the user types, together with its category.
    expect(find.text('Follow something specific'), findsOneWidget);
    final followField = find.byType(TextField).first;
    await tester.enterText(followField, 'www.revolut.com');
    await tap('Add');
    expect(find.text('Type a name, not a link.'), findsOneWidget);
    await tester.enterText(followField, '  Revolut ');
    await tap('Add');
    expect(find.text('Revolut'), findsOneWidget);
    expect(find.textContaining('following Revolut'), findsOneWidget);

    await tap('Next');

    // 1c. The optional "why" sentence; an example chip fills the field.
    expect(find.text('What should your feed help you with?'), findsOneWidget);
    await tap('I invest');
    expect(find.widgetWithText(TextField, 'I invest'), findsOneWidget);
    await tap('Continue');

    final put = _requests.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/users/u1/preferences');
    expect(jsonDecode(put.body), {
      'preferred_macro_tags': ['AI'],
      'preferred_micro_tags': ['llm_agents'],
      'interest_context': 'I invest',
    });
    // The follow is sent after the preferences are saved.
    final follow = _requests.singleWhere(
      (r) => r.method == 'POST' && r.url.path == '/api/users/u1/follows',
    );
    expect(_requests.indexOf(follow), greaterThan(_requests.indexOf(put)));
    expect(jsonDecode(follow.body), {'name': 'Revolut', 'macro': 'AI'});
    expect(state.follows.map((f) => f.name), ['Revolut']);

    // 2. Taste check: the steps go on even though the server counts onboarding as done.
    expect(state.needsOnboarding, isFalse);
    expect(state.onboardingStep, OnboardingStep.taste);
    expect(find.text('Would you read these?'), findsOneWidget);
    expect(find.text('1 / 6'), findsOneWidget);
    await tap("I'd read this");
    await tap("I'd read this");
    await tap('Not for me');
    await tap('Skip');

    final opinions = [
      for (final r in _requests)
        if (r.url.path.endsWith('/interactions'))
          '${r.url.pathSegments[2]}:'
              '${(jsonDecode(r.body) as Map)['interaction_type']}',
    ];
    expect(opinions, ['id-0:like', 'id-1:like', 'id-2:dislike']);

    // 3. Your feed is ready: the feed ranked with the updated profile.
    expect(state.onboardingStep, OnboardingStep.reveal);
    expect(find.textContaining('Here is your Feed'), findsOneWidget);
    expect(find.text('Your 60-second brief'), findsOneWidget);
    // Stories seen in the deck are not shown again; the disliked one left the feed.
    expect(state.revealPicks.map((a) => a.id), ['id-3', 'id-4', 'id-5']);
    // Topics learned from likes show up as reasons.
    expect(find.textContaining('Because you follow'), findsWidgets);
    // The reason for a story naming the followed thing is the follow itself.
    expect(find.text('Because you follow Revolut'), findsOneWidget);
    // A chosen topic with no stories in the feed: the server fetches and stores
    // it; no live web search (which stores nothing and spends credits).
    expect(find.textContaining('Collecting fresh stories on'), findsOneWidget);
    expect(
      _requests.any((r) => r.url.queryParameters['live_web'] == 'true'),
      isFalse,
    );

    await tap('Open my Feed');
    expect(state.onboardingStep, isNull);
    expect(state.navIndex, AppState.navFeed);
    expect(state.feed.first.id, 'id-3');
    expect(find.text('WOF Feed'), findsWidgets);

    // Home: the "Latest developments" card was written when onboarding ended;
    // next to it the own summaries of the stories it was written from (Daily
    // Brief). The home page no longer asks for the Tavily daily brief.
    state.goTo(AppState.navHome);
    await _settle(tester);
    expect(find.text('LATEST DEVELOPMENTS'), findsOneWidget);
    expect(
      find.text('Chipmakers race ahead as AI demand grows'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Demand for AI chips keeps rising'),
      findsOneWidget,
    );
    expect(find.text('Daily Brief'), findsOneWidget);
    expect(find.text('2 stories'), findsOneWidget);
    expect(
      _requests.where((r) => r.url.path.endsWith('/latest-developments')),
      hasLength(1),
    );
    expect(
      _requests.any((r) => r.url.path == '/api/intelligence/daily-digest'),
      isFalse,
    );
    expect(find.text('Picked for you'), findsOneWidget);
  });

  testWidgets('taste check is skipped when there are too few stories', (
    tester,
  ) async {
    _useServer(
      MockClient((req) async {
        final body = switch (req.url.path) {
          '/api/auth/login' => {
            'user': {
              'id': 'u1',
              'username': 'x',
              'onboarding_completed': false,
            },
            'token': 'token-1',
          },
          '/api/users/u1/preferences' => {
            'id': 'u1',
            'username': 'x',
            'onboarding_completed': true,
            'preferred_macro_tags': ['AI'],
          },
          '/api/feed/personalized' => {
            'is_fallback': false,
            'articles': [_article(0), _article(1)],
          },
          _ => <String, Object>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    await tester.runAsync(() async {
      await AppState.instance.login('x', _password);
      await AppState.instance.submitOnboardingPicks(
        macroTags: ['AI'],
        microTags: const [],
      );
    });
    // Two stories cannot calibrate; straight to the reveal screen.
    expect(AppState.instance.onboardingStep, OnboardingStep.reveal);
    expect(AppState.instance.revealPicks, hasLength(2));
  });

  testWidgets('swiping right sends a like and shows the match score', (
    tester,
  ) async {
    final state = AppState.instance;
    await tester.runAsync(() async {
      await state.login('can_test', _password);
      await state.ensureFeed();
    });
    state.goTo(AppState.navFeed);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    expect(state.feedIsPersonal, isTrue);
    expect(find.text('90% match'), findsOneWidget);
    expect(find.text('Personalized for you'.toUpperCase()), findsOneWidget);

    await tester.runAsync(() async {
      state.react(state.feed.first, like: true);
      // Wait for the queued request to finish.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final like = _requests.singleWhere(
      (r) => r.url.path == '/api/articles/id-0/interactions',
    );
    expect(jsonDecode(like.body), {
      'user_id': 'u1',
      'interaction_type': 'like',
    });
    expect(state.isLiked('id-0'), isTrue);

    // The server added the liked story's category to the preferences; the
    // app shows the updated list.
    expect(state.interests, ['AI', 'Tech']);
    await tester.pump();
    expect(find.text('Tech'), findsWidgets);
  });

  testWidgets('swiping left sends a dislike and the story leaves the feed', (
    tester,
  ) async {
    final state = AppState.instance;
    await tester.runAsync(() async {
      await state.login('can_test', _password);
      await state.ensureFeed();
    });
    state.goTo(AppState.navFeed);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    await tester.runAsync(() async {
      // Like first, then swipe the same story left.
      state.react(state.feed.first, like: true);
      state.rereadFeed();
      state.react(state.feed.first, like: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final sent = [
      for (final r in _requests)
        if (r.url.path == '/api/articles/id-0/interactions')
          (jsonDecode(r.body) as Map<String, dynamic>)['interaction_type'],
    ];
    expect(sent, ['like', 'dislike']);
    expect(state.isLiked('id-0'), isFalse);
    expect(state.sessionDislikes, 1);

    // If the same card comes up again via "Show them again", no request is resent.
    await tester.runAsync(() async {
      state.rereadFeed();
      state.react(state.feed.first, like: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(
      _requests.where((r) => r.url.path == '/api/articles/id-0/interactions'),
      hasLength(2),
    );

    // The refreshed personal feed has no disliked story.
    await tester.runAsync(state.refreshFeed);
    expect(state.feed.map((a) => a.id), isNot(contains('id-0')));
  });

  testWidgets('category tabs show unread counts and filter the deck', (
    tester,
  ) async {
    Map<String, Object?> story(int i, String macro) => {
      ..._article(i),
      'macro_tag': macro,
      'macro_tags': [macro],
    };
    _useServer(
      MockClient((req) async {
        final body = switch (req.url.path) {
          '/api/auth/login' => {
            'user': {
              'id': 'u1',
              'username': 'x',
              'onboarding_completed': true,
              'preferred_macro_tags': ['Tech', 'Finance'],
            },
            'token': 'token-1',
          },
          '/api/feed/personalized' => {
            'is_fallback': false,
            'articles': req.url.queryParameters['page'] == '1'
                ? [
                    story(0, 'Tech'),
                    story(1, 'Finance'),
                    story(2, 'Finance'),
                    story(3, 'Tech'),
                  ]
                : [],
          },
          _ => <String, Object>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final state = AppState.instance;
    await tester.runAsync(() async {
      await state.login('x', _password);
      await state.loadWholeFeed();
    });
    expect(state.unreadCount(null), 4);
    expect(state.unreadCount('Finance'), 2);

    state.openFeed('Finance');
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));
    expect(state.deck.map((a) => a.id), ['id-1', 'id-2']);
    expect(find.text('2 unread of 2'), findsOneWidget);

    await tester.runAsync(() async {
      state.react(state.currentFeedArticle!, like: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(state.deck.map((a) => a.id), ['id-2']);
    expect(find.text('1 unread of 2'), findsOneWidget);
    // A read story counts as read in every tab.
    expect(state.unreadCount(null), 3);

    // A story whose details were opened counts as read but stays in the deck until swiped.
    state.openFromDeck(state.currentFeedArticle!);
    expect(state.unreadCount('Finance'), 0);
    expect(state.deck.map((a) => a.id), ['id-2']);

    // "Show them again" only brings back the open tab's stories.
    state.rereadFeed();
    expect(state.unreadCount('Finance'), 2);
    expect(state.unreadCount('Tech'), 2);
  });

  testWidgets('profile shows server interests and opens the editor', (
    tester,
  ) async {
    final state = AppState.instance;
    await tester.runAsync(() => state.login('can_test', _password));
    state.goTo(AppState.navProfile);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));

    expect(find.text('AI'), findsWidgets);
    expect(find.text('LLM Agents'), findsWidgets);
    expect(
      find.text('Your Feed helps you: “I build products”'),
      findsOneWidget,
    );
    await tester.tap(find.text('Interests'));
    await _settle(tester);
    expect(find.text('Edit interests'), findsOneWidget);
    expect(find.textContaining('will be reset'), findsOneWidget);
    // The saved sentence fills the editor; if deleted, '' is sent.
    expect(find.widgetWithText(TextField, 'I build products'), findsOneWidget);
  });

  test('signed-in requests carry the bearer token', () async {
    final state = AppState.instance;
    await state.login('can_test', _password);
    await state.ensureFeed();
    final feed = _requests.lastWhere(
      (r) => r.url.path == '/api/feed/personalized',
    );
    expect(feed.headers['Authorization'], 'Bearer token-1');
    final signIn = _requests.singleWhere(
      (r) => r.url.path == '/api/auth/login',
    );
    expect(signIn.headers.containsKey('Authorization'), isFalse);
  });

  test('an expired session signs the user out', () async {
    var expired = false;
    _useServer(
      MockClient((req) async {
        if (req.url.path == '/api/auth/login') {
          return http.Response(
            jsonEncode({
              'user': {
                'id': 'u1',
                'username': 'x',
                'onboarding_completed': true,
              },
              'token': 'token-1',
            }),
            200,
          );
        }
        if (expired) {
          return http.Response(jsonEncode({'detail': 'Session expired.'}), 401);
        }
        return http.Response(jsonEncode(<String, Object>{}), 200);
      }),
    );
    final state = AppState.instance;
    await state.login('x', _password);
    expect(state.user, isNotNull);
    expired = true;
    await state.ensureFeed();
    expect(state.user, isNull);
    expect(state.sessionError?.userMessage, contains('session expired'));
  });

  test('signing out revokes the token on the server', () async {
    final state = AppState.instance;
    await state.login('can_test', _password);
    await state.logout();
    final revoke = _requests.singleWhere(
      (r) => r.url.path == '/api/auth/logout',
    );
    expect(revoke.headers['Authorization'], 'Bearer token-1');
    expect(state.user, isNull);
    expect(state.api.authToken, isNull);
  });

  testWidgets('wrong password shows the server message', (tester) async {
    _useServer(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'Wrong username or password.'}),
          401,
        ),
      ),
    );
    await _pumpAt(tester, const WebGate(), const Size(1440, 900));
    await tester.enterText(find.byType(TextField).at(0), 'can_test');
    await tester.enterText(find.byType(TextField).at(1), 'nope-nope');
    await tester.tap(find.text('Sign in'));
    await _settle(tester);
    expect(AppState.instance.user, isNull);
    expect(find.text('Wrong username or password.'), findsOneWidget);
  });

  testWidgets('tunnel down shows Server unavailable', (tester) async {
    _useServer(
      MockClient((_) async => http.Response('503 - Tunnel Unavailable', 503)),
    );
    AppState.instance.goTo(AppState.navFeed);
    await _pumpAt(tester, const WebShell(), const Size(1440, 900));
    expect(find.textContaining('Server unavailable'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
