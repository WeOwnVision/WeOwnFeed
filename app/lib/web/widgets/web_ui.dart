import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../models/article_ui.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common.dart';
import 'article_dialog.dart';

/// Components shared by the web pages.

/// Clickable area that changes on mouse hover.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.onTap});

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _hovered),
      ),
    );
  }
}

/// Dark bordered panel.
class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

/// Section heading: a mint bar on the left, an optional action on the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 22,
          decoration: BoxDecoration(
            color: AppColors.mint,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: GoogleFonts.playfairDisplay(
            color: AppColors.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// Small upper-case label ("SETTINGS", "TAGS").
class OverlineLabel extends StatelessWidget {
  const OverlineLabel(this.text, {super.key, this.color = AppColors.textMuted});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: GoogleFonts.inter(
      color: color,
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
    ),
  );
}

/// Button that looks like a text link ("See all ›").
class LinkButton extends StatelessWidget {
  const LinkButton(this.label, {super.key, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: AppColors.accentLight),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: GoogleFonts.inter(
              color: hovered ? AppColors.textPrimary : AppColors.accentLight,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (icon == null)
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: hovered ? AppColors.textPrimary : AppColors.accentLight,
            ),
        ],
      ),
    );
  }
}

/// Badge color per category.
/// Categories are not told apart by color; one color, like newspaper section heads.
Color categoryColor(String category) => AppColors.textBody;

/// Category badge placed over an image.
class CategoryBadge extends StatelessWidget {
  const CategoryBadge(this.category, {super.key});

  final String category;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xD9111110),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        category.toUpperCase(),
        style: GoogleFonts.inter(
          color: AppColors.textPrimary,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Match score in the personal feed; hidden in the date-ordered (fallback)
/// feed because there the server gives everyone a fixed 50.
int? matchScore(Article a) =>
    AppState.instance.feedIsFallback ? null : a.personalScore;

/// "76% match" badge (over the image).
class MatchBadge extends StatelessWidget {
  const MatchBadge(this.score, {super.key, this.fontSize = 12});

  final int score;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          'How well this story fits your interests: topics, category, '
          'stories you liked and freshness',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xD9111110),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: fontSize + 2,
              color: AppColors.mint,
            ),
            const SizedBox(width: 5),
            Text(
              '$score% match',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Save button; reads its state from [AppState].
class BookmarkButton extends StatelessWidget {
  const BookmarkButton(this.news, {super.key, this.size = 20});

  final Article news;
  final double size;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final saved = state.isSaved(news.id);
        return Tooltip(
          message: saved ? 'Remove from saved' : 'Save',
          child: Hoverable(
            onTap: () => state.toggleSaved(news.id),
            builder: (context, hovered) => Icon(
              saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              size: size,
              color: saved
                  ? AppColors.accentLight
                  : (hovered ? AppColors.textPrimary : AppColors.textMuted),
            ),
          ),
        );
      },
    );
  }
}

/// Story card in a grid (Discover, Home).
class NewsGridCard extends StatelessWidget {
  const NewsGridCard(this.news, {super.key});

  final Article news;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: () => showArticleDialog(context, news),
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, hovered ? -4 : 0, 0),
        decoration: BoxDecoration(
          color: hovered ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hovered ? AppColors.textMuted : AppColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedScale(
                    duration: const Duration(milliseconds: 300),
                    scale: hovered ? 1.05 : 1.0,
                    child: NewsImage(news.image),
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: CategoryBadge(news.category),
                  ),
                  if (matchScore(news) case final score?)
                    Positioned(right: 12, top: 12, child: MatchBadge(score)),
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: FactCheckBadge(news, onImage: true),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 48,
                    child: Text(
                      news.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.playfairDisplay(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: Text(
                      news.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sourceSerif4(
                        color: AppColors.textBody,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          sourceLine(news),
                          style: GoogleFonts.inter(
                            color: AppColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      BookmarkButton(news, size: 19),
                    ],
                  ),
                  if (news.hasAlsoPublished) ...[
                    const SizedBox(height: 8),
                    AlsoPublishedLine(news),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal story row (Saved, Up next lists).
class NewsListTile extends StatelessWidget {
  const NewsListTile(
    this.news, {
    super.key,
    this.thumbSize = 72,
    this.showBookmark = true,
  });

  final Article news;
  final double thumbSize;
  final bool showBookmark;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: () => showArticleDialog(context, news),
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hovered ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: NewsImage(news.image, width: thumbSize, height: thumbSize),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      OverlineLabel(news.category, color: AppColors.mint),
                      const SizedBox(width: 8),
                      FactCheckBadge(news),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    news.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.playfairDisplay(
                      color: AppColors.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sourceLine(news),
                    style: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  if (news.hasAlsoPublished) ...[
                    const SizedBox(height: 4),
                    AlsoPublishedLine(news),
                  ],
                ],
              ),
            ),
            if (showBookmark) ...[
              const SizedBox(width: 10),
              BookmarkButton(news),
            ],
          ],
        ),
      ),
    );
  }
}

/// Pill-shaped choice button (tags, segments).
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.showCheck = false,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showCheck;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 12 : 16,
          vertical: dense ? 6 : 9,
        ),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentLight
              : (hovered ? AppColors.surfaceAlt : AppColors.surface),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accentLight : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected && showCheck) ...[
              const Icon(Icons.check_rounded, size: 15, color: onAccent),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                color: selected ? onAccent : AppColors.textBody,
                fontSize: dense ? 12.5 : 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text color on the brand-color background.
const onAccent = AppColors.onAccent;

/// Primary (filled) and secondary (outlined) web button.
class WebButton extends StatelessWidget {
  const WebButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = true,
    this.color,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool primary;

  /// Text color of the secondary button.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? onAccent : (color ?? AppColors.textPrimary);
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? (hovered ? AppColors.textPrimary : AppColors.accentLight)
              : (hovered ? AppColors.surfaceAlt : AppColors.surface),
          borderRadius: BorderRadius.circular(14),
          border: primary ? null : Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                color: fg,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Wired · 3 hr ago" (only the source if there is no date).
String sourceLine(Article a) =>
    [a.source, a.timeAgo].where((s) => s.isNotEmpty).join(' · ');

/// Greeting such as "Good morning · October 12".
String greetingLine([DateTime? now]) {
  final t = now ?? DateTime.now();
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final greeting = switch (t.hour) {
    >= 5 && < 12 => 'Good morning',
    >= 12 && < 18 => 'Good afternoon',
    _ => 'Good evening',
  };
  return '$greeting · ${months[t.month - 1]} ${t.day}';
}

String formatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// A short notice that slides in at the top of the screen, above dialogs,
/// and hides itself after [duration].
void showTopNotice(
  BuildContext context,
  String message, {
  IconData icon = Icons.info_outline_rounded,
  Duration duration = const Duration(seconds: 4),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TopNotice(
      message: message,
      icon: icon,
      duration: duration,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _TopNotice extends StatefulWidget {
  const _TopNotice({
    required this.message,
    required this.icon,
    required this.duration,
    required this.onDone,
  });

  final String message;
  final IconData icon;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_TopNotice> createState() => _TopNoticeState();
}

class _TopNoticeState extends State<_TopNotice>
    with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  @override
  void initState() {
    super.initState();
    _anim.forward();
    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _anim.reverse();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    // Below the activity bar, which also sits at the top.
    return Positioned(
      top: 110,
      left: 16,
      right: 16,
      child: SafeArea(
        child: Center(
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, -0.6),
                end: Offset.zero,
              ).animate(curve),
              child: Material(
                color: AppColors.surfaceAlt,
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, size: 20, color: AppColors.accentLight),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: GoogleFonts.inter(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fact Check badge. Shows only when the check has something to say:
/// a story with no outside evidence yet ("single_source") or one never
/// checked gets no badge, so the feed is not filled with doubt marks.
class FactCheckBadge extends StatelessWidget {
  const FactCheckBadge(this.article, {super.key, this.onImage = false});

  final Article article;

  /// Over a photo: a dark background keeps the text readable.
  final bool onImage;

  static const _looks = {
    'supported': (
      Icons.verified_rounded,
      'Supported',
      AppColors.supported,
      'Fact Check: an official source or 2+ independent sources back it, '
          'none contradict it.',
    ),
    'disputed': (
      Icons.balance_rounded,
      'Disputed',
      AppColors.contested,
      'Fact Check: some sources back it, others contradict it.',
    ),
    'contradicted': (
      Icons.report_outlined,
      'Contradicted',
      AppColors.contradicted,
      'Fact Check: outside sources contradict it and none independently '
          'back it.',
    ),
    'developing': (
      Icons.schedule_rounded,
      'Developing',
      AppColors.developing,
      'Fact Check: under 6 hours old and from one origin, too new to '
          'cross-check yet.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final look = _looks[state.factCheckFor(article)];
        if (look == null) return const SizedBox.shrink();
        final (icon, label, color, tip) = look;
        return Tooltip(
          message: tip,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: onImage
                  ? const Color(0xD9111110)
                  : color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.55)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: GoogleFonts.inter(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Also published by IGN, Kotaku and 5 more": other outlets that ran the
/// same story. Their copies are merged into this card (server `dedup.py`).
class AlsoPublishedLine extends StatelessWidget {
  const AlsoPublishedLine(this.article, {super.key});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final line = article.alsoPublishedLine;
    if (line.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.layers_outlined, size: 14, color: AppColors.mint),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              color: AppColors.mint,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (article.origins.isNotEmpty) ...[
          const SizedBox(width: 8),
          OriginsCount(article),
        ],
      ],
    );
  }
}

/// "7 outlets · 2 origins": copies that share a wire byline count once.
class OriginsCount extends StatelessWidget {
  const OriginsCount(this.article, {super.key});

  final Article article;

  @override
  Widget build(BuildContext context) {
    final outlets = article.alsoPublishedByCount + 1;
    final origins = article.origins.length;
    return Tooltip(
      message:
          'Outlets that reprint the same wire story count as one '
          'independent origin.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.mint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$outlets outlets · $origins ${origins == 1 ? 'origin' : 'origins'}',
          style: GoogleFonts.inter(
            color: AppColors.mint,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
