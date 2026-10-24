import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/smooth_scroll.dart';
import '../../widgets/state_views.dart';
import '../widgets/web_ui.dart';

/// Site Watch: the sites the user follows (Tavily Map + Crawl, so a site
/// needs no RSS feed), a field to follow another one while under the limit,
/// and the stories that came from them. The chips on top count each site's
/// stories and filter the grid.
class WebSitesPage extends StatefulWidget {
  const WebSitesPage({super.key});

  @override
  State<WebSitesPage> createState() => _WebSitesPageState();
}

class _WebSitesPageState extends State<WebSitesPage> {
  final _state = AppState.instance;
  final _scroll = SmoothScrollController();
  final _urlCtrl = TextEditingController();

  /// Selected site's id; null shows every site's stories.
  String? _siteFilter;

  @override
  void initState() {
    super.initState();
    _state.loadSites();
    _state.loadSiteStories();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _follow() async {
    if (await _state.addSite(_urlCtrl.text)) {
      _urlCtrl.clear();
      if (mounted) {
        showTopNotice(
          context,
          'Following. Tavily is scanning the site; its newest posts appear '
          'here in a minute or two.',
          icon: Icons.language_rounded,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final sites = _state.sites;
        // A removed site's filter falls back to "All".
        if (_siteFilter != null && !sites.any((s) => s.id == _siteFilter)) {
          _siteFilter = null;
        }
        final stories = [
          for (final (siteId, a) in _state.siteStories.articles)
            if (_siteFilter == null || siteId == _siteFilter) a,
        ];
        return SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(40, 32, 40, 56),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _addCard(sites),
                  const SizedBox(height: 28),
                  if (sites.isNotEmpty) ...[
                    _filters(sites),
                    const SizedBox(height: 24),
                  ],
                  _grid(sites, stories),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// What the feature does, the address field and the limit.
  Widget _addCard(List<FollowedSite> sites) {
    final full = sites.length >= ApiService.maxSites;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Follow a site, even one without RSS',
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '${sites.length} / ${ApiService.maxSites} sites',
                style: GoogleFonts.inter(
                  color: full ? AppColors.dislike : AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Tavily maps the site, finds its newest posts and checks it '
            'again every day. Newsrooms, company blogs, press pages.',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 16),
          if (full)
            Text(
              'You follow ${ApiService.maxSites} sites, the most allowed. '
              'Remove one below to add another.',
              style: GoogleFonts.inter(color: AppColors.textBody, fontSize: 13),
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_state.addingSite,
                    onSubmitted: (_) => _follow(),
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Paste a site address, e.g. anthropic.com/news',
                      hintStyle: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 14,
                      ),
                      prefixIcon: const Icon(
                        Icons.link_rounded,
                        color: AppColors.iconMuted,
                        size: 20,
                      ),
                      filled: true,
                      fillColor: AppColors.surfaceAlt,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                WebButton(
                  label: _state.addingSite ? 'Adding…' : 'Follow',
                  icon: Icons.add_rounded,
                  primary: true,
                  onTap: _follow,
                ),
              ],
            ),
          if (_state.siteError != null) ...[
            const SizedBox(height: 10),
            Text(
              _state.siteError!,
              style: GoogleFonts.inter(color: AppColors.dislike, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  /// "All" plus one chip per site with its story count; tap to filter.
  Widget _filters(List<FollowedSite> sites) {
    final counts = _state.siteStories.counts;
    final total = counts.values.fold(0, (a, b) => a + b);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _SiteChip(
          label: 'All sites',
          count: total,
          selected: _siteFilter == null,
          onTap: () => setState(() => _siteFilter = null),
        ),
        for (final s in sites)
          _SiteChip(
            label: s.name,
            count: counts[s.id] ?? 0,
            site: s,
            selected: _siteFilter == s.id,
            onTap: () =>
                setState(() => _siteFilter = _siteFilter == s.id ? null : s.id),
            onRemove: () => _state.removeSite(s),
          ),
      ],
    );
  }

  Widget _grid(List<FollowedSite> sites, List<Article> stories) {
    if (sites.isEmpty) {
      return const EmptyView(
        icon: Icons.language_rounded,
        title: 'No sites yet',
        message:
            'Paste the address of a newsroom or blog above. Its newest posts '
            'will show up here and in your Feed.',
      );
    }
    if (stories.isEmpty) {
      if (_state.siteStoriesLoading) {
        return const LoadingView(message: 'Loading stories from your sites…');
      }
      final scanning = sites.any((s) => s.isWorking);
      return EmptyView(
        icon: scanning ? Icons.radar_rounded : Icons.inbox_outlined,
        title: scanning ? 'Scanning…' : 'No stories yet',
        message: scanning
            ? 'Tavily is reading the site. New posts land here when the scan '
                  'finishes.'
            : 'No posts from this site have arrived yet. It is checked again '
                  'every day.',
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 20.0;
        final width = (c.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final a in stories)
              SizedBox(width: width, child: NewsGridCard(a)),
          ],
        );
      },
    );
  }
}

/// A filter chip: site name, story count and scan status; × unfollows.
class _SiteChip extends StatelessWidget {
  const _SiteChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.site,
    this.onRemove,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final FollowedSite? site;
  final VoidCallback? onRemove;

  /// Scan status in words; null once the site is ready.
  static String? _status(FollowedSite s) => switch (s.status) {
    'pending' || 'mapping' => 'scanning',
    'crawling' => 'fetching posts',
    'no_articles' => 'no posts found',
    'failed' => 'scan failed',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final s = site;
    final status = s == null ? null : _status(s);
    final problem =
        s != null && (s.status == 'failed' || s.status == 'no_articles');
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.fromLTRB(14, 9, onRemove == null ? 14 : 8, 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : (hovered ? AppColors.surfaceAlt : AppColors.surface),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s != null && s.isWorking) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: AppColors.accentLight,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: GoogleFonts.inter(
                  color: AppColors.mint,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (status != null) ...[
              const SizedBox(width: 8),
              Text(
                status,
                style: GoogleFonts.inter(
                  color: problem ? AppColors.dislike : AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            if (onRemove != null) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Unfollow',
                child: Hoverable(
                  onTap: onRemove,
                  builder: (context, h) => Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: h ? AppColors.textPrimary : AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
