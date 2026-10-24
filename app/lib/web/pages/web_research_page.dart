import 'package:flutter/material.dart';
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

/// Research page: every story the user started Tavily Research on, running
/// or finished, so a report is never lost with the story it came from.
class WebResearchPage extends StatefulWidget {
  const WebResearchPage({super.key});

  @override
  State<WebResearchPage> createState() => _WebResearchPageState();
}

class _WebResearchPageState extends State<WebResearchPage> {
  final _state = AppState.instance;
  final _scroll = SmoothScrollController();
  late Future<void> _loading;

  @override
  void initState() {
    super.initState();
    _loading = _load();
  }

  /// Stories from earlier sessions are fetched, then each one's report or
  /// job status (spends no credits).
  Future<void> _load() async {
    final ids = _state.researchedIds;
    try {
      await _state.ensureArticles(ids);
    } on Exception {
      // Cards whose story could not load are skipped.
    }
    for (final id in ids) {
      final article = _state.articleById(id);
      if (article != null) _state.loadResearch(article);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snap) => ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          final articles = _state.researchedIds
              .map(_state.articleById)
              .whereType<Article>()
              .toList();
          if (articles.isEmpty) {
            if (snap.connectionState != ConnectionState.done &&
                _state.researchedIds.isNotEmpty) {
              return const LoadingView(message: 'Loading your research…');
            }
            return const EmptyView(
              icon: Icons.travel_explore_rounded,
              title: 'No research yet',
              message:
                  'Open a story and tap "Research deeper". Tavily reads many '
                  'sources and the cited report lands here.',
            );
          }
          return SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(40, 32, 40, 56),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionTitle('Your research'),
                    const SizedBox(height: 20),
                    for (final a in articles) ...[
                      _ResearchCard(article: a),
                      const SizedBox(height: 16),
                    ],
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

/// One story: image, title, the job's status and the report's opening lines.
/// Tapping opens the story with the full report.
class _ResearchCard extends StatelessWidget {
  const _ResearchCard({required this.article});

  final Article article;

  /// The report's first lines without Markdown marks, for the preview.
  static String _preview(String report) => report
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[#*_>`]|\[\d+\]'), '').trim())
      .where((l) => l.isNotEmpty)
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final running = state.isResearching(article.id);
    final report = state.researchFor(article.id);
    final error = state.researchError(article.id);

    final (IconData icon, Color color, String status) = running
        ? (Icons.autorenew_rounded, AppColors.accentLight, 'Researching…')
        : report != null
        ? (
            Icons.check_circle_rounded,
            AppColors.mint,
            'Report ready · ${report.sources.length} sources',
          )
        : error != null
        ? (Icons.error_outline_rounded, AppColors.dislike, error)
        : (
            Icons.refresh_rounded,
            AppColors.textMuted,
            'Not finished · open the story to try again',
          );

    return Hoverable(
      onTap: () => showArticleDialog(context, article),
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: hovered ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hovered ? AppColors.textMuted : AppColors.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 240, child: NewsImage(article.image)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (running)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.accentLight,
                              ),
                            )
                          else
                            Icon(icon, size: 16, color: color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              status,
                              style: GoogleFonts.inter(
                                color: color,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            sourceLine(article),
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        article.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.playfairDisplay(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        report != null
                            ? _preview(report.report!)
                            : running
                            ? 'Tavily is reading sources and writing a cited '
                                  'report. A notification comes when it is '
                                  'ready.'
                            : article.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.sourceSerif4(
                          color: AppColors.textBody,
                          fontSize: 14.5,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
