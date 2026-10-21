import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/api_models.dart';
import '../../models/article_ui.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/simple_markdown.dart';
import '../../widgets/smooth_scroll.dart';
import '../../widgets/state_views.dart';
import 'web_ui.dart';

/// Story details dialog: full text, source link and comments.
Future<void> showArticleDialog(BuildContext context, Article article) {
  // Opening a story's details counts as reading it (the menu's unread counts).
  AppState.instance.markRead(article.id);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (context) => _ArticleDialog(article: article),
  );
}

class _ArticleDialog extends StatefulWidget {
  const _ArticleDialog({required this.article});

  final Article article;

  @override
  State<_ArticleDialog> createState() => _ArticleDialogState();
}

class _ArticleDialogState extends State<_ArticleDialog> {
  final _state = AppState.instance;
  final _commentCtrl = TextEditingController();
  final _scroll = SmoothScrollController();
  final _askCtrl = TextEditingController();

  late Future<Article> _detail;
  late Future<List<ArticleComment>> _comments;
  final List<ArticleComment> _posted = [];
  String _selection = '';
  bool _posting = false;

  bool _inspecting = false;
  String? _inspectProgress;
  FactCheckResult? _factCheck;
  String? _inspectError;
  bool _asking = false;
  final List<Map<String, String>> _qaHistory = [];

  /// Tavily Research (below the evidence card, on request).
  ArticleResearch? _research;
  bool _researching = false;
  String? _researchError;
  Timer? _researchPoll;

  @override
  void initState() {
    super.initState();
    _factCheck = widget.article.factCheckCache;
    _loadDetail();
    _loadComments();
    _loadResearch();
  }

  /// Shows the saved Research report if there is one (spends no credits).
  Future<void> _loadResearch() async {
    try {
      final r = await _state.api.getResearch(widget.article.id);
      if (!mounted || r.status == 'none') return;
      setState(() => _research = r);
      if (r.isRunning) _pollResearch();
    } on ApiException {
      // Without a report the button shows.
    }
  }

  Future<void> _startResearch() async {
    if (_researching) return;
    setState(() {
      _researching = true;
      _researchError = null;
    });
    try {
      final r = await _state.api.startResearch(widget.article.id);
      if (!mounted) return;
      setState(() => _research = r);
      if (r.isRunning) {
        _pollResearch();
      } else if (!r.isCompleted) {
        setState(() => _researchError = 'Tavily Research could not finish.');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _researchError = e.userMessage);
    } finally {
      if (mounted && !(_research?.isRunning ?? false)) {
        setState(() => _researching = false);
      }
    }
  }

  /// If the server could not finish the report within 25 s, poll every 5 s
  /// (at most 3 min); each poll asks Tavily for the job status and spends no
  /// credits.
  void _pollResearch() {
    _researchPoll?.cancel();
    var tries = 0;
    _researching = true;
    _researchPoll = Timer.periodic(const Duration(seconds: 5), (t) async {
      tries++;
      try {
        final r = await _state.api.getResearch(widget.article.id);
        if (!mounted) return t.cancel();
        if (!r.isRunning || tries >= 36) {
          t.cancel();
          setState(() {
            _research = r;
            _researching = false;
            if (!r.isCompleted) {
              _researchError = 'Tavily Research could not finish.';
            }
          });
        }
      } on ApiException {
        // Bir sonraki denemede tekrar sorulur.
      }
    });
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _scroll.dispose();
    _askCtrl.dispose();
    _researchPoll?.cancel();
    super.dispose();
  }

  void _loadDetail() {
    _detail = _state.loadDetail(widget.article.id).then((art) {
      if (mounted && art.factCheckCache != null && _factCheck == null) {
        setState(() => _factCheck = art.factCheckCache);
      }
      return art;
    });
  }

  void _loadComments() {
    _posted.clear();
    _comments = _state.api.getComments(widget.article.id);
  }

  Future<void> _openOriginal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, webOnlyWindowName: '_blank');
  }

  Future<void> _postComment() async {
    final user = _state.user;
    final text = _commentCtrl.text.trim();
    if (user == null || text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      final comment = await _state.api.postComment(
        widget.article.id,
        user: user,
        commentText: text,
        selectedText: _selection,
      );
      _commentCtrl.clear();
      setState(() {
        _posted.add(comment);
        _selection = '';
      });
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _startDeepInspect() async {
    if (_inspecting) return;
    setState(() {
      _inspecting = true;
      _inspectError = null;
      _inspectProgress = 'Initializing Deep Inspect...';
    });

    try {
      await for (final event in _state.api.deepInspectStream(
        widget.article.id,
      )) {
        if (!mounted) return;
        if (event.event == 'status') {
          setState(() => _inspectProgress = event.data);
        } else if (event.event == 'final') {
          final json = jsonDecode(event.data);
          if (json is Map<String, dynamic>) {
            setState(() {
              _factCheck = FactCheckResult.fromJson(json);
              _inspecting = false;
              _inspectProgress = null;
            });
          }
        } else if (event.event == 'error') {
          String errMsg = event.data;
          try {
            final errJson = jsonDecode(event.data);
            if (errJson is Map && errJson['message'] != null) {
              errMsg = errJson['message'].toString();
            }
          } catch (_) {}
          setState(() {
            _inspectError = errMsg;
            _inspecting = false;
            _inspectProgress = null;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _inspectError = e.toString();
          _inspecting = false;
          _inspectProgress = null;
        });
      }
    }
  }

  Future<void> _askArticleQuestion() async {
    final q = _askCtrl.text.trim();
    if (q.isEmpty || _asking) return;
    setState(() => _asking = true);
    try {
      final answer = await _state.api.askArticle(
        widget.article.id,
        question: q,
        history: _qaHistory,
      );
      _askCtrl.clear();
      setState(() {
        _qaHistory.add({'role': 'user', 'content': q});
        _qaHistory.add({'role': 'assistant', 'content': answer});
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to answer: $e')));
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.article;
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.all(40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 880),
        // The dialog has no Scaffold of its own; add one for the SnackBar.
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(a),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(36, 26, 36, 32),
                    child: FutureBuilder<Article>(
                      future: _detail,
                      builder: (context, snap) {
                        final detail = snap.data;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _meta(detail ?? a),
                            const SizedBox(height: 14),
                            Text(
                              a.title,
                              style: GoogleFonts.playfairDisplay(
                                color: AppColors.textPrimary,
                                fontSize: 32,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                            if ((detail ?? a).tldr != null) ...[
                              const SizedBox(height: 20),
                              _tldr((detail ?? a).tldr!),
                            ],
                            const SizedBox(height: 22),
                            if (snap.hasError)
                              ErrorView(
                                error: snap.error!,
                                compact: true,
                                onRetry: () => setState(_loadDetail),
                              )
                            else if (detail == null)
                              const LoadingView(
                                message: 'Loading the full story…',
                                padding: 24,
                              )
                            else
                              _body(detail),
                            const SizedBox(height: 26),
                            _actions(detail ?? a),
                            if (_inspecting ||
                                _factCheck != null ||
                                _inspectError != null) ...[
                              const SizedBox(height: 24),
                              _deepInspectCard(detail ?? a),
                            ],
                            const SizedBox(height: 32),
                            const Divider(color: AppColors.border),
                            const SizedBox(height: 20),
                            _commentsSection(),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(Article a) {
    return Stack(
      children: [
        AspectRatio(aspectRatio: 2.6, child: NewsImage(a.image)),
        Positioned(left: 20, top: 20, child: CategoryBadge(a.category)),
        Positioned(
          right: 16,
          top: 16,
          child: CircleIconButton(
            icon: Icons.close_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }

  Widget _meta(Article a) {
    final parts = [
      a.source,
      if (a.author != null && a.author!.isNotEmpty) 'by ${a.author}',
      if (a.timeAgo.isNotEmpty) a.timeAgo,
      if (a.readMinutes != null) '${a.readMinutes} min read',
    ];
    return Row(
      children: [
        const Icon(Icons.verified_rounded, size: 16, color: AppColors.mint),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tldr(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.quoteBg,
        borderRadius: BorderRadius.circular(14),
        border: const Border(
          left: BorderSide(color: AppColors.accent, width: 4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OverlineLabel('TL;DR', color: AppColors.accentLight),
          const SizedBox(height: 8),
          Text(
            text,
            style: GoogleFonts.sourceSerif4(
              color: AppColors.textPrimary,
              fontSize: 16,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(Article detail) {
    final text = detail.cleanText?.trim() ?? '';
    if (text.isEmpty) {
      return Text(
        'The full text is not available for this story.',
        style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 14),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          text,
          style: GoogleFonts.sourceSerif4(
            color: AppColors.textBody,
            fontSize: 18,
            height: 1.7,
          ),
          onSelectionChanged: (sel, _) {
            final picked = sel.isValid && !sel.isCollapsed
                ? sel.textInside(text).trim()
                : '';
            if (picked.isNotEmpty && picked != _selection) {
              setState(() => _selection = picked);
            }
          },
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(
              Icons.format_quote_rounded,
              size: 15,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              'Select a passage to comment on it.',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actions(Article a) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          WebButton(
            label: _factCheck != null
                ? 'Grounded Fact-Check'
                : (_inspecting ? 'Inspecting...' : 'Deep Inspect'),
            icon: Icons.verified_user_rounded,
            primary: _factCheck != null,
            onTap: () {
              if (!_inspecting && _factCheck == null) {
                _startDeepInspect();
              }
            },
          ),
          WebButton(
            label: 'Ask WAI',
            icon: Icons.forum_outlined,
            onTap: () {
              Navigator.of(context).pop();
              _state.askAbout(a);
            },
          ),
          WebButton(
            label: _state.isSaved(a.id) ? 'Saved' : 'Save',
            icon: _state.isSaved(a.id)
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            primary: false,
            onTap: () => _state.toggleSaved(a.id),
          ),
          WebButton(
            label: _state.isLiked(a.id) ? 'Liked' : 'Like',
            icon: _state.isLiked(a.id)
                ? Icons.thumb_up_alt_rounded
                : Icons.thumb_up_alt_outlined,
            primary: false,
            color: _state.isLiked(a.id) ? AppColors.like : null,
            onTap: () => _state.toggleLiked(a.id),
          ),
          if (a.url.isNotEmpty)
            WebButton(
              label: 'Read original',
              icon: Icons.open_in_new_rounded,
              primary: false,
              onTap: () => _openOriginal(a.url),
            ),
        ],
      ),
    );
  }

  Widget _deepInspectCard(Article a) {
    if (_inspecting) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.accent,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    _inspectProgress ?? 'Running deep inspection...',
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Tavily Search and Extract are checking independent sources...',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    if (_inspectError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.dislike.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: AppColors.dislike,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _inspectError!,
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: _startDeepInspect,
              tooltip: 'Retry',
            ),
          ],
        ),
      );
    }

    final fc = _factCheck;
    if (fc == null) return const SizedBox.shrink();

    final isVerified =
        fc.factCheckVerdict.toLowerCase().contains('verified') &&
        !fc.factCheckVerdict.toLowerCase().contains('unverified');
    final isPartially = fc.factCheckVerdict.toLowerCase().contains('partially');
    // A story that cannot be verified is not "false"; gray instead of red.
    final verdictColor = isVerified
        ? AppColors.supported
        : (isPartially ? AppColors.contested : AppColors.unverified);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: verdictColor.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: verdictColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: verdictColor.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isVerified
                          ? Icons.check_circle_rounded
                          : (isPartially
                                ? Icons.warning_rounded
                                : Icons.help_outline_rounded),
                      size: 16,
                      color: verdictColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      fc.factCheckVerdict,
                      style: GoogleFonts.inter(
                        color: verdictColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (fc.isCached)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '0 Credits · Cached Receipt',
                    style: GoogleFonts.inter(
                      color: AppColors.mint,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (fc.modelUsed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Evaluated by ${fc.modelUsed}',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 11.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Executive Fact-Check Synthesis',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            fc.executiveSynthesis,
            style: GoogleFonts.sourceSerif4(
              color: AppColors.textBody,
              fontSize: 15.5,
              height: 1.6,
            ),
          ),
          if (fc.biasAndNuance.isNotEmpty &&
              fc.biasAndNuance != 'No framing bias detected.') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.quoteBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.balance_rounded,
                    size: 16,
                    color: AppColors.accentLight,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fc.biasAndNuance,
                      style: GoogleFonts.inter(
                        color: AppColors.textBody,
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (fc.claimMatrix.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Grounded Claims Matrix',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            for (final claim in fc.claimMatrix)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: claim.status.toLowerCase() == 'supported'
                                ? AppColors.supported.withValues(alpha: 0.2)
                                : (claim.status.toLowerCase() == 'contested'
                                      ? AppColors.contested.withValues(
                                          alpha: 0.2,
                                        )
                                      : AppColors.border),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            claim.status.toUpperCase(),
                            style: GoogleFonts.inter(
                              color: claim.status.toLowerCase() == 'supported'
                                  ? AppColors.supported
                                  : (claim.status.toLowerCase() == 'contested'
                                        ? AppColors.contested
                                        : AppColors.unverified),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            claim.claim,
                            style: GoogleFonts.inter(
                              color: AppColors.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      claim.evidenceSummary,
                      style: GoogleFonts.inter(
                        color: AppColors.textBody,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                    if (claim.sourceUrl != null &&
                        claim.sourceUrl!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () => _openOriginal(claim.sourceUrl!),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.link_rounded,
                                size: 14,
                                color: AppColors.accent,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  claim.sourceUrl!,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                    color: AppColors.accent,
                                    fontSize: 11.5,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
          if (fc.sourcesConsulted.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Tavily Verified Sources',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final src in fc.sourcesConsulted)
                  if ((src['url'] ?? '').isNotEmpty)
                    ActionChip(
                      avatar: const Icon(
                        Icons.travel_explore_rounded,
                        size: 14,
                        color: AppColors.accentLight,
                      ),
                      label: Text(
                        (src['title'] ?? '').isNotEmpty
                            ? src['title']!
                            : (Uri.tryParse(src['url']!)?.host ?? src['url']!),
                        style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      backgroundColor: AppColors.surface,
                      side: const BorderSide(color: AppColors.border),
                      onPressed: () => _openOriginal(src['url']!),
                    ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const Divider(color: AppColors.border),
          const SizedBox(height: 14),
          _researchSection(),
          const SizedBox(height: 20),
          const Divider(color: AppColors.border),
          const SizedBox(height: 14),
          Text(
            'Ask about this story',
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (_qaHistory.isNotEmpty) ...[
            for (final msg in _qaHistory)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: msg['role'] == 'user'
                        ? AppColors.surface
                        : AppColors.quoteBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        msg['role'] == 'user'
                            ? Icons.person_outline_rounded
                            : Icons.auto_awesome_rounded,
                        size: 14,
                        color: msg['role'] == 'user'
                            ? AppColors.textMuted
                            : AppColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          msg['content'] ?? '',
                          style: GoogleFonts.inter(
                            color: AppColors.textPrimary,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _askCtrl,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'Ask a question grounded in this verified report...',
                    hintStyle: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                  onSubmitted: (_) => _askArticleQuestion(),
                ),
              ),
              const SizedBox(width: 8),
              WebButton(
                label: _asking ? 'Thinking...' : 'Ask',
                icon: Icons.send_rounded,
                primary: true,
                onTap: () {
                  if (!_asking) {
                    _askArticleQuestion();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Tavily Research: on request, a multi-source report with citations about
  /// the story. The result is stored on the server per story; later openings
  /// spend no credits.
  Widget _researchSection() {
    final r = _research;
    final heading = Row(
      children: [
        const Icon(
          Icons.travel_explore_rounded,
          size: 18,
          color: AppColors.accentLight,
        ),
        const SizedBox(width: 8),
        Text(
          'Tavily Research',
          style: GoogleFonts.inter(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        if (r != null && r.isCompleted)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              r.cached
                  ? 'Saved report · 0 credits'
                  : '${(r.credits ?? 0).round()} Tavily credits',
              style: GoogleFonts.inter(
                color: AppColors.mint,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );

    if (_researching || (r?.isRunning ?? false)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 12),
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accentLight,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tavily Research is reading sources and writing a cited '
                  'report. This takes up to a minute.',
                  style: GoogleFonts.inter(
                    color: AppColors.textBody,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (r != null && r.isCompleted) {
      const shown = 8;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading,
          const SizedBox(height: 12),
          SimpleMarkdown(r.report!, fontSize: 14.5),
          if (r.sources.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${r.sources.length} sources',
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, src) in r.sources.take(shown).indexed)
                  ActionChip(
                    label: Text(
                      '[${i + 1}] ${Uri.tryParse(src.url)?.host ?? src.url}',
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: AppColors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    tooltip: src.title,
                    backgroundColor: AppColors.surface,
                    side: const BorderSide(color: AppColors.border),
                    onPressed: () => _openOriginal(src.url),
                  ),
                if (r.sources.length > shown)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '+${r.sources.length - shown} more',
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
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading,
        const SizedBox(height: 8),
        Text(
          'Want the bigger picture? Tavily Research reads many sources about '
          'this story and writes a cited report. It uses about 25 Tavily '
          'credits once; after that the report is saved for everyone.',
          style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 12.5),
        ),
        if (_researchError != null) ...[
          const SizedBox(height: 8),
          Text(
            _researchError!,
            style: GoogleFonts.inter(color: AppColors.dislike, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 12),
        WebButton(
          label: _researchError == null ? 'Research deeper' : 'Try again',
          icon: Icons.travel_explore_rounded,
          primary: false,
          onTap: _startResearch,
        ),
      ],
    );
  }

  Widget _commentsSection() {
    return FutureBuilder<List<ArticleComment>>(
      future: _comments,
      builder: (context, snap) {
        final comments = [...?snap.data, ..._posted];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              snap.hasData ? 'Comments (${comments.length})' : 'Comments',
              style: GoogleFonts.playfairDisplay(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            _commentInput(),
            const SizedBox(height: 18),
            if (snap.hasError)
              ErrorView(
                error: snap.error!,
                compact: true,
                onRetry: () => setState(_loadComments),
              )
            else if (!snap.hasData)
              const LoadingView(padding: 16)
            else if (comments.isEmpty)
              Text(
                'No comments yet. Be the first to share your take.',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13.5,
                ),
              )
            else
              for (final c in comments.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _CommentTile(comment: c),
                ),
          ],
        );
      },
    );
  }

  Widget _commentInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selection.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 3, height: 36, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '“$_selection”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.sourceSerif4(
                      color: AppColors.textBody,
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove quote',
                  onPressed: () => setState(() => _selection = ''),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              UserAvatar(size: 34, url: _state.user?.avatarUrl),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _commentCtrl,
                  onSubmitted: (_) => _postComment(),
                  minLines: 1,
                  maxLines: 4,
                  cursorColor: AppColors.accentLight,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: _selection.isEmpty
                        ? 'Add a comment…'
                        : 'Comment on the selected passage…',
                    hintStyle: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _posting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accentLight,
                      ),
                    )
                  : WebButton(label: 'Post', onTap: _postComment),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final ArticleComment comment;

  @override
  Widget build(BuildContext context) {
    final created = comment.createdAt?.toLocal();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(size: 34, url: comment.avatarUrl),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    comment.username.isEmpty ? 'Reader' : comment.username,
                    style: GoogleFonts.inter(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (created != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      formatTime(created),
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
              if (comment.selectedText != null &&
                  comment.selectedText!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: AppColors.accent, width: 3),
                    ),
                  ),
                  child: Text(
                    '“${comment.selectedText}”',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.sourceSerif4(
                      color: AppColors.textMuted,
                      fontSize: 13.5,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                comment.comment,
                style: GoogleFonts.inter(
                  color: AppColors.textBody,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
