// T2.2: the bundled snapshot parses with the app's own models, and every
// story a card points to can be opened offline.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:weownfeed/models/api_models.dart';
import 'package:weownfeed/offline/snapshot.dart';

void main() {
  final json =
      jsonDecode(File(OfflineSnapshot.assetPath).readAsStringSync())
          as Map<String, dynamic>;
  final snap = OfflineSnapshot.fromJson(json);
  final exported = snap.generatedAt != null;

  test('snapshot is the placeholder or a full export', () {
    if (!exported) return;
    expect(snap.taxonomy, isNotEmpty);
    expect(snap.articles.length, greaterThan(100));
    expect(snap.profiles, isNotEmpty);
  });

  test('every part parses with the app models', () {
    snap.taxonomy.forEach(TaxonomyCategory.fromJson);
    for (final a in snap.articles.values) {
      final article = Article.fromJson(a);
      expect(article.tldr, isNotEmpty, reason: article.id);
      final fc = a['fact_check_cache'];
      if (fc != null) {
        FactCheckResult.fromJson(fc as Map<String, dynamic>);
      }
    }
    snap.research.values.forEach(ArticleResearch.fromJson);
    for (final list in snap.comments.values) {
      list.forEach(ArticleComment.fromJson);
    }
    snap.digests.values.forEach(DailyDigest.fromJson);
    for (final p in snap.profiles) {
      expect(p.macros, isNotEmpty, reason: p.username);
      LatestDevelopments.fromJson(p.latest);
    }
    snap.tavilyCalls.forEach(TavilyCall.fromJson);
  });

  test('stories on cards are in the snapshot', () {
    final missing = <String>{
      for (final d in snap.digests.values)
        for (final a in DailyDigest.fromJson(d).articles)
          if (!snap.articles.containsKey(a.id)) a.id,
      for (final p in snap.profiles)
        for (final a in LatestDevelopments.fromJson(p.latest).articles)
          if (!snap.articles.containsKey(a.id)) a.id,
    };
    expect(missing, isEmpty);
  });
}
