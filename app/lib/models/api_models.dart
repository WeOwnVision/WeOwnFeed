/// Models of the JSON the WeOwnFeed API returns.
///
/// Field names match the responses in the server's `/openapi.json` schema
/// one to one. The server may send some fields as `null`, so lists fall back
/// to empty lists and texts to `null`.
library;

List<String> _stringList(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Items of `/api/articles`, `/api/articles/{id}` and `/api/search`.
class Article {
  const Article({
    required this.id,
    required this.source,
    required this.title,
    required this.url,
    this.author,
    this.publishedAt,
    this.macroTag,
    this.macroTags = const [],
    this.microTags = const [],
    this.tldr,
    this.cleanText,
    this.personalScore,
    this.isLiked,
    this.matchedFollows = const [],
    this.matchedSites = const [],
    this.imageUrl,
    this.imageStatus,
    this.factCheckCache,
  });

  factory Article.fromJson(Map<String, dynamic> json) {
    final macroTag = json['macro_tag'] as String?;
    final macroTags = _stringList(json['macro_tags']);
    return Article(
      id: json['id'] as String,
      source:
          (json['source'] as String?) ?? (json['source_feed'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      url: (json['url'] as String?) ?? (json['link'] as String?) ?? '',
      author: json['author'] as String?,
      publishedAt: _date(json['published_at']),
      macroTag: macroTag,
      macroTags: macroTags.isEmpty && macroTag != null ? [macroTag] : macroTags,
      microTags: _stringList(json['micro_tags']),
      tldr: json['tldr'] as String?,
      cleanText: json['clean_text'] as String?,
      personalScore: (json['personal_score'] as num?)?.toInt(),
      isLiked: json['is_liked'] as bool?,
      matchedFollows: _stringList(json['matched_follows']),
      matchedSites: _stringList(json['matched_sites']),
      imageUrl: json['image_url'] as String?,
      imageStatus: json['image_status'] as String?,
      factCheckCache: json['fact_check_cache'] is Map<String, dynamic>
          ? FactCheckResult.fromJson(
              json['fact_check_cache'] as Map<String, dynamic>,
            )
          : (json['fact_check_cache'] is Map
                ? FactCheckResult.fromJson(
                    Map<String, dynamic>.from(json['fact_check_cache'] as Map),
                  )
                : null),
    );
  }

  final String id;
  final String source;
  final String title;
  final String url;
  final String? author;
  final DateTime? publishedAt;

  /// Birincil kategori (Tech, AI & Compute, Systems & Cloud, etc.).
  final String? macroTag;
  final List<String> macroTags;
  final List<String> microTags;
  final String? tldr;

  /// The story's full text; only in the `getArticle` response.
  final String? cleanText;

  /// Match score in the personal feed (0-100).
  final int? personalScore;

  /// Whether the user liked this story on the server.
  final bool? isLiked;

  /// Things the user follows with "+" that the story names.
  final List<String> matchedFollows;

  /// Followed sites the story came from (e.g. "anthropic.com").
  final List<String> matchedSites;

  /// Image link and status from the 4-stage image resolver.
  final String? imageUrl;
  final String? imageStatus;

  /// Cache of the Tavily & Nemotron deep verification / fact check.
  final FactCheckResult? factCheckCache;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'url': url,
    if (author != null) 'author': author,
    if (publishedAt != null) 'published_at': publishedAt!.toIso8601String(),
    if (macroTag != null) 'macro_tag': macroTag,
    'macro_tags': macroTags,
    'micro_tags': microTags,
    if (tldr != null) 'tldr': tldr,
    if (cleanText != null) 'clean_text': cleanText,
    if (personalScore != null) 'personal_score': personalScore,
    if (isLiked != null) 'is_liked': isLiked,
    if (matchedFollows.isNotEmpty) 'matched_follows': matchedFollows,
    if (matchedSites.isNotEmpty) 'matched_sites': matchedSites,
    if (imageUrl != null) 'image_url': imageUrl,
    if (imageStatus != null) 'image_status': imageStatus,
  };
}

class ClaimItem {
  const ClaimItem({
    required this.claim,
    required this.status,
    required this.evidenceSummary,
    this.sourceUrl,
  });

  factory ClaimItem.fromJson(Map<String, dynamic> json) {
    return ClaimItem(
      claim: (json['claim'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'unverified',
      evidenceSummary: (json['evidence_summary'] as String?) ?? '',
      sourceUrl: json['source_url'] as String?,
    );
  }

  final String claim;
  final String status;
  final String evidenceSummary;
  final String? sourceUrl;
}

class FactCheckResult {
  const FactCheckResult({
    required this.executiveSynthesis,
    required this.factCheckVerdict,
    this.claimMatrix = const [],
    this.biasAndNuance = '',
    this.isCached = false,
    this.limitedSource = false,
    this.modelUsed = '',
    this.sourcesConsulted = const [],
  });

  factory FactCheckResult.fromJson(Map<String, dynamic> json) {
    final claims = json['claim_matrix'];
    final sources = json['sources_consulted'];
    return FactCheckResult(
      executiveSynthesis: (json['executive_synthesis'] as String?) ?? '',
      factCheckVerdict: (json['fact_check_verdict'] as String?) ?? 'Unverified',
      claimMatrix: claims is List
          ? claims
                .whereType<Map<String, dynamic>>()
                .map(ClaimItem.fromJson)
                .toList()
          : const [],
      biasAndNuance: (json['bias_and_nuance'] as String?) ?? '',
      isCached: json['is_cached'] == true,
      limitedSource: json['limited_source'] == true,
      modelUsed: (json['model_used'] as String?) ?? '',
      sourcesConsulted: sources is List
          ? sources
                .whereType<Map<String, dynamic>>()
                .map(
                  (s) => Map<String, String>.from(
                    s.map(
                      (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                    ),
                  ),
                )
                .toList()
          : const [],
    );
  }

  final String executiveSynthesis;
  final String factCheckVerdict;
  final List<ClaimItem> claimMatrix;
  final String biasAndNuance;
  final bool isCached;
  final bool limitedSource;
  final String modelUsed;
  final List<Map<String, String>> sourcesConsulted;
}

class DeepInspectEvent {
  const DeepInspectEvent({required this.event, required this.data});
  final String event;
  final String data;
}

/// Search result: a story + the server's match details.
class SearchHit {
  const SearchHit({
    required this.article,
    required this.isDirect,
    this.relevanceScore,
    this.possibility,
    this.exploreAngle,
  });

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
    article: Article.fromJson(json),
    isDirect: json['match_tier'] != 'explore',
    relevanceScore: (json['relevance_score'] as num?)?.toInt(),
    possibility: json['possibility'] as String?,
    exploreAngle: json['explore_angle'] as String?,
  );

  final Article article;

  /// `match_tier == "direct"`; otherwise "you might also want to explore".
  final bool isDirect;

  /// Relevance score from 0 to 99.
  final int? relevanceScore;

  /// "Direct Focus" / "Adjacent Horizon".
  final String? possibility;

  /// Angle the server generates for explore results (e.g. "Compute & ...").
  final String? exploreAngle;
}

/// Response of `/api/search?grouped=true`.
class GroupedSearch {
  const GroupedSearch({
    required this.query,
    required this.direct,
    required this.explore,
  });

  factory GroupedSearch.fromJson(Map<String, dynamic> json) {
    List<SearchHit> hits(Object? value) => value is List
        ? value
              .whereType<Map<String, dynamic>>()
              .map(SearchHit.fromJson)
              .toList()
        : const [];
    return GroupedSearch(
      query: (json['query'] as String?) ?? '',
      direct: hits(json['direct']),
      explore: hits(json['explore']),
    );
  }

  static const empty = GroupedSearch(query: '', direct: [], explore: []);

  final String query;
  final List<SearchHit> direct;
  final List<SearchHit> explore;

  bool get isEmpty => direct.isEmpty && explore.isEmpty;
}

/// Item of `/api/articles/{id}/comments`.
class ArticleComment {
  const ArticleComment({
    required this.id,
    required this.comment,
    required this.username,
    this.selectedText,
    this.avatarUrl,
    this.createdAt,
  });

  factory ArticleComment.fromJson(Map<String, dynamic> json) => ArticleComment(
    id: json['id'] as String,
    // The server uses `comment` in GET and `comment_text` in the POST body.
    comment: (json['comment'] ?? json['comment_text'] ?? '') as String,
    username: (json['username'] as String?) ?? '',
    selectedText: json['selected_text'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    createdAt: _date(json['created_at']),
  );

  final String id;
  final String comment;
  final String username;

  /// Text selected from the story that the comment is attached to.
  final String? selectedText;
  final String? avatarUrl;
  final DateTime? createdAt;
}

/// Item of `/api/auth/*` (the `user` field) and `/api/users/{id}/preferences`.
class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    this.avatarUrl,
    this.createdAt,
    this.onboardingCompleted = false,
    this.preferredMacroTags = const [],
    this.preferredMicroTags = const [],
    this.interestContext,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    username: (json['username'] as String?) ?? '',
    avatarUrl: json['avatar_url'] as String?,
    createdAt: _date(json['created_at']),
    onboardingCompleted: json['onboarding_completed'] == true,
    preferredMacroTags: _stringList(json['preferred_macro_tags']),
    preferredMicroTags: _stringList(json['preferred_micro_tags']),
    interestContext: json['interest_context'] as String?,
  );

  final String id;
  final String username;
  final String? avatarUrl;
  final DateTime? createdAt;

  /// Did the user pick interests? If `false` the onboarding screen opens.
  final bool onboardingCompleted;

  /// Chosen main categories (the taxonomy's `macro` values).
  final List<String> preferredMacroTags;

  /// Chosen subtopic tags (the taxonomy's `tag` values).
  final List<String> preferredMicroTags;

  /// The optional onboarding "why" sentence, in the language it was written
  /// (e.g. "I invest"). The server builds the interest vector from its English
  /// version; if `null`, from a standard sentence built from the chosen topics.
  final String? interestContext;

  AppUser copyWith({
    String? avatarUrl,
    bool? onboardingCompleted,
    List<String>? preferredMacroTags,
    List<String>? preferredMicroTags,
  }) => AppUser(
    id: id,
    username: username,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    createdAt: createdAt,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    preferredMacroTags: preferredMacroTags ?? this.preferredMacroTags,
    preferredMicroTags: preferredMicroTags ?? this.preferredMicroTags,
    interestContext: interestContext,
  );
}

/// One subtopic tag in `/api/taxonomy`.
class TaxonomyTag {
  const TaxonomyTag({required this.tag, required this.label});

  factory TaxonomyTag.fromJson(Map<String, dynamic> json) => TaxonomyTag(
    tag: json['tag'] as String,
    label: (json['label'] as String?) ?? json['tag'] as String,
  );

  /// Value sent to the server (e.g. `llm_agents`).
  final String tag;

  /// Name shown in the UI (e.g. "LLM Agents").
  final String label;
}

/// Item of `/api/taxonomy`: a main category and its subtopic tags.
///
/// The list is fixed in the server's code; user picks never change it.
class TaxonomyCategory {
  const TaxonomyCategory({
    required this.macro,
    required this.displayName,
    this.description = '',
    this.microTags = const [],
  });

  factory TaxonomyCategory.fromJson(Map<String, dynamic> json) {
    final macro = json['macro'] as String;
    final tags = json['micro_tags'];
    return TaxonomyCategory(
      macro: macro,
      displayName: (json['display_name'] as String?) ?? macro,
      description: (json['description'] as String?) ?? '',
      microTags: tags is List
          ? tags
                .whereType<Map<String, dynamic>>()
                .map(TaxonomyTag.fromJson)
                .toList()
          : const [],
    );
  }

  /// Value sent to the server (e.g. `AI`).
  final String macro;
  final String displayName;
  final String description;
  final List<TaxonomyTag> microTags;
}

/// A specific thing followed with "+" (company, product, person), e.g. "Revolut".
///
/// On the server one search query runs for everyone following the same thing;
/// stories that name it rank higher in the feed.
class UserFollow {
  const UserFollow({required this.name, required this.macro, this.id});

  factory UserFollow.fromJson(Map<String, dynamic> json) => UserFollow(
    id: json['id'] as String?,
    name: (json['name'] as String?) ?? '',
    macro: (json['macro'] as String?) ?? '',
  );

  /// Record id on the server; `null` if not saved yet.
  final String? id;
  final String name;

  /// Its category (adds context to the query: "Revolut finance").
  final String macro;

  /// Key that ignores case and spacing (same as the server's).
  String get key => name.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();
}

/// Response of `PUT /api/users/{id}/preferences`.
class PreferencesResult {
  const PreferencesResult({required this.user, this.interestSummary});

  final AppUser user;

  /// Sentence the server built from the picks and turned into the interest vector.
  final String? interestSummary;
}

/// Response of `/api/feed/personalized`.
class PersonalizedFeed {
  const PersonalizedFeed({
    required this.articles,
    required this.hasMore,
    this.isFallback = false,
  });

  final List<Article> articles;

  /// If the server returned a full page there may be a next one.
  final bool hasMore;

  /// `true`: the user picked no interests; the feed is date-ordered.
  final bool isFallback;
}

/// Interaction types for `POST /api/articles/{id}/interactions`.
///
/// [like] and [dislike] are mutually exclusive on the server: saving one
/// deletes the other. [dislike] removes the story from the personal feed.
enum InteractionType { like, dislike, bookmark }

/// Response of `POST /api/articles/{id}/interactions`.
class InteractionResult {
  const InteractionResult({
    required this.active,
    this.preferredMacroTags,
    this.preferredMicroTags,
  });

  factory InteractionResult.fromJson(Map<String, dynamic> json) {
    List<String>? tags(Object? v) => v is List ? _stringList(v) : null;
    return InteractionResult(
      active: json['active'] == true,
      preferredMacroTags: tags(json['updated_preferred_macro_tags']),
      preferredMicroTags: tags(json['updated_preferred_micro_tags']),
    );
  }

  /// Is the interaction saved (`false`: the server toggled it off).
  final bool active;

  /// Preferences the server updated after a like / dislike. The liked
  /// story's category and tags are added; `null` if the record was deleted.
  final List<String>? preferredMacroTags;
  final List<String>? preferredMicroTags;
}

/// Response of `/api/intelligence/daily-digest`.
class DailyDigest {
  const DailyDigest({
    required this.macroTag,
    required this.clusterTitle,
    required this.report,
    this.articles = const [],
    this.isCached = false,
  });

  factory DailyDigest.fromJson(Map<String, dynamic> json) {
    final arts = json['articles'];
    return DailyDigest(
      macroTag: (json['macro_tag'] as String?) ?? '',
      clusterTitle: (json['cluster_title'] as String?) ?? '',
      report: (json['synthesis_report'] as String?) ?? '',
      articles: arts is List
          ? arts
                .whereType<Map<String, dynamic>>()
                .where((a) => a['id'] is String)
                .map(Article.fromJson)
                .toList()
          : const [],
      isCached: json['is_cached'] == true,
    );
  }

  /// The brief's category (the user's first pick).
  final String macroTag;
  final String clusterTitle;

  /// Markdown rapor.
  final String report;

  /// Stories compared in the report.
  final List<Article> articles;
  final bool isCached;
}

/// `GET /api/users/{id}/latest-developments`: the home page "Latest
/// developments" card. The server writes a headline and a paragraph from the
/// user's top stories and stores them per user.
class LatestDevelopments {
  const LatestDevelopments({
    required this.headline,
    required this.paragraph,
    this.articles = const [],
    this.refreshing = false,
  });

  factory LatestDevelopments.fromJson(Map<String, dynamic> json) {
    final arts = json['articles'];
    return LatestDevelopments(
      headline: (json['headline'] as String?) ?? '',
      paragraph: (json['paragraph'] as String?) ?? '',
      articles: arts is List
          ? arts
                .whereType<Map<String, dynamic>>()
                .where((a) => a['id'] is String)
                .map(Article.fromJson)
                .toList()
          : const [],
      refreshing: json['refreshing'] == true,
    );
  }

  /// Short headline (the server caps it at 70 characters).
  final String headline;

  /// 3-4 sentence paragraph on the latest developments.
  final String paragraph;

  /// Stories the card was written from, in feed order.
  final List<Article> articles;

  /// The server is refreshing the card in the background; ask again a bit later.
  final bool refreshing;
}

/// `POST /api/wai/open`: a chat opened by WAI. The server reads the scope
/// (story, latest developments or area) and writes the first message itself.
class WaiOpening {
  const WaiOpening({
    required this.title,
    required this.opening,
    this.subtitle = '',
    this.sources = const [],
  });

  factory WaiOpening.fromJson(Map<String, dynamic> json) {
    final arts = json['sources'];
    return WaiOpening(
      title: (json['title'] as String?) ?? '',
      subtitle: (json['subtitle'] as String?) ?? '',
      opening: (json['opening'] as String?) ?? '',
      sources: arts is List
          ? arts
                .whereType<Map<String, dynamic>>()
                .where((a) => a['id'] is String)
                .map(Article.fromJson)
                .toList()
          : const [],
    );
  }

  /// Story title, latest developments title or area name.
  final String title;

  /// E.g. "Your latest developments · 8 stories".
  final String subtitle;

  /// WAI's first message.
  final String opening;

  /// Stories WAI read; [1], [2] in answers refer to this order.
  final List<Article> sources;
}

/// One turn of a WAI chat history.
class ChatTurn {
  const ChatTurn.user(this.content) : role = 'user';
  const ChatTurn.assistant(this.content) : role = 'assistant';

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// A page of `/api/articles`.
class ArticlePage {
  const ArticlePage({required this.items, required this.hasMore});

  final List<Article> items;

  /// If the server returned a full page there may be a next one.
  final bool hasMore;
}

/// Row of `GET /api/tavily/calls`: one Tavily call the server made.
class TavilyCall {
  const TavilyCall({
    required this.id,
    required this.endpoint,
    required this.purpose,
    this.detail,
    this.resultCount = 0,
    this.latencyMs = 0,
    this.credits = 0,
    this.cacheHit = false,
    this.createdAt,
  });

  factory TavilyCall.fromJson(Map<String, dynamic> json) => TavilyCall(
    id: (json['id'] as num).toInt(),
    endpoint: (json['endpoint'] as String?) ?? '',
    purpose: (json['purpose'] as String?) ?? '',
    detail: json['detail'] as String?,
    resultCount: (json['result_count'] as num?)?.toInt() ?? 0,
    latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
    credits: (json['credits_est'] as num?)?.toDouble() ?? 0,
    cacheHit: json['cache_hit'] == true,
    createdAt: _date(json['created_at']),
  );

  final int id;

  /// search, extract, map, crawl or research.
  final String endpoint;

  /// Why the call was made (e.g. demand_ingestion, support, site_follow_map).
  final String purpose;

  /// Query text, site read or research question.
  final String? detail;
  final int resultCount;
  final int latencyMs;
  final double credits;

  /// Served from the cache, so no credits were spent.
  final bool cacheHit;
  final DateTime? createdAt;
}

/// Response of `GET /api/tavily/calls`.
class TavilyCallPage {
  const TavilyCallPage({required this.calls, required this.latestId});

  /// Eskiden yeniye.
  final List<TavilyCall> calls;

  /// Sent as `after_id` in the next request.
  final int latestId;
}

/// One source of a Research report.
class ResearchSource {
  const ResearchSource({required this.title, required this.url});

  final String title;
  final String url;
}

/// `/api/articles/{id}/deep-inspect/research`: Tavily Research for a story.
class ArticleResearch {
  const ArticleResearch({
    required this.status,
    this.report,
    this.sources = const [],
    this.cached = false,
    this.credits,
  });

  factory ArticleResearch.fromJson(Map<String, dynamic> json) =>
      ArticleResearch(
        status: (json['status'] as String?) ?? 'none',
        report: json['report'] as String?,
        sources: [
          for (final s in (json['sources'] as List?) ?? const [])
            if (s is Map && s['url'] is String)
              ResearchSource(
                title: (s['title'] as String?) ?? s['url'] as String,
                url: s['url'] as String,
              ),
        ],
        cached: json['cached'] == true,
        credits: (json['credits'] as num?)?.toDouble(),
      );

  /// none, running, completed or failed.
  final String status;
  final String? report;
  final List<ResearchSource> sources;

  /// Done and saved earlier; no credits spent.
  final bool cached;
  final double? credits;

  bool get isRunning => status == 'running';
  bool get isCompleted => status == 'completed' && (report ?? '').isNotEmpty;
}

/// `/api/users/{id}/sites`: a site the user follows.
class FollowedSite {
  const FollowedSite({
    required this.id,
    required this.url,
    required this.name,
    required this.status,
    this.articleCount = 0,
  });

  factory FollowedSite.fromJson(Map<String, dynamic> json) => FollowedSite(
    id: json['id'] as String,
    url: (json['url'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'pending',
    articleCount: (json['article_count'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String url;

  /// Domain name (e.g. "anthropic.com").
  final String name;

  /// pending, mapping, crawling, ready, no_articles or failed.
  final String status;
  final int articleCount;

  /// The server is still scanning the site (Map, then Crawl).
  bool get isWorking =>
      status == 'pending' || status == 'mapping' || status == 'crawling';
}
