// Calls every endpoint of a live server in turn.
//
//   dart run bin/test_api.dart                       # read-only + AI
//   dart run bin/test_api.dart --user=can_k --password=... --write  # also posts a comment
//   dart run -DAPI_BASE_URL=https://xyz.loca.lt bin/test_api.dart
//
// Without --write nothing permanent is written to the server. Steps that need
// sign-in need --user and --password of an existing account.
// ignore_for_file: avoid_print
import 'package:weownfeed/models/api_models.dart';
import 'package:weownfeed/services/api_service.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  final username = arg('user') ?? 'can_test';
  final password = arg('password') ?? '';
  final write = args.contains('--write');
  final api = ApiService(logger: print);
  var failures = 0;

  Future<T?> step<T>(String title, Future<T> Function() run) async {
    print('\n━━━ $title');
    try {
      return await run();
    } on ApiException catch (e) {
      failures++;
      print('❌ $e\n   UI message: ${e.userMessage}');
      return null;
    }
  }

  print('Server: ${api.baseUrl}');

  final articles = await step(
    'GET /api/articles?page=1&page_size=20',
    () async {
      final list = await api.getArticles();
      for (final a in list) {
        print('  • [${a.macroTags.join(', ')}] ${a.title} — ${a.source}');
      }
      return list;
    },
  );
  if (articles == null || articles.isEmpty) {
    print('\nNo articles; stopping.');
    api.dispose();
    return;
  }
  final first = articles.first;

  await step('GET /api/articles?page=2&page_size=5', () async {
    final p = await api.getArticlePage(page: 2, pageSize: 5);
    print('  ${p.items.length} visible articles, hasMore: ${p.hasMore}');
  });

  await step('GET /api/articles?macro=Hardware', () async {
    final list = await api.getArticles(macro: 'Hardware');
    print('  ${list.length} Hardware articles');
  });

  await step('GET /api/articles/{id}', () async {
    final a = await api.getArticle(first.id);
    print('  ${a.title}\n  clean_text: ${a.cleanText?.length ?? 0} chars');
  });

  await step('GET /api/search?q=battery (flat)', () async {
    final hits = await api.searchArticles('battery');
    for (final h in hits) {
      print(
        '  • ${h.isDirect ? 'direct ' : 'explore'} ${h.relevanceScore} ${h.article.title}',
      );
    }
  });

  await step('GET /api/search?q=gpu inference&grouped=true', () async {
    final r = await api.searchGrouped('gpu inference');
    print('  direct: ${r.direct.length}, explore: ${r.explore.length}');
  });

  await step('GET /api/articles/{id}/comments', () async {
    final list = await api.getComments(first.id);
    print('  ${list.length} comments');
  });

  final user = await step('POST /api/auth/login ($username)', () async {
    final session = await api.login(username, password);
    api.authToken = session.token;
    print('  ${session.user.username} → ${session.user.id}');
    return session.user;
  });

  await step('POST /api/articles/{id}/chat (stream)', () async {
    final buffer = StringBuffer();
    await for (final chunk in api.chatStream(
      first.id,
      question: 'Explain this story simply.',
      history: const [ChatTurn.user('Summarize it.')],
    )) {
      buffer.write(chunk);
    }
    print('  $buffer');
  });

  if (articles.length >= 2) {
    await step('POST /api/intelligence/synthesize', () async {
      final md = await api.synthesizeArticles([articles[0].id, articles[1].id]);
      print('  ${md.length} chars\n  ${md.split('\n').take(4).join('\n  ')}');
    });
  }

  if (write && user != null) {
    await step('POST /api/articles/{id}/comments', () async {
      final c = await api.postComment(
        first.id,
        user: user,
        commentText: 'API test comment from WeOwnFeed',
      );
      print('  comment ${c.id} by ${c.username}');
    });
  } else {
    print('\n(skipped POST comments; pass --write to send a real comment)');
  }

  api.dispose();
  print(
    '\n${failures == 0 ? '✅ All steps passed' : '❌ $failures step(s) failed'}',
  );
}
