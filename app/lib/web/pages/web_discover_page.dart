import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../models/article_ui.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/smooth_scroll.dart';
import '../../widgets/state_views.dart';
import '../widgets/web_ui.dart';

/// Discover: natural-language search, category tags and a side panel.
class WebDiscoverPage extends StatefulWidget {
  const WebDiscoverPage({super.key});

  @override
  State<WebDiscoverPage> createState() => _WebDiscoverPageState();
}

class _WebDiscoverPageState extends State<WebDiscoverPage> {
  final _state = AppState.instance;
  late final _search = TextEditingController(text: _state.searchQuery);
  Timer? _debounce;
  final _scroll = SmoothScrollController();

  // Arama
  int _searchSeq = 0;
  GroupedSearch? _results;
  bool _searching = false;
  ApiException? _searchError;

  // Kategori
  String? _tag;
  List<Article>? _tagArticles;
  bool _tagLoading = false;
  ApiException? _tagError;

  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    _state.ensureFeed();
    if (_query.length >= ApiService.minSearchLength) _runSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _state.setSearchQuery(value);
    _debounce?.cancel();
    if (value.trim().length < ApiService.minSearchLength) {
      _searchSeq++;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), _runSearch);
  }

  void _searchFor(String query) {
    _search.text = query;
    _onQueryChanged(query);
  }

  Future<void> _runSearch() async {
    final q = _query;
    if (q.length < ApiService.minSearchLength) return;
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await _state.api.searchGrouped(q);
      if (!mounted || seq != _searchSeq) return;
      setState(() => _results = r);
      // Text matches came first; the meaning matches follow once the
      // server has the query's embedding (it keeps computing it).
      if (!r.semantic) _refineLater(q, seq);
    } on ApiException catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() => _searchError = e);
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _searching = false);
    }
  }

  /// Asks again after 3, 6 and 10 s until the meaning matches are in; each
  /// repeat is cheap (text search plus a cached embedding once it is ready).
  void _refineLater(String q, int seq, {int attempt = 0}) {
    const delays = [3, 3, 4];
    if (attempt >= delays.length) return;
    Timer(Duration(seconds: delays[attempt]), () async {
      if (!mounted || seq != _searchSeq || q != _query) return;
      try {
        final r = await _state.api.searchGrouped(q);
        if (!mounted || seq != _searchSeq) return;
        setState(() => _results = r);
        if (!r.semantic) _refineLater(q, seq, attempt: attempt + 1);
      } on ApiException {
        // The text matches stay on screen.
      }
    });
  }

  Future<void> _selectTag(String? tag) async {
    setState(() {
      _tag = tag;
      _tagArticles = null;
      _tagError = null;
      _tagLoading = tag != null;
    });
    if (tag == null) return;
    try {
      final list = await _state.api.getArticles(macro: tag, pageSize: 50);
      if (!mounted || _tag != tag) return;
      setState(() => _tagArticles = list);
    } on ApiException catch (e) {
      if (!mounted || _tag != tag) return;
      setState(() => _tagError = e);
    } finally {
      if (mounted && _tag == tag) setState(() => _tagLoading = false);
    }
  }

  void _clearAll() {
    _search.clear();
    _onQueryChanged('');
    _selectTag(null);
  }

  bool _matchesTag(Article a) => _tag == null || a.macroTags.contains(_tag);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(40, 32, 40, 56),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1320),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSearchBar(),
                      const SizedBox(height: 26),
                      _buildTags(),
                      const SizedBox(height: 34),
                      ..._buildResults(),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                SizedBox(
                  width: 340,
                  child: _SidePanel(state: _state, onTopic: _searchFor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildResults() {
    final ranked = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.auto_awesome_outlined,
          size: 15,
          color: AppColors.textMuted,
        ),
        const SizedBox(width: 6),
        Text(
          'AI-ranked',
          style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13),
        ),
      ],
    );

    // 1) Arama
    if (_query.length >= ApiService.minSearchLength) {
      if (_searchError != null) {
        return [ErrorView(error: _searchError!, onRetry: _runSearch)];
      }
      if (_searching || _results == null) {
        return const [
          LoadingView(
            message: 'Searching…',
            hint:
                'The first search after the server starts can take up to '
                'a minute.',
          ),
        ];
      }
      final direct = _results!.direct.where((h) => _matchesTag(h.article));
      final explore = _results!.explore.where((h) => _matchesTag(h.article));
      if (direct.isEmpty && explore.isEmpty) return [_empty()];
      return [
        if (direct.isNotEmpty) ...[
          SectionTitle('Top matches', trailing: ranked),
          const SizedBox(height: 20),
          _Grid(hits: direct.toList()),
        ],
        if (explore.isNotEmpty) ...[
          if (direct.isNotEmpty) const SizedBox(height: 40),
          const SectionTitle('You might also explore'),
          const SizedBox(height: 8),
          Text(
            'Related stories from adjacent topics.',
            style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _Grid(hits: explore.toList()),
        ],
      ];
    }

    // 2) Kategori
    if (_tag != null) {
      if (_tagError != null) {
        return [ErrorView(error: _tagError!, onRetry: () => _selectTag(_tag))];
      }
      if (_tagLoading || _tagArticles == null) {
        return const [LoadingView(message: 'Loading stories…')];
      }
      if (_tagArticles!.isEmpty) return [_empty()];
      return [
        SectionTitle(_tag!, trailing: _count(_tagArticles!.length)),
        const SizedBox(height: 20),
        _Grid(articles: _tagArticles!),
      ];
    }

    // 3) Default: the newest stories
    final feed = _state.feed;
    if (feed.isEmpty && _state.feedError != null) {
      return [
        ErrorView(error: _state.feedError!, onRetry: _state.loadMoreFeed),
      ];
    }
    if (feed.isEmpty) {
      return const [LoadingView(message: 'Loading stories…')];
    }
    return [
      SectionTitle('Latest', trailing: _count(feed.length)),
      const SizedBox(height: 20),
      _Grid(articles: feed),
      if (_state.feedHasMore) ...[
        const SizedBox(height: 24),
        Center(
          child: _state.feedLoading
              ? const LoadingView(padding: 8)
              : WebButton(
                  label: 'Load more',
                  primary: false,
                  onTap: _state.loadMoreFeed,
                ),
        ),
      ],
    ];
  }

  Widget _count(int n) => Text(
    '$n ${n == 1 ? 'story' : 'stories'}',
    style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13),
  );

  Widget _empty() => EmptyView(
    icon: Icons.search_off_rounded,
    title: 'No results found',
    message: 'Try a different keyword or remove the category filter.',
    action: WebButton(label: 'Clear filters', primary: false, onTap: _clearAll),
  );

  Widget _buildSearchBar() {
    return SizedBox(
      height: 56,
      child: TextField(
        controller: _search,
        autofocus: _state.searchQuery.isEmpty,
        onChanged: _onQueryChanged,
        onSubmitted: (_) {
          _debounce?.cancel();
          _runSearch();
        },
        cursorColor: AppColors.accentLight,
        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 15.5),
        decoration: InputDecoration(
          hintText: 'Search in plain English, e.g. "new GPU chips"…',
          hintStyle: GoogleFonts.inter(
            color: AppColors.textMuted,
            fontSize: 15.5,
          ),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(Icons.search_rounded, color: AppColors.iconMuted),
          ),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  onPressed: () => _searchFor(''),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textMuted,
                    size: 20,
                  ),
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: EdgeInsets.zero,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }

  Widget _buildTags() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const OverlineLabel('Categories'),
            const Spacer(),
            if (_tag != null)
              LinkButton(
                'Clear selection',
                icon: Icons.close_rounded,
                onTap: () => _selectTag(null),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tag in macroCategories)
              PillButton(
                label: tag,
                selected: _tag == tag,
                showCheck: true,
                onTap: () => _selectTag(_tag == tag ? null : tag),
              ),
          ],
        ),
      ],
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({this.articles, this.hits});

  final List<Article>? articles;
  final List<SearchHit>? hits;

  @override
  Widget build(BuildContext context) {
    const gap = 20.0;
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 900 ? 3 : 2;
        final w = (c.maxWidth - gap * (columns - 1)) / columns;
        final cards = <Widget>[
          if (articles != null)
            for (final a in articles!) NewsGridCard(a),
          if (hits != null)
            for (final h in hits!) _HitCard(hit: h),
        ];
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: w, child: card)],
        );
      },
    );
  }
}

/// Search result card: relevance score and (for explore results) the angle.
class _HitCard extends StatelessWidget {
  const _HitCard({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final angle = hit.isDirect ? null : hit.exploreAngle;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NewsGridCard(hit.article),
            if (angle != null) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.alt_route_rounded,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      angle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        if (hit.relevanceScore != null)
          Positioned(
            right: 12,
            top: 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xD9111110),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${hit.relevanceScore}% match',
                  style: GoogleFonts.inter(
                    color: hit.isDirect ? AppColors.mint : AppColors.iconMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.state, required this.onTopic});

  final AppState state;
  final ValueChanged<String> onTopic;

  /// The most frequent subtopic tags in the feed.
  List<(String, int)> get _topics {
    final counts = <String, int>{};
    for (final a in state.feed) {
      for (final t in a.microTags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in sorted.take(6)) (e.key, e.value)];
  }

  static String _label(String tag) => tag
      .split(RegExp(r'[_\s]+'))
      .where((w) => w.isNotEmpty)
      .map(
        (w) => w.length <= 3
            ? w.toUpperCase()
            : '${w[0].toUpperCase()}${w.substring(1)}',
      )
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final top = state.feed.isEmpty ? null : state.feed.first;
    final topics = _topics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (top != null)
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bolt_rounded, size: 18, color: AppColors.mint),
                    SizedBox(width: 6),
                    OverlineLabel('Quick brief', color: AppColors.mint),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  top.title,
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  top.summary,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sourceSerif4(
                    color: AppColors.textBody,
                    fontSize: 15,
                    height: 1.55,
                  ),
                ),
                if (state.isLive) ...[
                  const SizedBox(height: 16),
                  LinkButton(
                    'Dig deeper with WAI',
                    onTap: () => state.askAbout(top),
                  ),
                ],
              ],
            ),
          ),
        if (topics.isNotEmpty) ...[
          const SizedBox(height: 20),
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const OverlineLabel('Trending topics'),
                const SizedBox(height: 14),
                for (var i = 0; i < topics.length; i++)
                  Hoverable(
                    onTap: () => onTopic(_label(topics[i].$1)),
                    builder: (context, hovered) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: hovered ? AppColors.surfaceAlt : null,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${i + 1}',
                              style: GoogleFonts.playfairDisplay(
                                color: AppColors.accentLight,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              _label(topics[i].$1),
                              style: GoogleFonts.inter(
                                color: AppColors.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${topics[i].$2} '
                            '${topics[i].$2 == 1 ? 'story' : 'stories'}',
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
