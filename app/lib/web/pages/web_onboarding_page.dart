import 'dart:math' as math;

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
import '../widgets/interest_form.dart';
import '../widgets/tavily_terminal.dart';
import '../widgets/web_ui.dart';

/// First visit: a personal feed in 60 seconds.
///
/// 1. Pick: categories and topics from `GET /api/taxonomy`, saved with
///    `PUT /api/users/{id}/preferences`.
/// 2. Taste check: swipe 8 real stories from the chosen categories; each
///    answer updates the interest vector at once via `POST /interactions`.
/// 3. Your feed is ready: the feed ranked with the updated profile, a
///    60-second brief and "why this story" reasons; topics with few stories
///    are fetched and stored on the server (shown as "being collected").
class WebOnboardingPage extends StatelessWidget {
  const WebOnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      backgroundColor: AppColors.background,
      // Tavily terminal on the right: Map and Crawl stream here when a site is added.
      body: Row(
        children: [
          Expanded(child: _body(state)),
          const TavilyDock(),
        ],
      ),
    );
  }

  Widget _body(AppState state) {
    return SmoothScroll(
      builder: (context, scroll) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final step = state.onboardingStep ?? OnboardingStep.pick;
          return SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 56),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Header(state: state, step: step),
                    const SizedBox(height: 44),
                    switch (step) {
                      OnboardingStep.pick => _PickStep(state: state),
                      OnboardingStep.taste => _TasteStep(state: state),
                      OnboardingStep.reveal => _RevealStep(state: state),
                    },
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar and step indicator
// ---------------------------------------------------------------------------
class _Header extends StatelessWidget {
  const _Header({required this.state, required this.step});

  final AppState state;
  final OnboardingStep step;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const WofLogo(fontSize: 26),
        const SizedBox(width: 32),
        _StepIndicator(step: step),
        const Spacer(),
        const TavilyTerminalButton(),
        const SizedBox(width: 20),
        Text(
          'Signed in as ${state.user?.username ?? ''}',
          style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(width: 16),
        LinkButton('Log out', icon: Icons.logout_rounded, onTap: state.logout),
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final OnboardingStep step;

  static const _labels = {
    OnboardingStep.pick: 'Pick topics',
    OnboardingStep.taste: 'Taste check',
    OnboardingStep.reveal: 'Your feed',
  };

  @override
  Widget build(BuildContext context) {
    final steps = OnboardingStep.values;
    return Row(
      children: [
        for (final s in steps) ...[
          _dot(s, steps.indexOf(s) + 1),
          if (s != steps.last)
            Container(
              width: 28,
              height: 1.5,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: s.index < step.index
                  ? AppColors.mint
                  : AppColors.barInactive,
            ),
        ],
      ],
    );
  }

  Widget _dot(OnboardingStep s, int number) {
    final done = s.index < step.index;
    final active = s == step;
    final color = done || active ? AppColors.mint : AppColors.textMuted;
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? AppColors.mint : Colors.transparent,
            border: Border.all(color: color, width: 1.5),
          ),
          child: done
              ? const Icon(Icons.check_rounded, size: 13, color: AppColors.mint)
              : Text(
                  '$number',
                  style: GoogleFonts.inter(
                    color: active ? AppColors.background : color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Text(
          _labels[s]!,
          style: GoogleFonts.inter(
            color: active ? AppColors.textPrimary : AppColors.textMuted,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({
    required this.overline,
    required this.title,
    required this.subtitle,
  });

  final String overline;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OverlineLabel(overline, color: AppColors.mint),
        const SizedBox(height: 12),
        Text(
          title,
          style: GoogleFonts.playfairDisplay(
            color: AppColors.textPrimary,
            fontSize: 40,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Text(
            subtitle,
            style: GoogleFonts.inter(
              color: AppColors.textBody,
              fontSize: 15,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Pick
// ---------------------------------------------------------------------------
class _PickStep extends StatelessWidget {
  const _PickStep({required this.state});

  final AppState state;

  /// Picking is split into three screens: categories → topics and "+" follows → sentence.
  static const _titles = [
    _StepTitle(
      overline: 'Step 1 of 3 · Categories',
      title: 'What do you want to read about?',
      subtitle:
          'Pick one or more areas. Your Feed shows stories from the '
          'categories you pick.',
    ),
    _StepTitle(
      overline: 'Step 1 of 3 · Topics',
      title: 'Narrow it down',
      subtitle:
          'Topics decide which stories come first. You can also follow a '
          'company, product or person, or a site. All of these are optional.',
    ),
    _StepTitle(
      overline: 'Step 1 of 3 · Your why',
      title: 'What should your feed help you with?',
      subtitle:
          'Optional. One sentence, in any language. Stories closer to it '
          'rank higher. Next, a quick taste check tunes your Feed.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return InterestForm(
      submitLabel: 'Continue',
      stepped: true,
      headerBuilder: (step) => _titles[step],
      initialMacros: state.interests,
      initialMicros: state.interestTags,
      initialFollows: state.follows,
      initialContext: state.interestContext ?? '',
      onSubmit: (macros, micros, follows, why) => state.submitOnboardingPicks(
        macroTags: macros,
        microTags: micros,
        follows: follows,
        context: why,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Taste check
// ---------------------------------------------------------------------------
class _TasteStep extends StatefulWidget {
  const _TasteStep({required this.state});

  final AppState state;

  @override
  State<_TasteStep> createState() => _TasteStepState();
}

class _TasteStepState extends State<_TasteStep> {
  static const _threshold = 120.0;

  final _focus = FocusNode();
  double _dx = 0;
  bool _dragging = false;

  AppState get _state => widget.state;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _answer({required bool like}) {
    final card = _state.currentTasteCard;
    if (card == null) return;
    setState(() => _dx = 0);
    _state.tasteReact(card, like: like);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _answer(like: true);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _answer(like: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final card = _state.currentTasteCard;
    if (_state.tasteLoading || card == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 60),
        child: LoadingView(message: 'Picking a few stories for you…'),
      );
    }
    final total = _state.tasteDeck.length;
    final index = _state.tasteIndex;

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepTitle(
            overline: 'Step 2 of 3 · about 30 seconds',
            title: 'Would you read these?',
            subtitle:
                'Swipe right on stories you would read, left on ones you '
                'would not. Every answer tunes your Feed right away.',
          ),
          const SizedBox(height: 32),
          Center(
            child: SizedBox(
              width: 560,
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        '${index + 1} / $total',
                        style: GoogleFonts.inter(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: index / total,
                            minHeight: 5,
                            color: AppColors.mint,
                            backgroundColor: AppColors.barInactive,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      LinkButton(
                        'Skip',
                        onTap: () => _state.finishTasteCheck(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  GestureDetector(
                    onHorizontalDragStart: (_) =>
                        setState(() => _dragging = true),
                    onHorizontalDragUpdate: (d) =>
                        setState(() => _dx += d.delta.dx),
                    onHorizontalDragEnd: (_) {
                      _dragging = false;
                      if (_dx.abs() > _threshold) {
                        _answer(like: _dx > 0);
                      } else {
                        setState(() => _dx = 0);
                      }
                    },
                    child: AnimatedContainer(
                      duration: Duration(milliseconds: _dragging ? 0 : 180),
                      transform: Matrix4.translationValues(_dx, 0, 0)
                        ..rotateZ(_dx / 1600 * math.pi / 4),
                      transformAlignment: Alignment.bottomCenter,
                      child: _TasteCard(
                        key: ValueKey(card.id),
                        article: card,
                        lean: (_dx / _threshold).clamp(-1.0, 1.0),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: WebButton(
                          label: 'Not for me',
                          icon: Icons.thumb_down_alt_outlined,
                          primary: false,
                          color: AppColors.dislike,
                          onTap: () => _answer(like: false),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: WebButton(
                          label: 'I\'d read this',
                          icon: Icons.thumb_up_alt_outlined,
                          onTap: () => _answer(like: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Tip: use ← and → on your keyboard.',
                    style: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TasteCard extends StatelessWidget {
  const _TasteCard({super.key, required this.article, this.lean = 0});

  final Article article;

  /// -1 (left, dislike) … 1 (right, like).
  final double lean;

  @override
  Widget build(BuildContext context) {
    final edge = lean > 0
        ? AppColors.like.withValues(alpha: lean)
        : lean < 0
        ? AppColors.dislike.withValues(alpha: -lean)
        : AppColors.border;
    final reasons = AppState.instance.reasonsFor(article);
    return Container(
      height: 430,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: edge, width: lean == 0 ? 1 : 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 190,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                NewsImage(article.image),
                Positioned(
                  left: 14,
                  top: 14,
                  child: CategoryBadge(article.category),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.playfairDisplay(
                      color: AppColors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Text(
                      article.summary,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sourceSerif4(
                        color: AppColors.textBody,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          sourceLine(article),
                          style: GoogleFonts.inter(
                            color: AppColors.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      if (reasons.isNotEmpty)
                        Flexible(
                          child: Text(
                            'Matches ${reasons.join(' · ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              color: AppColors.mint,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
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
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Your feed is ready
// ---------------------------------------------------------------------------
class _RevealStep extends StatelessWidget {
  const _RevealStep({required this.state});

  final AppState state;

  static const _picks = 5;
  static const _briefItems = 4;

  @override
  Widget build(BuildContext context) {
    if (state.revealLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 60),
        child: LoadingView(
          message: 'Building your Feed from your picks…',
          hint: 'Usually a few seconds.',
        ),
      );
    }
    final picks = state.revealPicks.take(_picks).toList();
    final name = state.user?.username ?? '';
    final cats = state.interests.length;
    final topics = state.interestTags.length;
    final likes = state.tasteLikes;
    final basis = [
      '$cats ${cats == 1 ? 'category' : 'categories'}',
      if (topics > 0) '$topics ${topics == 1 ? 'topic' : 'topics'}',
      if (likes > 0) '$likes ${likes == 1 ? 'story' : 'stories'} you liked',
    ];
    final basisText = basis.length == 1
        ? basis.single
        : '${basis.sublist(0, basis.length - 1).join(', ')} and ${basis.last}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepTitle(
          overline: 'Step 3 of 3 · your feed is ready',
          title: 'Here is your Feed, $name',
          subtitle: 'Built from $basisText.',
        ),
        const SizedBox(height: 32),
        if (picks.isEmpty)
          const PanelCard(
            child: EmptyView(
              icon: Icons.hourglass_empty_rounded,
              title: 'Your stories are on their way',
              message:
                  'We do not have stories for these topics yet. Fresh ones '
                  'will appear in your Feed as they arrive.',
            ),
          )
        else
          LayoutBuilder(
            builder: (context, c) {
              final brief = _BriefPanel(
                articles: picks.take(_briefItems).toList(),
              );
              final list = _PicksPanel(state: state, articles: picks);
              if (c.maxWidth < 900) {
                return Column(
                  children: [brief, const SizedBox(height: 20), list],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: brief),
                  const SizedBox(width: 24),
                  Expanded(flex: 7, child: list),
                ],
              );
            },
          ),
        if (state.collectingTopics.isNotEmpty) ...[
          const SizedBox(height: 24),
          _CollectingNote(topics: state.collectingTopics),
        ],
        const SizedBox(height: 32),
        Row(
          children: [
            WebButton(
              label: 'Open my Feed',
              icon: Icons.arrow_forward_rounded,
              onTap: state.completeOnboarding,
            ),
            const SizedBox(width: 20),
            LinkButton(
              'Go to Home',
              onTap: () => state.completeOnboarding(openTab: AppState.navHome),
            ),
          ],
        ),
      ],
    );
  }
}

/// Two-sentence summaries of the first stories (the server's `tldr` field);
/// opens instantly without waiting for AI.
class _BriefPanel extends StatelessWidget {
  const _BriefPanel({required this.articles});

  final List<Article> articles;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 20, color: AppColors.mint),
              const SizedBox(width: 8),
              Text(
                'Your 60-second brief',
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          for (final a in articles)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Hoverable(
                onTap: () => showArticleDialog(context, a),
                builder: (context, hovered) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 8, right: 12),
                      decoration: BoxDecoration(
                        color: categoryColor(a.category),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.summary,
                            style: GoogleFonts.sourceSerif4(
                              color: hovered
                                  ? AppColors.textPrimary
                                  : AppColors.textBody,
                              fontSize: 15,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${a.category} · ${a.source}',
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12,
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
      ),
    );
  }
}

/// Best matching stories, with match score and a "why this story" reason.
class _PicksPanel extends StatelessWidget {
  const _PicksPanel({required this.state, required this.articles});

  final AppState state;
  final List<Article> articles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const OverlineLabel('Top picks for you'),
        const SizedBox(height: 14),
        for (final a in articles)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PickTile(article: a, reasons: state.reasonsFor(a)),
          ),
      ],
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({required this.article, required this.reasons});

  final Article article;
  final List<String> reasons;

  @override
  Widget build(BuildContext context) {
    final score = matchScore(article);
    return Hoverable(
      onTap: () => showArticleDialog(context, article),
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
              child: NewsImage(article.image, width: 64, height: 64),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.playfairDisplay(
                      color: AppColors.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    reasons.isEmpty
                        ? sourceLine(article)
                        : 'Because you follow ${reasons.join(' · ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      color: reasons.isEmpty
                          ? AppColors.textMuted
                          : AppColors.mint,
                      fontSize: 12.5,
                      fontWeight: reasons.isEmpty
                          ? FontWeight.w400
                          : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (score != null) ...[
              const SizedBox(width: 12),
              MatchBadge(score),
            ],
          ],
        ),
      ),
    );
  }
}

/// Topics with few stories in the feed yet: the server started fetching and
/// storing them when the interests were saved; they reach the feed within a
/// few minutes.
class _CollectingNote extends StatelessWidget {
  const _CollectingNote({required this.topics});

  final List<String> topics;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.mint,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Collecting fresh stories on '),
                  TextSpan(
                    text: topics.join(', '),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const TextSpan(
                    text:
                        '. They will show up in your Feed within a few '
                        'minutes.',
                  ),
                ],
              ),
              style: GoogleFonts.inter(
                color: AppColors.textBody,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
