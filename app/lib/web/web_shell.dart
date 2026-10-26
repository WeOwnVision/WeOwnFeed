import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import 'pages/web_chat_page.dart';
import 'pages/web_discover_page.dart';
import 'pages/web_feed_page.dart';
import 'pages/web_home_page.dart';
import 'pages/web_profile_page.dart';
import 'pages/web_research_page.dart';
import 'pages/web_sites_page.dart';
import 'widgets/article_dialog.dart';
import 'widgets/tavily_terminal.dart';
import 'widgets/web_ui.dart';

/// Skeleton of the web (desktop) UI: menu on the left, bar on top, page on the right.
class WebShell extends StatelessWidget {
  const WebShell({super.key});

  /// Below these sizes the page does not shrink; it scrolls.
  static const double minWidth = 1200;
  static const double minHeight = 700;

  static const pages = <_WebPage>[
    _WebPage(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: 'Home',
      title: 'Home',
    ),
    _WebPage(
      icon: Icons.view_carousel_outlined,
      activeIcon: Icons.view_carousel,
      label: 'WOF Feed',
      title: 'WOF Feed',
      subtitle: 'Swipe and react',
    ),
    _WebPage(
      icon: Icons.forum_outlined,
      activeIcon: Icons.forum,
      label: 'WAI Assistant',
      title: 'WAI',
      subtitle: 'Your news assistant',
    ),
    _WebPage(
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore,
      label: 'Discover',
      title: 'Discover',
      subtitle: 'Search & explore news',
    ),
    _WebPage(
      icon: Icons.travel_explore_outlined,
      activeIcon: Icons.travel_explore_rounded,
      label: 'Research',
      title: 'Research',
      subtitle: 'Cited reports on the stories you dug into',
    ),
    _WebPage(
      icon: Icons.language_outlined,
      activeIcon: Icons.language_rounded,
      label: 'Site Watch',
      title: 'Site Watch',
      subtitle: 'Follow any newsroom or blog, even without RSS',
    ),
    _WebPage(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: 'Profile & Settings',
      title: 'Profile & Settings',
      subtitle: 'Your account and preferences',
    ),
  ];

  Widget _pageBody(int index, {required bool live}) => switch (index) {
    AppState.navFeed => const WebFeedPage(),
    // WAI and Site Watch need the server; offline sessions go home.
    AppState.navChat when live => const WebChatPage(),
    AppState.navDiscover => const WebDiscoverPage(),
    AppState.navResearch => const WebResearchPage(),
    AppState.navSites when live => const WebSitesPage(),
    AppState.navProfile => const WebProfilePage(),
    _ => const WebHomePage(),
  };

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, c) {
          final width = math.max(c.maxWidth, minWidth);
          final height = math.max(c.maxHeight, minHeight);

          Widget shell = ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              final index = state.navIndex;
              final page = pages[index];
              return Row(
                children: [
                  _SideNav(currentIndex: index, onTap: state.goTo),
                  Expanded(
                    child: Column(
                      children: [
                        _TopBar(
                          title: page.title,
                          subtitle:
                              index == AppState.navFeed &&
                                  state.feedCategory != null
                              ? '${state.feedCategory} stories, ranked for you'
                              : page.subtitle ?? greetingLine(),
                          showSearch: index != AppState.navDiscover,
                        ),
                        if (state.isOffline) const _OfflineBanner(),
                        if (_debug) _ModeBadge(live: state.isLive),
                        Expanded(
                          // Reading text follows the text size in Settings.
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: TextScaler.linear(state.fontScale),
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              child: KeyedSubtree(
                                key: ValueKey(index),
                                child: _pageBody(index, live: state.isLive),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const TavilyDock(),
                ],
              );
            },
          );

          shell = SizedBox(width: width, height: height, child: shell);

          // If the window is smaller than desktop size, scroll instead of breaking the layout.
          if (c.maxWidth < minWidth) {
            shell = SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: shell,
            );
          }
          if (c.maxHeight < minHeight) {
            shell = SingleChildScrollView(child: shell);
          }
          return shell;
        },
      ),
    );
  }
}

class _WebPage {
  const _WebPage({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String title;

  /// If empty, the greeting of the day is shown.
  final String? subtitle;
}

// ---------------------------------------------------------------------------
// Left menu
// ---------------------------------------------------------------------------
class _SideNav extends StatelessWidget {
  const _SideNav({required this.currentIndex, required this.onTap});

  /// Menu items hidden in offline sessions.
  static const _onlineOnly = {AppState.navChat, AppState.navSites};

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final onFeed = currentIndex == AppState.navFeed;
    // No count before the feed loads; "0" would give the wrong impression.
    int? unread(String? category) {
      if (state.feed.isEmpty) return null;
      final n = state.unreadCount(category);
      return n == 0 ? null : n;
    }

    return Container(
      width: 264,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 30, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const WofLogo(fontSize: 28),
                const SizedBox(height: 2),
                Text(
                  'World of Feeds',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          const Padding(
            padding: EdgeInsets.only(left: 14, bottom: 10),
            child: OverlineLabel('Menu'),
          ),
          // With many category tabs the menu scrolls on its own.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < WebShell.pages.length; i++)
                    if (state.isLive || !_onlineOnly.contains(i)) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: i == AppState.navFeed
                            ? _SideNavTile(
                                page: WebShell.pages[i],
                                selected: onFeed && state.feedCategory == null,
                                badge: unread(null),
                                onTap: () => state.openFeed(null),
                              )
                            : _SideNavTile(
                                page: WebShell.pages[i],
                                selected: i == currentIndex,
                                badge:
                                    i == AppState.navResearch &&
                                        state.researchingCount > 0
                                    ? state.researchingCount
                                    : null,
                                onTap: () => onTap(i),
                              ),
                      ),
                      // The user's main categories are WOF Feed's sub-tabs.
                      if (i == AppState.navFeed)
                        for (final category in state.interests)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: _SubNavTile(
                              label: category,
                              selected:
                                  onFeed && state.feedCategory == category,
                              badge: unread(category),
                              onTap: () => state.openFeed(category),
                            ),
                          ),
                    ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _UserTile(onTap: () => onTap(AppState.navProfile)),
        ],
      ),
    );
  }
}

class _SideNavTile extends StatelessWidget {
  const _SideNavTile({
    required this.page,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final _WebPage page;
  final bool selected;
  final VoidCallback onTap;

  /// Number of unread stories.
  final int? badge;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) {
        final color = selected
            ? AppColors.accentLight
            : (hovered ? AppColors.textPrimary : AppColors.iconMuted);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surfaceAlt
                : (hovered ? AppColors.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                child: Icon(
                  selected ? page.activeIcon : page.icon,
                  size: 21,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                page.label,
                style: GoogleFonts.inter(
                  color: color,
                  fontSize: 14.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (badge != null) ...[
                const Spacer(),
                _CountBadge(badge!, selected: selected),
              ] else if (selected) ...[
                const Spacer(),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.accentLight,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A category tab under WOF Feed.
class _SubNavTile extends StatelessWidget {
  const _SubNavTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) {
        final color = selected
            ? AppColors.accentLight
            : (hovered ? AppColors.textPrimary : AppColors.textMuted);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          // Starts at the icon's edge so it reads as part of the main tab.
          margin: const EdgeInsets.only(left: 28),
          padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surfaceAlt
                : (hovered ? AppColors.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(
                color: selected ? AppColors.accentLight : AppColors.border,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: color,
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (badge != null) _CountBadge(badge!, selected: selected),
            ],
          ),
        );
      },
    );
  }
}

/// Unread count in the menu.
class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count, {required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: GoogleFonts.inter(
          color: selected ? AppColors.textPrimary : AppColors.textBody,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: hovered ? AppColors.surfaceAlt : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            UserAvatar(size: 38, url: AppState.instance.user?.avatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppState.instance.user?.username ?? 'Reader',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(
              Icons.settings_outlined,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.showSearch,
  });

  final String title;
  final String subtitle;
  final bool showSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          if (showSearch) ...[
            const _TopSearchField(),
            const SizedBox(width: 14),
          ],
          const TavilyTerminalButton(),
          const SizedBox(width: 14),
          const _NotificationsButton(),
          const SizedBox(width: 14),
          const _ProfileMenu(),
        ],
      ),
    );
  }
}

class _TopSearchField extends StatefulWidget {
  const _TopSearchField();

  @override
  State<_TopSearchField> createState() => _TopSearchFieldState();
}

class _TopSearchFieldState extends State<_TopSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (value.trim().isEmpty) return;
    AppState.instance.search(value);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 340,
      height: 46,
      child: TextField(
        controller: _controller,
        onSubmitted: _submit,
        cursorColor: AppColors.accentLight,
        style: GoogleFonts.inter(color: AppColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search news, topics or sources…',
          hintStyle: GoogleFonts.inter(
            color: AppColors.textMuted,
            fontSize: 14,
          ),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppColors.iconMuted,
            size: 20,
          ),
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              widthFactor: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Enter',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: EdgeInsets.zero,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(23),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(23),
            borderSide: const BorderSide(color: AppColors.accent),
          ),
        ),
      ),
    );
  }
}

/// The bell in the top bar: notifications from this session (e.g. a
/// finished Tavily Research). Tapping one opens its story.
class _NotificationsButton extends StatelessWidget {
  const _NotificationsButton();

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => PopupMenuButton<int>(
        tooltip: 'Notifications',
        offset: const Offset(0, 56),
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        onOpened: state.markNotificationsRead,
        onSelected: (i) {
          final article = state.inbox[i].article;
          if (article != null) showArticleDialog(context, article);
        },
        itemBuilder: (context) => [
          if (state.inbox.isEmpty)
            PopupMenuItem<int>(
              enabled: false,
              height: 56,
              child: SizedBox(
                width: 300,
                child: Text(
                  'No notifications yet.',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          for (final (i, n) in state.inbox.indexed)
            PopupMenuItem<int>(
              value: i,
              height: 64,
              child: SizedBox(
                width: 300,
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        n.kind == NotificationKind.research
                            ? Icons.travel_explore_rounded
                            : n.kind == NotificationKind.factCheck
                            ? Icons.verified_user_rounded
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: n.kind != NotificationKind.error
                            ? AppColors.accentLight
                            : AppColors.dislike,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${n.title} · ${_ago(n.time)}',
                            style: GoogleFonts.inter(
                              color: AppColors.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            n.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(
                Icons.notifications_none_rounded,
                color: AppColors.iconMuted,
                size: 22,
              ),
            ),
            if (state.unreadNotifications > 0)
              Positioned(
                right: 11,
                top: 11,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.mint,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.surface, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `?debug=1` in the address shows the session's backend mode.
final bool _debug = Uri.base.queryParameters['debug'] == '1';

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 6),
      color: AppColors.surfaceAlt,
      child: Text(
        live
            ? 'debug · live server (${ApiService.defaultBaseUrl})'
            : 'debug · offline demo (bundled data)',
        style: GoogleFonts.inter(
          color: live ? AppColors.mint : AppColors.contested,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
      color: AppColors.surfaceAlt,
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 18, color: AppColors.mint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Server is offline — showing cached articles. '
              'Live features like search and chat are unavailable.',
              style: GoogleFonts.inter(color: AppColors.textBody, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: () => AppState.instance.refreshFeed(),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Retry'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accentLight,
              textStyle: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu();

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<int> item(
      int value,
      IconData icon,
      String label, {
      Color color = AppColors.textPrimary,
    }) => PopupMenuItem<int>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Text(label, style: GoogleFonts.inter(color: color, fontSize: 13.5)),
        ],
      ),
    );

    return PopupMenuButton<int>(
      tooltip: 'Account',
      offset: const Offset(0, 56),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: (value) {
        if (value == 0) AppState.instance.goTo(AppState.navProfile);
        if (value == 1) AppState.instance.logout();
      },
      itemBuilder: (context) => [
        item(0, Icons.person_outline_rounded, 'Profile & Settings'),
        const PopupMenuDivider(),
        item(1, Icons.logout_rounded, 'Log out', color: AppColors.dislike),
      ],
      child: UserAvatar(size: 46, url: AppState.instance.user?.avatarUrl),
    );
  }
}
