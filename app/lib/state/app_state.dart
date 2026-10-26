import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_models.dart';
import '../offline/backend_client.dart';
import '../services/api_service.dart';
import '../services/local_cache.dart';

/// The single shared UI state: session, stories, WAI chats and the
/// preferences kept on the device (saved stories, likes, settings).
///
/// Tests can swap in a new instance with a fake [ApiService]:
/// `AppState.instance = AppState(api: ...)`.
class AppState extends ChangeNotifier {
  /// Without [api] the app's [BackendClient] is used (live server first,
  /// offline answers when there is none).
  AppState({ApiService? api, BackendClient? backend})
    : backend = backend ?? (api == null ? BackendClient.instance : null),
      api =
          api ??
          ApiService(
            client: backend ?? BackendClient.instance,
            logger: kDebugMode ? debugPrint : null,
          ) {
    // A request rejected for an expired token sends the user back to the
    // sign-in screen.
    this.api.onUnauthorized = () {
      if (user != null) logout(sessionExpired: true);
    };
  }

  static AppState instance = AppState();

  final ApiService api;

  /// `null` when tests pass their own [api].
  final BackendClient? backend;

  /// A live server answers this session. Online-only controls (WAI chat,
  /// Ask, starting a Fact Check or Research, adding sites and "+" follows)
  /// show only then. Tests without a [backend] count as live.
  bool get isLive => backend?.isLive ?? true;

  LocalCache? _cache;

  /// `true` when the current feed is served from local cache (seed or stale).
  bool get isOffline => _offline;
  bool _offline = false;

  // -------------------------------------------------------------------------
  // Gezinme
  // -------------------------------------------------------------------------
  static const navHome = 0;
  static const navFeed = 1;
  static const navChat = 2;
  static const navDiscover = 3;
  static const navResearch = 4;
  static const navSites = 5;
  static const navProfile = 6;

  int navIndex = navHome;

  void goTo(int index) {
    if (navIndex == index) return;
    navIndex = index;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Oturum
  // -------------------------------------------------------------------------
  static const _kUsername = 'username';
  static const _kToken = 'auth_token';
  static const _kSaved = 'saved_ids';
  static const _kLiked = 'liked_ids';
  static const _kRead = 'read_ids';
  static const _kResearched = 'researched_ids';

  /// Prefix of temporary users created while the server is unreachable.
  static const _localPrefix = 'local-';

  SharedPreferences? _prefs;
  bool _initialized = false;

  AppUser? user;

  /// `true` while the app signs in with the saved session at startup.
  bool sessionLoading = true;
  bool loggingIn = false;
  ApiException? sessionError;

  /// Does the user really exist on the server? Personalization endpoints
  /// are never called for `local-…` users created offline (the server
  /// returns 400 for an invalid id).
  bool get hasServerUser => user != null && !user!.id.startsWith(_localPrefix);

  /// Signed in but no interests picked yet: the onboarding screen opens.
  bool get needsOnboarding => hasServerUser && !user!.onboardingCompleted;

  /// Username of the last sign-in on this device, to prefill the form.
  String? get lastUsername => _prefs?.getString(_kUsername);

  /// Loads preferences and silently restores the previous session.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // Live or offline is decided before anything is requested (≤ 4 s).
    await backend?.mode;
    try {
      _prefs = await SharedPreferences.getInstance();
      _cache = LocalCache(_prefs!);
    } catch (_) {
      // Storage unavailable (private tab etc.): keep everything in memory.
    }
    final token = _prefs?.getString(_kToken);
    if (token != null && token.isNotEmpty) {
      api.authToken = token;
      try {
        _signedIn(await api.me());
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.unauthorized) {
          await _forgetSession();
        } else {
          sessionError = e;
        }
      }
    }
    sessionLoading = false;
    notifyListeners();
  }

  /// Signs in (`POST /api/auth/login`); the server creates the account when
  /// the username is new. The response's `onboarding_completed` decides
  /// whether onboarding opens.
  Future<void> login(String username, String password) async {
    loggingIn = true;
    sessionError = null;
    notifyListeners();
    try {
      final session = await api.login(username, password);
      api.authToken = session.token;
      await _prefs?.setString(_kToken, session.token);
      await _prefs?.setString(_kUsername, session.user.username);
      _signedIn(session.user);
    } on ApiException catch (e) {
      sessionError = e;
    } finally {
      loggingIn = false;
      notifyListeners();
    }
  }

  void _signedIn(AppUser signedIn) {
    user = signedIn;
    _loadLibrary();
    // The feed is personal, so never reuse the previous session's.
    _clearFeed();
    _resetOnboarding();
    follows = const [];
    _setSites(const []);
    if (needsOnboarding) onboardingStep = OnboardingStep.pick;
    if (hasServerUser) {
      loadFollows();
      loadSites();
    }
  }

  Future<void> _forgetSession() async {
    api.authToken = null;
    await _prefs?.remove(_kToken);
  }

  /// Signs out. With [sessionExpired] the sign-in screen says why.
  Future<void> logout({bool sessionExpired = false}) async {
    // Starts the revoke request while the token is still set.
    final revoke = sessionExpired ? null : api.logout();
    api.authToken = null;
    // The UI state resets at once; storage cleanup follows below.
    user = null;
    sessionError = sessionExpired
        ? const ApiException(
            ApiErrorKind.unauthorized,
            'Your session expired. Please sign in again.',
          )
        : null;
    navIndex = navHome;
    interestSummary = null;
    follows = const [];
    _setSites(const []);
    siteStories = const SiteStories();
    saved.clear();
    liked.clear();
    read.clear();
    _disliked.clear();
    researched.clear();
    _research.clear();
    _researching.clear();
    _tasks.clear();
    _researchErrors.clear();
    inbox.clear();
    unreadNotifications = 0;
    _clearFeed();
    _resetOnboarding();
    notifyListeners();
    await revoke;
    await _forgetSession();
    await _cache?.clear();
  }

  // -------------------------------------------------------------------------
  // Interests (taxonomy + preferences)
  // -------------------------------------------------------------------------
  /// The server's fixed category list; loaded once per session.
  List<TaxonomyCategory>? taxonomy;
  bool taxonomyLoading = false;
  ApiException? taxonomyError;

  bool savingPreferences = false;
  ApiException? preferencesError;

  /// Sentence the server builds from the picks (source of the interest vector).
  String? interestSummary;

  /// Chosen main categories (from the server).
  List<String> get interests => user?.preferredMacroTags ?? const [];

  /// Chosen subtopic tags (from the server).
  List<String> get interestTags => user?.preferredMicroTags ?? const [];

  /// The onboarding "why" sentence (from the server); `null` if not written.
  String? get interestContext => user?.interestContext;

  /// `GET /api/taxonomy`.
  Future<void> loadTaxonomy() async {
    if (taxonomy != null || taxonomyLoading) return;
    taxonomyLoading = true;
    taxonomyError = null;
    await Future<void>.value();
    notifyListeners();
    try {
      taxonomy = await api.getTaxonomy();
    } on ApiException catch (e) {
      taxonomyError = e;
    } finally {
      taxonomyLoading = false;
      notifyListeners();
    }
  }

  /// Display name of a subtopic tag ("llm_agents" → "LLM Agents").
  String tagLabel(String tag) {
    for (final c in taxonomy ?? const <TaxonomyCategory>[]) {
      for (final t in c.microTags) {
        if (t.tag == tag) return t.label;
      }
    }
    return tag
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  /// `PUT /api/users/{id}/preferences`. On success the feed and the daily
  /// brief reload with the new preferences. `context`: `null` keeps the
  /// sentence on the server, an empty string deletes it.
  Future<bool> savePreferences({
    required List<String> macroTags,
    required List<String> microTags,
    String? context,
  }) async {
    final current = user;
    if (current == null || !hasServerUser || savingPreferences) return false;
    savingPreferences = true;
    preferencesError = null;
    notifyListeners();
    try {
      final result = await api.updatePreferences(
        current.id,
        macroTags: macroTags,
        microTags: microTags,
        interestContext: context,
      );
      user = AppUser(
        id: result.user.id,
        username: result.user.username,
        avatarUrl: result.user.avatarUrl ?? current.avatarUrl,
        createdAt: current.createdAt,
        onboardingCompleted: result.user.onboardingCompleted,
        preferredMacroTags: result.user.preferredMacroTags,
        preferredMicroTags: result.user.preferredMicroTags,
        interestContext: result.user.interestContext,
      );
      interestSummary = result.interestSummary;
      _clearFeed();
      return true;
    } on ApiException catch (e) {
      preferencesError = e;
      return false;
    } finally {
      savingPreferences = false;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // "+" follows (a specific company, product or person)
  // -------------------------------------------------------------------------
  /// Follows on the server (in the order they were added).
  List<UserFollow> follows = const [];

  /// `GET /api/users/{id}/follows`.
  Future<void> loadFollows() async {
    final current = user;
    if (current == null || !hasServerUser) return;
    try {
      final list = await api.getFollows(current.id);
      if (user?.id != current.id) return;
      follows = list;
      notifyListeners();
    } on ApiException {
      // Interests still work if follows cannot be shown.
    }
  }

  // -------------------------------------------------------------------------
  // Followed sites (Tavily Map + Crawl)
  // -------------------------------------------------------------------------
  /// Site follows on the server. Adding and removing are saved at once; the
  /// server scans the site in the background and [FollowedSite.status] updates.
  List<FollowedSite> sites = const [];

  /// Error of the last attempt to add a site (invalid address, limit of 5).
  String? siteError;
  bool addingSite = false;
  Timer? _sitePoll;

  /// Stories from the followed sites (the Sites page).
  SiteStories siteStories = const SiteStories();
  bool siteStoriesLoading = false;

  /// `GET /api/users/{id}/sites/articles`.
  Future<void> loadSiteStories() async {
    final current = user;
    if (current == null || !hasServerUser) return;
    siteStoriesLoading = true;
    notifyListeners();
    try {
      final result = await api.getSiteStories(current.id);
      if (user?.id != current.id) return;
      _remember(result.articles.map((e) => e.$2));
      siteStories = result;
    } on ApiException {
      // The page keeps the last list.
    } finally {
      siteStoriesLoading = false;
      notifyListeners();
    }
  }

  void _setSites(List<FollowedSite> list) {
    final wasWorking = sites.any((s) => s.isWorking);
    sites = list;
    // A scan just finished: its posts are in the database now.
    if (wasWorking && !list.any((s) => s.isWorking)) loadSiteStories();
    // Refresh the status every 3 s while a scan runs; stop when it is done.
    if (list.any((s) => s.isWorking)) {
      _sitePoll ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => loadSites(),
      );
    } else {
      _sitePoll?.cancel();
      _sitePoll = null;
    }
  }

  /// `GET /api/users/{id}/sites`.
  Future<void> loadSites() async {
    final current = user;
    if (current == null || !hasServerUser) return;
    try {
      final list = await api.getSites(current.id);
      if (user?.id != current.id) return;
      _setSites(list);
      notifyListeners();
    } on ApiException {
      // Interests still work if sites cannot be shown.
    }
  }

  /// Follows a site. The address may be typed without "https://".
  Future<bool> addSite(String input) async {
    final current = user;
    if (current == null || !hasServerUser || addingSite) return false;
    var url = input.trim();
    if (url.isEmpty) return false;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    addingSite = true;
    siteError = null;
    notifyListeners();
    try {
      await api.addSite(current.id, url);
      await loadSites();
      return true;
    } on ApiException catch (e) {
      siteError = e.userMessage;
      return false;
    } finally {
      addingSite = false;
      notifyListeners();
    }
  }

  Future<void> removeSite(FollowedSite site) async {
    final current = user;
    if (current == null || !hasServerUser) return;
    _setSites([
      for (final s in sites)
        if (s.id != site.id) s,
    ]);
    siteError = null;
    notifyListeners();
    try {
      await api.removeSite(current.id, site.id);
    } on ApiException {
      // The next load shows the server's state.
    }
    await loadSites();
  }

  /// Saves category/subtopic preferences and the "why" sentence
  /// (`PUT /preferences`) together with the follows. Onboarding and the
  /// Profile editor use the same path.
  Future<bool> saveInterests({
    required List<String> macroTags,
    required List<String> microTags,
    List<UserFollow> follows = const [],
    String? context,
  }) async {
    final ok = await savePreferences(
      macroTags: macroTags,
      microTags: microTags,
      context: context,
    );
    if (!ok) return false;
    await _syncFollows(follows);
    return true;
  }

  /// Adds the missing follows and deletes the removed ones. A follow error
  /// does not undo the saved preferences; the list is reloaded from the server.
  Future<void> _syncFollows(List<UserFollow> desired) async {
    final current = user;
    if (current == null || !hasServerUser) return;
    final wanted = {for (final f in desired) f.key: f};
    final existing = {for (final f in follows) f.key: f};
    for (final f in existing.values) {
      if (!wanted.containsKey(f.key) && f.id != null) {
        try {
          await api.removeFollow(current.id, f.id!);
        } on ApiException {
          // The next load shows the server's state.
        }
      }
    }
    for (final f in wanted.values) {
      if (!existing.containsKey(f.key)) {
        try {
          await api.addFollow(current.id, name: f.name, macro: f.macro);
        } on ApiException {
          // Invalid or over the limit: the server refuses it and the reload drops it.
        }
      }
    }
    await loadFollows();
  }

  /// `GET /api/users/{id}/preferences`: fetches the current preferences when
  /// the profile opens. On error the values at hand stay.
  Future<void> refreshPreferences() async {
    final current = user;
    if (current == null || !hasServerUser) return;
    try {
      final fresh = await api.getPreferences(current.id);
      if (user?.id != current.id) return;
      user = AppUser(
        id: fresh.id,
        username: fresh.username,
        avatarUrl: fresh.avatarUrl ?? current.avatarUrl,
        createdAt: current.createdAt,
        onboardingCompleted: fresh.onboardingCompleted,
        preferredMacroTags: fresh.preferredMacroTags,
        preferredMicroTags: fresh.preferredMicroTags,
        interestContext: fresh.interestContext,
      );
      notifyListeners();
    } on ApiException {
      // The preferences at hand stay on screen.
    }
  }

  // -------------------------------------------------------------------------
  // Onboarding flow (goal: a personal feed within 60 s)
  // -------------------------------------------------------------------------
  /// The current onboarding step; `null`: onboarding is not open.
  ///
  /// The server sets `onboarding_completed = true` as soon as the picks are
  /// saved; without keeping the steps here the app would jump to the shell
  /// after the first step.
  OnboardingStep? onboardingStep;

  /// Should WebGate show the onboarding screen?
  bool get showOnboarding => onboardingStep != null || needsOnboarding;

  /// Number of cards in the "taste check" deck (~30 s).
  static const tasteSize = 8;

  /// With fewer suitable stories the step is skipped; one card cannot calibrate.
  static const tasteMin = 4;

  List<Article> tasteDeck = const [];
  int tasteIndex = 0;
  int tasteLikes = 0;
  bool tasteLoading = false;

  /// Stories shown in the deck; the reveal screen and the feed move them last.
  final Set<String> _tasted = {};

  Article? get currentTasteCard =>
      tasteIndex < tasteDeck.length ? tasteDeck[tasteIndex] : null;

  /// `true` while the reveal screen loads the feed.
  bool revealLoading = false;

  /// Step 1: saves the picks (`PUT /preferences`) and moves to step 2.
  Future<bool> submitOnboardingPicks({
    required List<String> macroTags,
    required List<String> microTags,
    List<UserFollow> follows = const [],
    String? context,
  }) async {
    final ok = await saveInterests(
      macroTags: macroTags,
      microTags: microTags,
      follows: follows,
      context: context,
    );
    if (!ok) return false;
    onboardingStep = OnboardingStep.taste;
    tasteDeck = const [];
    tasteIndex = 0;
    tasteLikes = 0;
    _tasted.clear();
    notifyListeners();
    await _loadTasteDeck();
    return true;
  }

  /// 8 real stories from the chosen categories, alternating between them.
  /// Taken from the personal feed; the server already filters it to them.
  Future<void> _loadTasteDeck() async {
    final current = user;
    if (current == null) return;
    tasteLoading = true;
    notifyListeners();
    var deck = const <Article>[];
    try {
      final page = await api.getPersonalizedFeed(current.id, pageSize: 40);
      deck = _diversify(page.articles, current.preferredMacroTags, tasteSize);
    } on ApiException {
      // Continue without a deck; the reveal screen is built from the picks.
    }
    if (onboardingStep != OnboardingStep.taste) return;
    _remember(deck);
    tasteDeck = deck;
    tasteLoading = false;
    if (deck.length < tasteMin) {
      await finishTasteCheck();
    } else {
      notifyListeners();
    }
  }

  /// Takes one story from each category in turn (in the user's pick order)
  /// so the deck does not pile up in a single category.
  static List<Article> _diversify(
    List<Article> items,
    List<String> macros,
    int size,
  ) {
    final buckets = <String, List<Article>>{};
    for (final a in items) {
      buckets.putIfAbsent(a.macroTag ?? '', () => []).add(a);
    }
    final order = [
      ...macros.where(buckets.containsKey),
      ...buckets.keys.where((k) => !macros.contains(k)),
    ];
    final out = <Article>[];
    for (var round = 0; out.length < size; round++) {
      var added = false;
      for (final k in order) {
        final bucket = buckets[k]!;
        if (round < bucket.length && out.length < size) {
          out.add(bucket[round]);
          added = true;
        }
      }
      if (!added) break;
    }
    return out;
  }

  /// Step 2: swipe a card right (I'd read this) or left (not for me).
  /// Sends the same signal as a swipe in the feed; the interest vector and
  /// tags update on the server right away.
  void tasteReact(Article article, {required bool like}) {
    if (currentTasteCard?.id != article.id) return;
    if (like) tasteLikes++;
    _tasted.add(article.id);
    _recordOpinion(article.id, like: like);
    tasteIndex++;
    notifyListeners();
    if (tasteIndex >= tasteDeck.length) finishTasteCheck();
  }

  /// Step 2 finished or skipped: waits for the like requests to reach the
  /// server (so the feed ranks with the updated vector), then the reveal.
  Future<void> finishTasteCheck() async {
    if (onboardingStep != OnboardingStep.taste) return;
    onboardingStep = OnboardingStep.reveal;
    revealLoading = true;
    notifyListeners();
    await _interactionsSettled();
    if (onboardingStep != OnboardingStep.reveal) return;
    await refreshFeed();
    if (onboardingStep != OnboardingStep.reveal) return;
    revealLoading = false;
    notifyListeners();
    // Write the home page "Latest developments" card with the updated
    // profile now, so it is ready when the user reaches the home page.
    loadBrief();
  }

  Future<void> _interactionsSettled() async {
    try {
      await Future.wait(_interactionQueue.values.toList());
    } catch (_) {
      // Each is handled on its own; here we only wait for them to finish.
    }
  }

  /// The reveal screen's "for you" stories: those not already seen in the deck.
  List<Article> get revealPicks =>
      feed.where((a) => !_tasted.contains(a.id)).toList();

  /// Chosen subtopics with few stories in the feed yet, and follows with no
  /// stories so far. The server fetches and stores them when interests are
  /// saved; the reveal screen only says they are "being collected" (no live
  /// search that spends credits without storing anything).
  List<String> get collectingTopics {
    int count(bool Function(Article) test) => feed.where(test).length;
    return [
      for (final t in interestTags)
        if (count((a) => a.microTags.contains(t)) < 2) tagLabel(t),
      for (final f in follows)
        if (count((a) => a.matchedFollows.contains(f.name)) == 0) f.name,
    ];
  }

  /// Step 3: onboarding ends and the feed opens. Stories seen in the deck go
  /// to the end of the feed so the first cards are new to the user.
  void completeOnboarding({int openTab = navFeed}) {
    final fresh = feed.where((a) => !_tasted.contains(a.id)).toList();
    final seen = feed.where((a) => _tasted.contains(a.id)).toList();
    feed
      ..clear()
      ..addAll([...fresh, ...seen]);
    onboardingStep = null;
    navIndex = openTab;
    notifyListeners();
  }

  void _resetOnboarding() {
    onboardingStep = null;
    tasteDeck = const [];
    tasteIndex = 0;
    tasteLikes = 0;
    tasteLoading = false;
    _tasted.clear();
    revealLoading = false;
  }

  /// "Why this story": the subtopics the user picked (or that were learned
  /// from likes), otherwise the category. Makes personalization visible.
  List<String> reasonsFor(Article a) {
    final u = user;
    if (u == null || !hasServerUser) return const [];
    // A story from a followed site, or one naming a "+" follow, has the
    // strongest reason.
    if (a.matchedSites.isNotEmpty || a.matchedFollows.isNotEmpty) {
      return [...a.matchedSites, ...a.matchedFollows].take(2).toList();
    }
    final topics = [
      for (final t in a.microTags)
        if (u.preferredMicroTags.contains(t)) tagLabel(t),
    ];
    if (topics.isNotEmpty) return topics.take(3).toList();
    return [
      for (final m in a.macroTags)
        if (u.preferredMacroTags.contains(m)) m,
    ].take(1).toList();
  }

  // -------------------------------------------------------------------------
  // Story cache and details
  // -------------------------------------------------------------------------
  final Map<String, Article> _articles = {};

  /// Stories whose full text is loaded.
  final Map<String, Article> _details = {};

  Article? articleById(String id) => _details[id] ?? _articles[id];

  void _remember(Iterable<Article> items) {
    for (final a in items) {
      _articles[a.id] = a;
    }
  }

  /// Fetches a story's details (full text); loaded once.
  Future<Article> loadDetail(String id) async {
    final cached = _details[id];
    if (cached != null) return cached;
    final article = await api.getArticle(id);
    _details[id] = article;
    _articles[id] = article;
    return article;
  }

  /// Fetches stories missing from the cache (e.g. saved in an earlier session).
  Future<void> ensureArticles(Iterable<String> ids) async {
    final missing = ids.where((id) => !_articles.containsKey(id)).toList();
    if (missing.isEmpty) return;
    await Future.wait(
      missing.map((id) async {
        try {
          await loadDetail(id);
        } on ApiException {
          // Deleted or unreachable story; not shown in the list.
        }
      }),
    );
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Feed (paged)
  // -------------------------------------------------------------------------
  static const pageSize = 20;

  final List<Article> feed = [];
  int _feedPage = 0;
  bool feedHasMore = true;
  bool feedLoading = false;
  ApiException? feedError;

  /// Is the feed personal (`/api/feed/personalized`)?
  bool feedIsPersonal = false;

  /// A personal feed was requested but the user has no preferences; the
  /// server returned a date-ordered feed.
  bool feedIsFallback = false;

  /// A pending load's result is dropped if the feed was cleared meanwhile.
  int _feedGeneration = 0;

  Future<void>? _feedRequest;

  /// Fetches the first page if the feed is not loaded yet; if a load is
  /// running, waits for it.
  Future<void> ensureFeed() {
    if (_feedRequest != null) return _feedRequest!;
    return feed.isEmpty ? loadMoreFeed() : Future.value();
  }

  /// Fetches the next page. Skips pages that come back empty because test
  /// records are hidden. Returns the running request if there is one.
  Future<void> loadMoreFeed() {
    if (_feedRequest != null) return _feedRequest!;
    if (!feedHasMore) return Future.value();
    feedLoading = true;
    feedError = null;
    late final Future<void> request;
    request = _loadMoreFeed().whenComplete(() {
      // The feed was cleared and a new request started meanwhile: leave it.
      if (identical(_feedRequest, request)) _feedRequest = null;
    });
    return _feedRequest = request;
  }

  Future<void> _loadMoreFeed() async {
    final generation = _feedGeneration;
    // May be called from a page's initState; notify after the frame.
    await Future<void>.value();
    notifyListeners();
    try {
      var added = 0;
      while (added == 0 && feedHasMore) {
        final List<Article> items;
        // Personal feed for a signed-in user; the general feed for mobile /
        // offline users.
        final personal = hasServerUser;
        if (personal) {
          final page = await api.getPersonalizedFeed(
            user!.id,
            page: _feedPage + 1,
            pageSize: personalPageSize,
          );
          if (generation != _feedGeneration) return;
          items = page.articles;
          feedHasMore = page.hasMore;
          feedIsFallback = page.isFallback;
          _syncLikes(items);
        } else {
          final page = await api.getArticlePage(
            page: _feedPage + 1,
            pageSize: pageSize,
          );
          if (generation != _feedGeneration) return;
          items = page.items;
          feedHasMore = page.hasMore;
        }
        feedIsPersonal = personal;
        _feedPage++;
        final known = feed.map((a) => a.id).toSet();
        final fresh = items.where((a) => !known.contains(a.id)).toList();
        _remember(fresh);
        feed.addAll(fresh);
        added = fresh.length;
      }
      // Server responded — replace local cache with fresh data.
      _offline = false;
      _cache?.saveArticles(feed);
    } on ApiException catch (e) {
      if (generation != _feedGeneration) return;
      // First page failed and feed is empty → fall back to local cache.
      if (feed.isEmpty) {
        final cached = _cache?.loadArticles() ?? const [];
        if (cached.isNotEmpty) {
          _remember(cached);
          feed.addAll(cached);
          feedHasMore = false;
          _offline = true;
          feedError = null;
        } else {
          feedError = e;
        }
      } else {
        feedError = e;
      }
    } finally {
      if (generation == _feedGeneration) {
        feedLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshFeed() async {
    _clearFeed();
    await loadMoreFeed();
  }

  /// Resets the feed and its brief (sign-in, sign-out, preference change).
  void _clearFeed() {
    _feedGeneration++;
    _feedRequest = null;
    feed.clear();
    _feedPage = 0;
    feedHasMore = true;
    feedLoading = false;
    feedError = null;
    feedIsPersonal = false;
    feedIsFallback = false;
    // After a preference change the open category may no longer be chosen.
    feedCategory = null;
    _deckHold = null;
    sessionLikes = 0;
    sessionDislikes = 0;
    _offline = false;
    _briefGeneration++;
    brief = null;
    briefTitle = null;
    briefLoading = false;
    briefError = null;
    _briefSources = const [];
  }

  /// The personal feed sends the server's like state (`is_liked`) for each
  /// story; the list on the device is updated from it.
  void _syncLikes(Iterable<Article> items) {
    var changed = false;
    for (final a in items) {
      final serverLiked = a.isLiked;
      if (serverLiked == null) continue;
      changed |= serverLiked ? liked.add(a.id) : liked.remove(a.id);
    }
    if (changed) _persistIds(_kLiked, liked);
  }

  /// Unread counts need the whole feed, so the personal feed comes in large
  /// pages (the server returns 400 stories in ~0.07 s).
  static const personalPageSize = 100;

  /// Loads the whole feed in the background for the menu's unread counts.
  Future<void> loadWholeFeed() async {
    await ensureFeed();
    while (hasServerUser && feedHasMore && feedError == null) {
      await loadMoreFeed();
    }
  }

  // -------------------------------------------------------------------------
  // WOF swiping and category feeds
  // -------------------------------------------------------------------------
  int sessionLikes = 0;
  int sessionDislikes = 0;

  /// The category open in WOF Feed; `null` = all categories.
  String? feedCategory;

  /// Read stories: swiped or opened. Kept on the device per user; the
  /// menu's unread counts come from it.
  final Set<String> read = {};

  /// A card opened from the deck counts as read but stays in the deck until
  /// it is swiped; otherwise it would vanish when the dialog closes.
  String? _deckHold;

  /// Opens WOF Feed on [category] (`null` = all categories).
  void openFeed(String? category) {
    if (navIndex == navFeed && feedCategory == category) return;
    feedCategory = category;
    _deckHold = null;
    navIndex = navFeed;
    notifyListeners();
  }

  /// Stories of [category], in personal order.
  List<Article> feedFor(String? category) => category == null
      ? feed
      : [
          for (final a in feed)
            if (a.macroTags.contains(category) || a.macroTag == category) a,
        ];

  int unreadCount(String? category) =>
      feedFor(category).where((a) => !read.contains(a.id)).length;

  /// The open tab's deck: unread stories.
  List<Article> get deck => [
    for (final a in feedFor(feedCategory))
      if (!read.contains(a.id) || a.id == _deckHold) a,
  ];

  Article? get currentFeedArticle => deck.firstOrNull;

  void markRead(String id) {
    if (!read.add(id)) return;
    _persistIds(_kRead, read);
    notifyListeners();
  }

  /// Marks a card opened from the deck as read but keeps it in the deck.
  void openFromDeck(Article article) {
    _deckHold = article.id;
    markRead(article.id);
  }

  /// Stories disliked in this session. The server removes them from the feed;
  /// if the same card comes up again after "Start over" no request is resent.
  final Set<String> _disliked = {};

  /// Swipe a card right (like) or left (dislike).
  ///
  /// Like: the interest vector moves toward the story and its category and
  /// tags are added to the preferences. Dislike: the vector moves away and
  /// the story leaves the personal feed. The server treats them as mutually
  /// exclusive signals (saving one deletes the other).
  void react(Article article, {required bool like}) {
    if (like) {
      sessionLikes++;
    } else {
      sessionDislikes++;
    }
    _recordOpinion(article.id, like: like);
    if (_deckHold == article.id) _deckHold = null;
    read.add(article.id);
    _persistIds(_kRead, read);
    notifyListeners();
    // Prepare the next page before the cards run out.
    if (deck.length <= 3) loadMoreFeed();
  }

  /// Saves a like or dislike on the device and sends it to the server.
  /// A dislike is not resent for the same story (the server would push the
  /// vector away again each time).
  void _recordOpinion(String id, {required bool like}) {
    if (like) {
      _disliked.remove(id);
      if (liked.add(id)) {
        _persistIds(_kLiked, liked);
        _syncInteraction(id, InteractionType.like, true);
      }
    } else {
      if (liked.remove(id)) _persistIds(_kLiked, liked);
      if (_disliked.add(id)) {
        _syncInteraction(id, InteractionType.dislike, true);
      }
    }
  }

  /// Marks the open tab's stories unread again ("Show them again").
  void rereadFeed() {
    read.removeAll(feedFor(feedCategory).map((a) => a.id));
    _persistIds(_kRead, read);
    sessionLikes = 0;
    sessionDislikes = 0;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Daily brief
  // -------------------------------------------------------------------------
  /// Number of stories the home page comparison brief uses (when not
  /// signed in).
  static const briefSize = 3;

  String? brief;
  bool briefLoading = false;
  ApiException? briefError;

  /// Title of the "Latest developments" card when signed in; `null` for the
  /// general brief.
  String? briefTitle;

  List<Article> _briefSources = const [];
  int _briefGeneration = 0;

  /// When the server refreshes the card in the background, ask once more after this.
  static const briefRefreshDelay = Duration(seconds: 8);

  /// The brief's source stories: the stories the "Latest developments" card
  /// was written from when signed in, otherwise the first stories of the feed.
  List<Article> get briefArticles =>
      hasServerUser ? _briefSources : feed.take(briefSize).toList();

  /// Loads the feed and builds the home page brief once.
  ///
  /// Signed in: `GET /api/users/{id}/latest-developments`, a headline
  /// ([briefTitle]) and paragraph ([brief]) written from the top stories;
  /// ~2 s the first time, then from the cache. Spends no Tavily credits.
  /// Otherwise the first stories are compared with `synthesize` (~15-25 s).
  Future<void> loadBrief() async {
    if (briefLoading || brief != null) return;
    // Set the flag at once so concurrent calls do not start a second request.
    briefLoading = true;
    briefError = null;
    final generation = _briefGeneration;
    try {
      if (hasServerUser) {
        // The feed and the brief load without waiting for each other.
        ensureFeed();
        await Future<void>.value();
        notifyListeners();
        final latest = await api.getLatestDevelopments(user!.id);
        if (generation != _briefGeneration) return;
        _applyLatest(latest);
        if (latest.refreshing) _refreshBriefLater(generation);
      } else {
        await ensureFeed();
        final ids = briefArticles.map((a) => a.id).toList();
        if (ids.length < 2) return;
        await Future<void>.value();
        notifyListeners();
        final text = await api.synthesizeArticles(ids);
        if (generation != _briefGeneration) return;
        brief = text;
      }
    } on ApiException catch (e) {
      if (generation == _briefGeneration) briefError = e;
    } finally {
      if (generation == _briefGeneration) {
        briefLoading = false;
        notifyListeners();
      }
    }
  }

  void _applyLatest(LatestDevelopments latest) {
    _remember(latest.articles);
    _briefSources = latest.articles;
    briefTitle = latest.headline;
    brief = latest.paragraph;
  }

  /// The server is refreshing the card in the background: ask again quietly
  /// a bit later; on error the current card stays.
  void _refreshBriefLater(int generation) {
    Future<void>.delayed(briefRefreshDelay, () async {
      final current = user;
      if (generation != _briefGeneration || current == null) return;
      try {
        final latest = await api.getLatestDevelopments(current.id);
        if (generation != _briefGeneration) return;
        _applyLatest(latest);
        notifyListeners();
      } on ApiException {
        // The current card stays on screen.
      }
    });
  }

  // -------------------------------------------------------------------------
  // Search (from the top bar to Discover)
  // -------------------------------------------------------------------------
  String searchQuery = '';

  void search(String query) {
    searchQuery = query.trim();
    navIndex = navDiscover;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    if (searchQuery == query) return;
    searchQuery = query;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Saved stories / likes
  // -------------------------------------------------------------------------
  /// Kept per user on the device and also sent to the server. The server has
  /// no listing endpoint, so the lists are shown from the device.
  final Set<String> saved = {};
  final Set<String> liked = {};

  bool isSaved(String id) => saved.contains(id);
  bool isLiked(String id) => liked.contains(id);

  void toggleSaved(String id) {
    final active = saved.add(id);
    if (!active) saved.remove(id);
    _persistIds(_kSaved, saved);
    _syncInteraction(id, InteractionType.bookmark, active);
    notifyListeners();
  }

  void toggleLiked(String id) {
    final active = liked.add(id);
    if (!active) liked.remove(id);
    // Saving a like makes the server delete the dislike.
    if (active) _disliked.remove(id);
    _persistIds(_kLiked, liked);
    _syncInteraction(id, InteractionType.like, active);
    notifyListeners();
  }

  List<Article> get savedArticles => _known(saved);
  List<Article> get likedArticles => _known(liked);

  /// Those in the cache, most recently added first.
  List<Article> _known(Set<String> ids) =>
      ids.toList().reversed.map(articleById).whereType<Article>().toList();

  /// Requests for the same story are sent in order: the server toggles, so
  /// rapid clicks must not undo each other. Like and dislike share the queue
  /// because each deletes the other on the server.
  final Map<String, Future<void>> _interactionQueue = {};

  void _syncInteraction(String articleId, InteractionType type, bool active) {
    final current = user;
    if (current == null || !hasServerUser) return;
    final lane = type == InteractionType.bookmark ? 'bookmark' : 'opinion';
    final key = '$lane:$articleId';
    final previous = _interactionQueue[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      try {
        final result = await api.setInteraction(
          articleId,
          userId: current.id,
          type: type,
          active: active,
        );
        _applyLearnedPreferences(current.id, result);
      } on ApiException {
        // The device state stays; the next personal feed load brings back
        // the server's like state (`is_liked`).
      }
      if (identical(_interactionQueue[key], next)) {
        _interactionQueue.remove(key);
      }
    });
    _interactionQueue[key] = next;
  }

  /// After a like / dislike the server updates the preferences itself (the
  /// liked story's category and tags are added, the disliked one's tags
  /// removed). Show the current list in the profile and the feed panel.
  void _applyLearnedPreferences(String userId, InteractionResult result) {
    final current = user;
    final macros = result.preferredMacroTags;
    final micros = result.preferredMicroTags;
    if (current == null || current.id != userId) return;
    if (macros == null && micros == null) return;
    user = current.copyWith(
      preferredMacroTags: macros,
      preferredMicroTags: micros,
    );
    notifyListeners();
  }

  /// Records are kept per username, so two accounts on the same device never
  /// see each other's lists.
  String _libraryKey(String base) => '$base:${user?.username ?? ''}';

  void _loadLibrary() {
    saved
      ..clear()
      ..addAll(_readIds(_kSaved));
    liked
      ..clear()
      ..addAll(_readIds(_kLiked));
    read
      ..clear()
      ..addAll(_readIds(_kRead));
    researched
      ..clear()
      ..addAll(_readIds(_kResearched));
  }

  List<String> _readIds(String base) {
    final prefs = _prefs;
    if (prefs == null) return const [];
    // Older versions kept the records under a user-independent key.
    return prefs.getStringList(_libraryKey(base)) ??
        prefs.getStringList(base) ??
        const [];
  }

  void _persistIds(String base, Set<String> ids) =>
      _prefs?.setStringList(_libraryKey(base), ids.toList());

  // -------------------------------------------------------------------------
  // WAI chat
  // -------------------------------------------------------------------------
  /// Chats in the order they were opened. The key names the scope:
  /// `story:<story>`, `latest` or `area:<area>`; opening the same scope again
  /// returns to the earlier chat.
  final Map<String, WaiThread> threads = {};
  String? activeThreadId;

  WaiThread? get activeThread => threads[activeThreadId];

  List<ChatMessage> get activeMessages => activeThread?.messages ?? const [];

  /// The story of a story chat; `null` in other chats.
  Article? get activeThreadArticle => activeThread?.article;

  /// Is WAI writing in the active chat right now?
  bool get waiTyping => activeMessages.any((m) => m.streaming);

  void openThread(String id) {
    activeThreadId = id;
    notifyListeners();
  }

  /// Returns to the area picker.
  void startNewChat() {
    activeThreadId = null;
    notifyListeners();
  }

  /// From a story card: WAI reads the full text and opens the chat itself.
  void askAbout(Article article) {
    _remember([article]);
    _startThread(
      WaiThread(
        id: 'story:${article.id}',
        mode: WaiMode.story,
        title: article.title,
        article: article,
      ),
    );
  }

  /// From the home page "Latest developments" card: WAI reads the card and
  /// the stories behind it.
  void askLatest() => _startThread(
    WaiThread(
      id: 'latest',
      mode: WaiMode.latest,
      title: briefTitle ?? 'Your latest developments',
    ),
  );

  /// The area (category or subtopic) picked in the WAI tab: WAI reads that
  /// area's latest stories.
  void askArea(String area, {required String label}) => _startThread(
    WaiThread(id: 'area:$area', mode: WaiMode.area, title: label, area: area),
  );

  void _startThread(WaiThread thread) {
    activeThreadId = thread.id;
    navIndex = navChat;
    if (threads.containsKey(thread.id)) {
      notifyListeners();
      return;
    }
    threads[thread.id] = thread;
    if (thread.article != null) {
      thread.messages.add(
        ChatMessage(role: ChatRole.user, article: thread.article),
      );
    }
    _openThread(thread);
  }

  /// WAI reads the scope and writes the first message (`POST /api/wai/open`).
  /// Without a server user a story chat uses the older endpoint and shows a
  /// fixed opening.
  Future<void> _openThread(WaiThread thread) async {
    final reply = ChatMessage(
      role: ChatRole.assistant,
      streaming: true,
      isOpening: true,
    );
    thread.messages.add(reply);
    notifyListeners();
    final current = user;
    try {
      if (!hasServerUser || current == null) {
        reply.text = "I've read this story. What would you like to know?";
      } else {
        final opening = await api.openWai(
          userId: current.id,
          mode: thread.mode.name,
          articleId: thread.article?.id,
          area: thread.area,
        );
        if (opening.title.isNotEmpty) thread.title = opening.title;
        thread
          ..subtitle = opening.subtitle
          ..sources = opening.sources;
        _remember(opening.sources);
        reply.text = opening.opening;
      }
    } on ApiException catch (e) {
      reply
        ..isError = true
        ..text = e.userMessage;
    } finally {
      reply.streaming = false;
      reply.time = DateTime.now();
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final question = text.trim();
    final thread = activeThread;
    if (question.isEmpty || thread == null || waiTyping) return;
    thread.messages.add(ChatMessage(role: ChatRole.user, text: question));
    await _answer(thread, question);
  }

  /// Deletes the failed reply and asks the same question again; for the
  /// opening message, reopens the chat.
  Future<void> retry(ChatMessage failed) async {
    final thread = activeThread;
    if (thread == null || waiTyping) return;
    final messages = thread.messages;
    final index = messages.indexOf(failed);
    if (index < 0) return;
    messages.removeAt(index);
    if (failed.isOpening) {
      await _openThread(thread);
      return;
    }
    final question = messages
        .take(index)
        .lastWhere(
          (m) => m.role == ChatRole.user && m.text.isNotEmpty,
          orElse: () => ChatMessage(role: ChatRole.user),
        )
        .text;
    if (question.isEmpty) {
      notifyListeners();
      return;
    }
    await _answer(thread, question);
  }

  Future<void> _answer(WaiThread thread, String question) async {
    // History sent to the server: the successful turns before this question
    // (including WAI's opening, so short answers like "yes" make sense).
    final history = <ChatTurn>[
      for (final m in thread.messages)
        if (m.text.isNotEmpty && !m.isError && m.article == null)
          m.role == ChatRole.user
              ? ChatTurn.user(m.text)
              : ChatTurn.assistant(m.text),
    ];
    if (history.isNotEmpty) history.removeLast(); // Sorunun kendisi.

    final reply = ChatMessage(role: ChatRole.assistant, streaming: true);
    thread.messages.add(reply);
    notifyListeners();

    final current = user;
    final stream = hasServerUser && current != null
        ? api.waiChatStream(
            userId: current.id,
            mode: thread.mode.name,
            articleId: thread.article?.id,
            area: thread.area,
            sourceIds: [for (final s in thread.sources) s.id],
            question: question,
            history: history,
          )
        : api.chatStream(
            thread.article!.id,
            question: question,
            history: history,
          );
    // Redraw at most every 50 ms, not on every chunk: drawing per chunk
    // made the whole UI stutter while text streamed in.
    final sinceRedraw = Stopwatch()..start();
    try {
      await for (final chunk in stream) {
        reply.text += chunk;
        if (sinceRedraw.elapsedMilliseconds >= 50) {
          sinceRedraw.reset();
          notifyListeners();
        }
      }
    } on ApiException catch (e) {
      reply
        ..isError = true
        ..text = e.userMessage;
    } finally {
      reply.streaming = false;
      reply.time = DateTime.now();
      notifyListeners();
    }
  }

  void toggleHelpful(ChatMessage message) {
    message.helpful = !message.helpful;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Fact Check badges
  // -------------------------------------------------------------------------
  /// Results of Fact Checks run in this session, so every card of the story
  /// shows the badge at once (lists loaded earlier do not have it yet).
  final Map<String, String> _factChecks = {};

  String? factCheckFor(Article a) => _factChecks[a.id] ?? a.factCheckVerdict;

  void setFactCheck(String articleId, String code) {
    if (_factChecks[articleId] == code) return;
    _factChecks[articleId] = code;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Running Fact Checks and Research (the activity bar on top of the page)
  // -------------------------------------------------------------------------
  final Map<String, RunningTask> _tasks = {};

  /// Oldest first.
  List<RunningTask> get runningTasks => _tasks.values.toList();

  void _startTask(TaskKind kind, Article article) {
    _tasks.putIfAbsent(
      '${kind.name}:${article.id}',
      () => RunningTask(kind: kind, article: article),
    );
  }

  void _endTask(TaskKind kind, String articleId) =>
      _tasks.remove('${kind.name}:$articleId');

  // Fact Check: runs here, not in the story's dialog, so it keeps going
  // when the dialog closes.
  final Map<String, FactCheckResult> _factCheckResults = {};
  final Map<String, String> _factCheckErrors = {};

  bool isFactChecking(String articleId) =>
      _tasks.containsKey('${TaskKind.factCheck.name}:$articleId');

  /// The step the server is on ("Querying Tavily…").
  String? factCheckStep(String articleId) =>
      _tasks['${TaskKind.factCheck.name}:$articleId']?.step;

  FactCheckResult? factCheckResult(String articleId) =>
      _factCheckResults[articleId];

  String? factCheckError(String articleId) => _factCheckErrors[articleId];

  /// Streams the server's Fact Check (`deep-inspect`, SSE): status steps,
  /// then the result.
  Future<void> startFactCheck(Article article) async {
    if (isFactChecking(article.id)) return;
    _startTask(TaskKind.factCheck, article);
    _factCheckErrors.remove(article.id);
    notifyListeners();
    String? error;
    try {
      await for (final event in api.deepInspectStream(article.id)) {
        if (event.event == 'status') {
          _tasks['${TaskKind.factCheck.name}:${article.id}']?.step = event.data;
          notifyListeners();
        } else if (event.event == 'final') {
          final json = jsonDecode(event.data);
          if (json is Map<String, dynamic>) {
            final result = FactCheckResult.fromJson(json);
            _factCheckResults[article.id] = result;
            _factChecks[article.id] = factCheckCode(result.factCheckVerdict);
            _notify(
              AppNotification(
                kind: NotificationKind.factCheck,
                title: 'Fact Check done',
                body: article.title,
                article: article,
              ),
            );
          }
        } else if (event.event == 'error') {
          error = event.data;
          try {
            final errJson = jsonDecode(event.data);
            if (errJson is Map && errJson['message'] != null) {
              error = errJson['message'].toString();
            }
          } on FormatException {
            // Plain text message.
          }
        }
      }
    } on ApiException catch (e) {
      error = e.userMessage;
    } catch (e) {
      error = e.toString();
    }
    if (error != null) _factCheckErrors[article.id] = error;
    _endTask(TaskKind.factCheck, article.id);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Tavily Research (runs in the background, a notification says when done)
  // -------------------------------------------------------------------------
  final Map<String, ArticleResearch> _research = {};
  final Set<String> _researching = {};

  /// Stories the user started Research on, for the Research page. Kept per
  /// user on the device, like saved stories.
  final Set<String> researched = {};

  /// Most recent first.
  List<String> get researchedIds => researched.toList().reversed.toList();
  final Map<String, String> _researchErrors = {};

  /// The story's finished report, if there is one.
  ArticleResearch? researchFor(String articleId) {
    final r = _research[articleId];
    return r != null && r.isCompleted ? r : null;
  }

  /// `true` from the tap until the report is ready, even while the story's
  /// dialog is closed.
  bool isResearching(String articleId) => _researching.contains(articleId);

  /// Jobs still running (the menu's Research badge).
  int get researchingCount => _researching.length;

  String? researchError(String articleId) => _researchErrors[articleId];

  /// Shows a saved report, or resumes watching a job started earlier (spends
  /// no credits).
  Future<void> loadResearch(Article article) async {
    if (_research.containsKey(article.id) || isResearching(article.id)) return;
    try {
      final r = await api.getResearch(article.id);
      if (r.status == 'none') return;
      _research[article.id] = r;
      if (r.isRunning) {
        _watchResearch(article);
      } else {
        notifyListeners();
      }
    } on ApiException {
      // Without a report the button shows.
    }
  }

  /// Starts Tavily Research. The server may hold the request for ~25 s; the
  /// spinner shows from the tap, and [_watchResearch] keeps polling after.
  Future<void> startResearch(Article article) async {
    if (isResearching(article.id)) return;
    _remember([article]);
    researched
      ..remove(article.id)
      ..add(article.id);
    _persistIds(_kResearched, researched);
    _researching.add(article.id);
    _startTask(TaskKind.research, article);
    _researchErrors.remove(article.id);
    notifyListeners();
    try {
      final r = await api.startResearch(article.id);
      _research[article.id] = r;
      if (r.isRunning) {
        await _watchResearch(article);
      } else {
        _finishResearch(article, r);
      }
    } on ApiException catch (e) {
      _researching.remove(article.id);
      _endTask(TaskKind.research, article.id);
      _researchErrors[article.id] = e.userMessage;
      notifyListeners();
    }
  }

  /// Polls every 5 s (at most 3 min); each poll asks Tavily for the job
  /// status and spends no credits.
  Future<void> _watchResearch(Article article) async {
    _researching.add(article.id);
    _startTask(TaskKind.research, article);
    notifyListeners();
    for (var tries = 0; tries < 36; tries++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (user == null) return;
      try {
        final r = await api.getResearch(article.id);
        if (!r.isRunning) {
          _finishResearch(article, r);
          return;
        }
      } on ApiException {
        // Asked again on the next try.
      }
    }
    _finishResearch(article, null);
  }

  void _finishResearch(Article article, ArticleResearch? r) {
    _researching.remove(article.id);
    _endTask(TaskKind.research, article.id);
    if (r != null && r.isCompleted) {
      _research[article.id] = r;
      _notify(
        AppNotification(
          kind: NotificationKind.research,
          title: 'Research ready',
          body: article.title,
          article: article,
        ),
      );
    } else {
      _research.remove(article.id);
      _researchErrors[article.id] = 'Tavily Research could not finish.';
      _notify(
        AppNotification(
          kind: NotificationKind.error,
          title: 'Research could not finish',
          body: article.title,
          article: article,
        ),
      );
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Notifications (top bar bell, this session only)
  // -------------------------------------------------------------------------
  final List<AppNotification> inbox = [];
  int unreadNotifications = 0;

  void _notify(AppNotification n) {
    inbox.insert(0, n);
    unreadNotifications++;
  }

  void markNotificationsRead() {
    if (unreadNotifications == 0) return;
    unreadNotifications = 0;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Settings (this session only)
  // -------------------------------------------------------------------------
  ThemeChoice theme = ThemeChoice.dark;

  /// Text scale applied to reading text (1.0 = 16 px).
  double fontScale = 1.0;
  double audioSpeed = 1.25;
  bool notifications = true;
  String language = 'English';

  void setTheme(ThemeChoice value) {
    theme = value;
    notifyListeners();
  }

  void setFontScale(double value) {
    fontScale = value;
    notifyListeners();
  }

  void setAudioSpeed(double value) {
    audioSpeed = value;
    notifyListeners();
  }

  void setNotifications(bool value) {
    notifications = value;
    notifyListeners();
  }

  void setLanguage(String value) {
    language = value;
    notifyListeners();
  }
}

enum ThemeChoice { light, dark, system }

/// Onboarding steps: 1 pick, 2 taste check, 3 your feed is ready.
enum OnboardingStep { pick, taste, reveal }

enum ChatRole { user, assistant }

enum NotificationKind { research, factCheck, error }

enum TaskKind { factCheck, research }

/// A Fact Check or Research in progress, shown in the activity bar.
class RunningTask {
  RunningTask({required this.kind, required this.article})
    : started = DateTime.now();

  final TaskKind kind;
  final Article article;
  final DateTime started;

  /// The server's current step, if it reports one (Fact Check).
  String? step;

  /// Typical length: the bar fills toward it, then keeps moving.
  Duration get expected => kind == TaskKind.factCheck
      ? const Duration(seconds: 30)
      : const Duration(seconds: 60);
}

/// An entry in the top bar's notifications menu; tapping it opens [article].
class AppNotification {
  AppNotification({
    required this.kind,
    required this.title,
    required this.body,
    this.article,
  }) : time = DateTime.now();

  final NotificationKind kind;
  final String title;
  final String body;
  final Article? article;
  final DateTime time;
}

/// The scope of a WAI chat: a story, the home page latest developments, or
/// an area picked in the WAI tab.
enum WaiMode { story, latest, area }

/// A WAI chat: its scope, the stories WAI read, and the messages.
class WaiThread {
  WaiThread({
    required this.id,
    required this.mode,
    required this.title,
    this.article,
    this.area,
  });

  final String id;
  final WaiMode mode;

  /// Story title, latest developments title or area name (the server
  /// updates it when the chat opens).
  String title;
  String subtitle = '';

  /// The story, in a story chat.
  final Article? article;

  /// Category (e.g. `AI`) or subtopic (e.g. `fintech`), in an area chat.
  final String? area;

  /// Stories WAI read; [1], [2] in answers refer to this order.
  List<Article> sources = const [];
  final List<ChatMessage> messages = [];
}

class ChatMessage {
  ChatMessage({
    required this.role,
    this.text = '',
    this.article,
    this.streaming = false,
    this.isOpening = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final ChatRole role;

  /// WAI's first message that opens the chat.
  final bool isOpening;

  /// Grows chunk by chunk while streaming.
  String text;

  /// If set, the message is a story card sent to WAI.
  final Article? article;
  DateTime time;
  bool streaming;
  bool isError = false;
  bool helpful = false;
}

/// The server's macro categories (Discover tags).
const macroCategories = [
  'Tech',
  'AI',
  'Hardware',
  'Automotive',
  'Gaming',
  'Finance',
  'Science',
];
