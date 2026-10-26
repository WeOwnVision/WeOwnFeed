import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../models/article_ui.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/smooth_scroll.dart';
import '../../widgets/state_views.dart';
import '../widgets/article_dialog.dart';
import '../widgets/web_ui.dart';

/// WOF card swiping screen. Used with mouse dragging and keyboard shortcuts
/// (← skip, → like, ↑ send to WAI, Space details).
class WebFeedPage extends StatefulWidget {
  const WebFeedPage({super.key});

  @override
  State<WebFeedPage> createState() => _WebFeedPageState();
}

class _WebFeedPageState extends State<WebFeedPage>
    with SingleTickerProviderStateMixin {
  static const _cardWidth = 560.0;
  static const _cardHeight = 600.0;
  static const _swipeThreshold = 150.0;

  final _state = AppState.instance;
  final _focusNode = FocusNode();
  late final AnimationController _anim;

  Animatable<double>? _tween;
  bool _busy = false;

  /// The card's horizontal offset. Widgets listening to it redraw instead of
  /// setState; rebuilding the whole page every frame while dragging stuttered.
  final _dx = ValueNotifier<double>(0);
  final _scroll = SmoothScrollController();

  @override
  void initState() {
    super.initState();
    _state.loadWholeFeed();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() => _dx.value = _tween?.evaluate(_anim) ?? _dx.value);
  }

  @override
  void dispose() {
    _anim.dispose();
    _dx.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double target, Curve curve) {
    _tween = Tween(
      begin: _dx.value,
      end: target,
    ).chain(CurveTween(curve: curve));
    return _anim.forward(from: 0);
  }

  Future<void> _swipe({required bool like}) async {
    final news = _state.currentFeedArticle;
    if (news == null || _busy) return;
    _busy = true;
    await _animateTo(like ? 1100 : -1100, Curves.easeIn);
    _state.react(news, like: like);
    _dx.value = 0;
    _busy = false;
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final dx = _dx.value;
    if (dx.abs() > _swipeThreshold || v.abs() > 900) {
      _swipe(like: (dx + v * 0.1) > 0);
    } else {
      _animateTo(0, Curves.easeOutBack);
    }
  }

  void _sendToWai() {
    if (!_state.isLive) return;
    final news = _state.currentFeedArticle;
    if (news != null) _state.askAbout(news);
  }

  void _openDetail(Article news) {
    _state.openFromDeck(news);
    showArticleDialog(context, news);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final news = _state.currentFeedArticle;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _swipe(like: false);
      case LogicalKeyboardKey.arrowRight:
        _swipe(like: true);
      case LogicalKeyboardKey.arrowUp:
        _sendToWai();
      case LogicalKeyboardKey.space:
        if (news != null) _openDetail(news);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _focusNode.requestFocus,
        child: ListenableBuilder(
          listenable: _state,
          builder: (context, _) => SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(40, 32, 40, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1320),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildDeckColumn()),
                    const SizedBox(width: 32),
                    SizedBox(width: 340, child: _SidePanel(state: _state)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// When no cards are left: error, loading or "that's all".
  Widget _emptyDeck() {
    if (_state.feedError != null) {
      return ErrorView(error: _state.feedError!, onRetry: _state.loadMoreFeed);
    }
    if (_state.feedLoading || _state.feedHasMore) {
      return const LoadingView(message: 'Loading stories…');
    }
    return _EndCard(
      category: _state.feedCategory,
      onRestart: _state.rereadFeed,
    );
  }

  Widget _buildDeckColumn() {
    final deck = _state.deck;
    final current = deck.firstOrNull;
    final total = _state.feedFor(_state.feedCategory).length;
    final done = total - deck.length;

    return Column(
      children: [
        _DeckHeader(
          category: _state.feedCategory,
          left: deck.length,
          total: total,
          loading: _state.feedHasMore,
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: _cardWidth + 40,
          height: _cardHeight + 24,
          child: current == null
              ? _emptyDeck()
              : Stack(
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.none,
                  children: [
                    // Cards behind (deck view).
                    for (var depth = 2; depth >= 1; depth--)
                      if (depth < deck.length) _backCard(deck[depth], depth),
                    _frontCard(current, done, total),
                  ],
                ),
        ),
        const SizedBox(height: 28),
        _ActionBar(
          enabled: current != null,
          onDislike: () => _swipe(like: false),
          onWai: _state.isLive ? _sendToWai : null,
          onLike: () => _swipe(like: true),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.swipe_rounded,
              size: 16,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            Text(
              'Drag the card or use ← → to react',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _backCard(Article news, int depth) {
    final card = RepaintBoundary(
      child: IgnorePointer(child: _NewsSwipeCard(news: news)),
    );
    Widget place(double d) => Positioned(
      top: 12.0 * d,
      child: Transform.scale(
        scale: 1 - 0.05 * d,
        alignment: Alignment.topCenter,
        child: Opacity(opacity: (1 - 0.3 * d).clamp(0.0, 1.0), child: card),
      ),
    );
    if (depth != 1) return place(depth.toDouble());
    // As the front card is dragged, the card right behind it moves forward.
    return ValueListenableBuilder<double>(
      valueListenable: _dx,
      builder: (context, dx, _) =>
          place(depth - (dx.abs() / _swipeThreshold).clamp(0.0, 1.0)),
    );
  }

  Widget _frontCard(Article news, int index, int total) {
    return Positioned(
      top: 0,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          onHorizontalDragUpdate: (d) {
            if (_busy) return;
            _anim.stop();
            _dx.value += d.delta.dx;
          },
          onHorizontalDragEnd: _busy ? null : _onDragEnd,
          onTap: () => _openDetail(news),
          child: ValueListenableBuilder<double>(
            valueListenable: _dx,
            // The card's content is built once; dragging only changes its position.
            child: RepaintBoundary(
              child: _NewsSwipeCard(
                news: news,
                position: '${index + 1}/$total',
                drag: _dx,
              ),
            ),
            builder: (context, dx, card) => Transform.translate(
              offset: Offset(dx, dx.abs() * 0.06),
              child: Transform.rotate(
                angle: dx / 1400 * math.pi / 4,
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Kart
// ---------------------------------------------------------------------------
class _NewsSwipeCard extends StatelessWidget {
  const _NewsSwipeCard({required this.news, this.position, this.drag});

  final Article news;
  final String? position;

  /// The front card's offset; the LIKE / NOPE stamp appears from it.
  final ValueListenable<double>? drag;

  @override
  Widget build(BuildContext context) {
    final reasons = AppState.instance.reasonsFor(news);
    return Container(
      width: _WebFeedPageState._cardWidth,
      height: _WebFeedPageState._cardHeight,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 290,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NewsImage(news.image),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.center,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), AppColors.surface],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      top: 18,
                      child: Row(
                        children: [
                          _GlassPill(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: AppColors.mint,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                [
                                  news.category,
                                  news.timeAgo,
                                ].where((s) => s.isNotEmpty).join(' · '),
                              ),
                            ],
                          ),
                          if (matchScore(news) case final score?) ...[
                            const SizedBox(width: 8),
                            MatchBadge(score, fontSize: 13),
                          ],
                        ],
                      ),
                    ),
                    if (position != null)
                      Positioned(
                        right: 18,
                        top: 18,
                        child: _GlassPill(
                          children: [
                            const Icon(
                              Icons.bolt_rounded,
                              size: 15,
                              color: AppColors.accentLight,
                            ),
                            const SizedBox(width: 4),
                            Text(position!),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(30, 6, 30, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // "Why this story": makes personalization visible.
                      if (reasons.isNotEmpty) ...[
                        Text(
                          'Because you follow ${reasons.join(' · ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            color: AppColors.mint,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        news.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.playfairDisplay(
                          color: AppColors.textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        news.summary,
                        maxLines: reasons.isEmpty ? 4 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.sourceSerif4(
                          color: AppColors.textBody,
                          fontSize: 16.5,
                          height: 1.6,
                        ),
                      ),
                      const Spacer(),
                      if (news.hasAlsoPublished) ...[
                        AlsoPublishedLine(news),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            news.readMinutes == null
                                ? 'Tap for the full story'
                                : '${news.readMinutes} min read',
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                          const Spacer(),
                          FactCheckBadge(news),
                          const SizedBox(width: 10),
                          Text(
                            news.source,
                            style: GoogleFonts.inter(
                              color: AppColors.textBody,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (drag != null)
            Positioned.fill(
              child: ValueListenableBuilder<double>(
                valueListenable: drag!,
                builder: (context, dx, _) {
                  final t = _WebFeedPageState._swipeThreshold;
                  if (dx > 0) {
                    return _Stamp(
                      label: 'LIKE',
                      color: AppColors.like,
                      opacity: (dx / t).clamp(0.0, 1.0),
                      alignment: Alignment.topLeft,
                      angle: -0.2,
                    );
                  }
                  if (dx < 0) {
                    return _Stamp(
                      label: 'NOPE',
                      color: AppColors.dislike,
                      opacity: (-dx / t).clamp(0.0, 1.0),
                      alignment: Alignment.topRight,
                      angle: 0.2,
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xD9111110),
        borderRadius: BorderRadius.circular(16),
      ),
      child: DefaultTextStyle(
        style: GoogleFonts.inter(
          color: AppColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp({
    required this.label,
    required this.color,
    required this.opacity,
    required this.alignment,
    required this.angle,
  });

  final String label;
  final Color color;
  final double opacity;
  final Alignment alignment;
  final double angle;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        color: color.withValues(alpha: 0.10 * opacity),
        padding: const EdgeInsets.all(40),
        alignment: alignment,
        child: Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: angle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: GoogleFonts.inter(
                  color: color,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Above the cards: the open tab and how many stories are left.
class _DeckHeader extends StatelessWidget {
  const _DeckHeader({
    required this.category,
    required this.left,
    required this.total,
    required this.loading,
  });

  final String? category;
  final int left;
  final int total;

  /// The rest of the feed is still loading; the counts are not final yet.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final String count;
    if (loading && total == 0) {
      count = 'Counting stories…';
    } else if (left == 0) {
      count = 'All $total read';
    } else {
      count = '$left unread of $total';
    }
    return SizedBox(
      width: _WebFeedPageState._cardWidth,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            category ?? 'All topics',
            style: GoogleFonts.playfairDisplay(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            count,
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndCard extends StatelessWidget {
  const _EndCard({required this.category, required this.onRestart});

  /// The open tab; `null` = all categories.
  final String? category;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: _WebFeedPageState._cardWidth,
        height: _WebFeedPageState._cardHeight,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.task_alt_rounded, size: 56, color: AppColors.mint),
            const SizedBox(height: 20),
            Text(
              "You're all caught up!",
              style: GoogleFonts.playfairDisplay(
                color: AppColors.textPrimary,
                fontSize: 30,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              category == null
                  ? "You've read every story in your Feed. New stories will "
                        'show up here as they arrive.'
                  : "You've read every $category story. New ones will show "
                        'up here as they arrive.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: AppColors.textBody,
                fontSize: 14.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            WebButton(
              label: 'Show them again',
              icon: Icons.replay_rounded,
              onTap: onRestart,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dislike / WAI / Like buttons
// ---------------------------------------------------------------------------
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.enabled,
    required this.onDislike,
    required this.onWai,
    required this.onLike,
  });

  final bool enabled;
  final VoidCallback onDislike;

  /// `null` hides the WAI button (offline sessions have no WAI).
  final VoidCallback? onWai;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RoundAction(
              icon: Icons.thumb_down_alt_outlined,
              label: 'Dislike',
              shortcut: '←',
              color: AppColors.dislike,
              size: 64,
              onTap: onDislike,
            ),
            if (onWai != null) ...[
              const SizedBox(width: 56),
              _RoundAction(
                icon: Icons.forum_outlined,
                label: 'Send to WAI',
                shortcut: '↑',
                color: AppColors.accentLight,
                size: 84,
                primary: true,
                onTap: onWai!,
              ),
            ],
            const SizedBox(width: 56),
            _RoundAction(
              icon: Icons.thumb_up_alt_outlined,
              label: 'Like',
              shortcut: '→',
              color: AppColors.like,
              size: 64,
              onTap: onLike,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.color,
    required this.size,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final String shortcut;
  final Color color;
  final double size;
  final VoidCallback onTap;

  /// The main action in the middle: brand-color outline.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label ($shortcut)',
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => Column(
          children: [
            AnimatedScale(
              duration: const Duration(milliseconds: 150),
              scale: hovered ? 1.08 : 1,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceAlt,
                  border: Border.all(
                    color: primary || hovered
                        ? color.withValues(alpha: hovered ? 0.9 : 0.6)
                        : AppColors.border,
                    width: primary ? 1.5 : 1,
                  ),
                ),
                child: Icon(icon, color: color, size: size * 0.4),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: GoogleFonts.inter(
                color: primary ? AppColors.accentLight : AppColors.textBody,
                fontSize: 13,
                fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Right panel: session, up next, shortcuts
// ---------------------------------------------------------------------------
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final deck = state.deck;
    final total = state.feedFor(state.feedCategory).length;
    final seen = total - deck.length;
    final upcoming = deck.skip(1).take(4).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FeedSourcePanel(state: state),
        const SizedBox(height: 20),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OverlineLabel('This session'),
              const SizedBox(height: 16),
              Row(
                children: [
                  _Stat(
                    value: '${state.sessionLikes}',
                    label: 'Liked',
                    color: AppColors.like,
                  ),
                  _Stat(
                    value: '${state.sessionDislikes}',
                    label: 'Disliked',
                    color: AppColors.dislike,
                  ),
                  _Stat(
                    value: '${deck.length}',
                    label: 'Left',
                    color: AppColors.accentLight,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : seen / total,
                  minHeight: 6,
                  color: AppColors.accentLight,
                  backgroundColor: AppColors.barInactive,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OverlineLabel('Up next'),
              const SizedBox(height: 14),
              if (upcoming.isEmpty)
                Text(
                  'Nothing else in the queue.',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                )
              else
                for (final n in upcoming)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: NewsListTile(n, thumbSize: 52, showBookmark: false),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OverlineLabel('Keyboard shortcuts'),
              const SizedBox(height: 14),
              const _Shortcut(keyLabel: '←', label: 'Dislike (hides it)'),
              const _Shortcut(keyLabel: '→', label: 'Like'),
              if (AppState.instance.isLive)
                const _Shortcut(keyLabel: '↑', label: 'Send to WAI'),
              const _Shortcut(keyLabel: 'Space', label: 'Story details'),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the feed is ranked by: personal (interests), the date-ordered
/// fallback or the general feed.
class _FeedSourcePanel extends StatelessWidget {
  const _FeedSourcePanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final personal = state.feedIsPersonal && !state.feedIsFallback;
    final String title;
    final String body;
    if (personal) {
      title = 'Personalized for you';
      body =
          'Ranked by your topics, categories, the stories you like and '
          'freshness. Likes add their topics to your Feed; dislikes hide '
          'a story and steer you away from similar ones.';
    } else if (state.feedIsPersonal) {
      title = 'Latest stories';
      body = 'Pick your interests to get a Feed ranked for you.';
    } else {
      title = 'Latest stories';
      body = state.hasServerUser
          ? 'Loading your personalized Feed…'
          : 'Showing everyone the newest stories.';
    }

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                personal ? Icons.auto_awesome_rounded : Icons.schedule_rounded,
                size: 17,
                color: personal ? AppColors.mint : AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OverlineLabel(
                  title,
                  color: personal ? AppColors.mint : AppColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: GoogleFonts.inter(
              color: AppColors.textBody,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (state.interests.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final i in state.interests)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: categoryColor(i).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      i,
                      style: GoogleFonts.inter(
                        color: categoryColor(i),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (state.hasServerUser) ...[
            const SizedBox(height: 14),
            LinkButton(
              state.interests.isEmpty ? 'Pick interests' : 'Edit interests',
              onTap: () => state.goTo(AppState.navProfile),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: GoogleFonts.playfairDisplay(
              color: color,
              fontSize: 30,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.keyLabel, required this.label});

  final String keyLabel;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 34),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              keyLabel,
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: GoogleFonts.inter(color: AppColors.textBody, fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}
