import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/api_models.dart';
import '../models/article_ui.dart';
import '../theme/app_colors.dart';
import 'audio_bulletin_player.dart';
import 'common.dart';
import 'simple_markdown.dart';
import 'state_views.dart';

/// Home page cards. Mobile and web use the same cards; on the web [large]
/// picks the bigger sizes.

class _Card extends StatelessWidget {
  const _Card({required this.child, this.large = false});

  final Widget child;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(large ? 26 : 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(large ? 26 : 22),
        border: large ? Border.all(color: AppColors.border) : null,
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Headline card (image + title + summary + audio bulletin)
// ---------------------------------------------------------------------------
/// Shows a single story by default ("TOP STORY"). The home page "Latest
/// developments" card uses the same layout: [label], [title] and [summary]
/// get the headline and paragraph the server wrote, and the image comes from
/// [article] (the top story).
class DailySummaryCard extends StatelessWidget {
  const DailySummaryCard({
    super.key,
    required this.article,
    this.large = false,
    this.horizontal = false,
    this.onTap,
    this.label = 'TOP STORY',
    this.title,
    this.summary,
    this.summaryMaxLines = 3,
    this.caption,
    this.onAsk,
  });

  final Article article;

  /// Label above the card.
  final String label;

  /// If not given, the story's title and summary.
  final String? title;
  final String? summary;
  final int summaryMaxLines;

  /// Text over the image; if not given, category · source · time.
  final String? caption;

  /// If set, an "Ask WAI" button shows under the summary.
  final VoidCallback? onAsk;

  /// Desktop sizes.
  final bool large;

  /// Image on the left, headline and player on the right.
  final bool horizontal;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final header = Row(
      children: [
        const AccentDot(),
        const SizedBox(width: 7),
        Text(
          label,
          style: GoogleFonts.inter(
            color: AppColors.mint,
            fontSize: large ? 12 : 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const Spacer(),
        Icon(
          Icons.headphones_outlined,
          size: large ? 18 : 16,
          color: AppColors.textBody,
        ),
        const SizedBox(width: 5),
        Text(
          'Audio Bulletin',
          style: GoogleFonts.inter(
            color: AppColors.textBody,
            fontSize: large ? 14 : 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    final image = ClipRRect(
      borderRadius: BorderRadius.circular(large ? 18 : 16),
      child: AspectRatio(
        aspectRatio: large ? 16 / 9 : 1.2,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NewsImage(article.image),
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xD9111110),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  caption ??
                      [
                        article.category,
                        article.source,
                        article.timeAgo,
                      ].where((s) => s.isNotEmpty).join(' · '),
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final titleText = Text(
      title ?? article.title,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.playfairDisplay(
        color: AppColors.textPrimary,
        fontSize: large ? (horizontal ? 28 : 26) : 20,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
    );

    final summaryText = Text(
      summary ?? article.summary,
      maxLines: summaryMaxLines,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.sourceSerif4(
        color: AppColors.textBody,
        fontSize: large ? 16 : 14.5,
        height: 1.55,
      ),
    );

    Widget tappable(Widget child) => onTap == null
        ? child
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: onTap, child: child),
          );

    if (horizontal) {
      return _Card(
        large: large,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 11, child: tappable(image)),
                const SizedBox(width: 28),
                Expanded(
                  flex: 9,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      tappable(titleText),
                      const SizedBox(height: 12),
                      summaryText,
                      if (onAsk != null) ...[
                        const SizedBox(height: 14),
                        _AskWaiButton(onTap: onAsk!),
                      ],
                      const SizedBox(height: 20),
                      const AudioBulletinPlayer(),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return _Card(
      large: large,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          SizedBox(height: large ? 16 : 12),
          tappable(image),
          SizedBox(height: large ? 22 : 18),
          tappable(titleText),
          SizedBox(height: large ? 10 : 8),
          summaryText,
          if (onAsk != null) ...[
            SizedBox(height: large ? 14 : 10),
            _AskWaiButton(onTap: onAsk!),
          ],
          SizedBox(height: large ? 18 : 14),
          const AudioBulletinPlayer(),
        ],
      ),
    );
  }
}

/// "Ask WAI about this": opens a WAI chat about the card's content.
class _AskWaiButton extends StatelessWidget {
  const _AskWaiButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: AppColors.accentLight,
              ),
              const SizedBox(width: 8),
              Text(
                'Ask WAI about this',
                style: GoogleFonts.inter(
                  color: AppColors.accentLight,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cross-source comparison brief (synthesize)
// ---------------------------------------------------------------------------
class WrittenSummaryCard extends StatelessWidget {
  const WrittenSummaryCard({
    super.key,
    required this.sources,
    this.brief,
    this.loading = false,
    this.error,
    this.onRetry,
    this.onReadMore,
    this.large = false,
    this.previewHeight,
    this.title = 'Cross-Source Brief',
    this.loadingMessage = "WAI is comparing today's top stories…",
    this.loadingHint = 'This can take up to 30 seconds.',
  });

  /// Card title (in the personal brief e.g. "Daily Brief · AI").
  final String title;
  final String loadingMessage;
  final String loadingHint;

  /// The compared stories.
  final List<Article> sources;
  final String? brief;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  /// If set, the brief is shown shortened and "Read more" calls this.
  final VoidCallback? onReadMore;
  final bool large;

  /// Height of the shortened preview.
  final double? previewHeight;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (error != null) {
      body = ErrorView(error: error!, onRetry: onRetry, compact: true);
    } else if (loading || brief == null) {
      body = LoadingView(
        message: loadingMessage,
        hint: loadingHint,
        padding: 36,
      );
    } else if (onReadMore != null) {
      body = SizedBox(
        height: previewHeight ?? (large ? 420 : 320),
        child: ClipRect(
          child: ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.78, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: SimpleMarkdown(brief!, fontSize: large ? 16 : 15),
            ),
          ),
        ),
      );
    } else {
      body = SimpleMarkdown(brief!, fontSize: large ? 16 : 15);
    }

    return _Card(
      large: large,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: large ? 22 : 20,
                color: AppColors.textBody,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    style: GoogleFonts.playfairDisplay(
                      color: AppColors.textPrimary,
                      fontSize: large ? 22 : 19,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (sources.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${sources.length} source${sources.length == 1 ? '' : 's'}',
                  style: GoogleFonts.inter(
                    color: AppColors.textBody,
                    fontSize: large ? 12 : 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in sources)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.quoteBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    a.source,
                    style: GoogleFonts.inter(
                      color: AppColors.accentLight,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: large ? 18 : 14),
          body,
          if (brief != null && error == null && onReadMore != null) ...[
            SizedBox(height: large ? 14 : 10),
            Align(
              alignment: Alignment.centerRight,
              child: InkWell(
                onTap: onReadMore,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Read full brief',
                        style: GoogleFonts.inter(
                          color: AppColors.accentLight,
                          fontSize: large ? 15 : 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: AppColors.accentLight,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Story summary list (the home page "Daily Brief")
// ---------------------------------------------------------------------------
/// The stories the "Latest developments" card was written from, each with
/// its own short summary (not rewritten per user).
class StorySummariesCard extends StatelessWidget {
  const StorySummariesCard({
    super.key,
    required this.articles,
    this.title = 'Daily Brief',
    this.subtitle = 'The stories behind your latest developments',
    this.loading = false,
    this.error,
    this.onRetry,
    this.onOpen,
    this.large = false,
    this.height,
  });

  final List<Article> articles;
  final String title;
  final String subtitle;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final ValueChanged<Article>? onOpen;
  final bool large;

  /// The list scrolls at this height; if not given, everything is shown.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (error != null && articles.isEmpty) {
      body = ErrorView(error: error!, onRetry: onRetry, compact: true);
    } else if (articles.isEmpty) {
      body = LoadingView(
        message: loading
            ? 'WAI is picking the stories that matter to you…'
            : 'No stories yet.',
        padding: 36,
      );
    } else {
      final list = ListView.separated(
        padding: EdgeInsets.zero,
        shrinkWrap: height == null,
        physics: height == null ? const NeverScrollableScrollPhysics() : null,
        itemCount: articles.length,
        separatorBuilder: (_, _) =>
            const Divider(color: AppColors.border, height: 28),
        itemBuilder: (context, i) => _StorySummary(
          article: articles[i],
          large: large,
          onTap: onOpen == null ? null : () => onOpen!(articles[i]),
        ),
      );
      body = height == null ? list : SizedBox(height: height, child: list);
    }

    final count = articles.length;
    return _Card(
      large: large,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: large ? 22 : 20,
                color: AppColors.textBody,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: large ? 22 : 19,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (count > 0)
                Text(
                  count == 1 ? '1 story' : '$count stories',
                  style: GoogleFonts.inter(
                    color: AppColors.textBody,
                    fontSize: large ? 12 : 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: large ? 13 : 12,
            ),
          ),
          SizedBox(height: large ? 18 : 14),
          body,
        ],
      ),
    );
  }
}

class _StorySummary extends StatelessWidget {
  const _StorySummary({required this.article, this.large = false, this.onTap});

  final Article article;
  final bool large;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            article.source,
            article.timeAgo,
          ].where((s) => s.isNotEmpty).join(' · '),
          style: GoogleFonts.inter(
            color: AppColors.accentLight,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          article.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            color: AppColors.textPrimary,
            fontSize: large ? 15 : 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        if (article.summary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            article.summary,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.sourceSerif4(
              color: AppColors.textBody,
              fontSize: large ? 14.5 : 13.5,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
    if (onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: content),
    );
  }
}
