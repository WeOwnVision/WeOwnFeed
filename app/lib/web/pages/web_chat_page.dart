import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../models/article_ui.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/simple_markdown.dart';
import '../../widgets/smooth_scroll.dart';
import '../../widgets/state_views.dart';
import '../widgets/article_dialog.dart';
import '../widgets/interest_form.dart' show categoryIcon;
import '../widgets/web_ui.dart';

/// WAI, the news assistant. A chat opens from three places and WAI writes
/// the first message: a story card (the story's full text), the home page
/// "Latest developments" card, and an area picked on this page (that area's
/// latest stories).
class WebChatPage extends StatelessWidget {
  const WebChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 28),
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => LayoutBuilder(
          builder: (context, c) {
            final showContext = c.maxWidth >= 1080;
            final thread = state.activeThread;
            final news = state.activeThreadArticle;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 290, child: _ThreadList(state: state)),
                const SizedBox(width: 20),
                Expanded(child: _ChatPanel(state: state)),
                if (showContext) ...[
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 320,
                    child: thread == null
                        ? const _CapabilitiesPanel()
                        : news != null
                        ? _ContextPanel(news: news)
                        : _SourcesPanel(thread: thread),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sohbet listesi
// ---------------------------------------------------------------------------
class _ThreadList extends StatelessWidget {
  const _ThreadList({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ids = state.threads.keys.toList().reversed.toList();
    return PanelCard(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(
                  'Chats',
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: 'New chat',
                  child: Hoverable(
                    onTap: state.startNewChat,
                    builder: (context, hovered) => Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: hovered
                            ? AppColors.accentLight
                            : AppColors.surfaceAlt,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.edit_outlined,
                        size: 16,
                        color: hovered ? onAccent : AppColors.accentLight,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ids.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'No chats yet. Pick an area to start one.',
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: ids.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      final id = ids[i];
                      final thread = state.threads[id]!;
                      final messages = thread.messages;
                      final last = messages.lastWhere(
                        (m) => m.text.isNotEmpty,
                        orElse: () => messages.last,
                      );
                      return _ThreadTile(
                        title: thread.title,
                        preview: last.text.isEmpty
                            ? 'WAI is reading…'
                            : last.text,
                        time: formatTime(last.time),
                        image: thread.article?.image,
                        icon: _modeIcon(thread),
                        selected: id == state.activeThreadId,
                        onTap: () => state.openThread(id),
                      );
                    },
                  ),
          ),
          const Divider(color: AppColors.border, height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Ask WAI from a story card or from your Latest developments, '
              'or pick an area with the pencil button.',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon of the chat type (a story chat shows the story's image).
IconData _modeIcon(WaiThread thread) => switch (thread.mode) {
  WaiMode.story => Icons.article_outlined,
  WaiMode.latest => Icons.auto_awesome_rounded,
  WaiMode.area => categoryIcon(thread.area ?? ''),
};

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.title,
    required this.preview,
    required this.time,
    required this.image,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String preview;
  final String time;
  final String? image;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceAlt
              : (hovered ? AppColors.surfaceAlt : Colors.transparent),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: image == null
                  ? IconOrb(
                      size: 44,
                      child: Icon(icon, size: 18, color: AppColors.accentLight),
                    )
                  : NewsImage(image!, width: 44, height: 44),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            color: selected
                                ? AppColors.accentLight
                                : AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        time,
                        style: GoogleFonts.inter(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    preview,
                    maxLines: 1,
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
    );
  }
}

// ---------------------------------------------------------------------------
// Sohbet paneli
// ---------------------------------------------------------------------------
class _ChatPanel extends StatefulWidget {
  const _ChatPanel({required this.state});

  final AppState state;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  static const _storySuggestions = [
    'Simplify this',
    'Why does it matter?',
    "What's the counterargument?",
    'What are the sources?',
  ];
  static const _overviewSuggestions = [
    'Summarize the most striking',
    'What matters most for me?',
    'How are these connected?',
    'What should I watch next?',
  ];

  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = SmoothScrollController();
  int _lastCount = -1;
  int _lastLength = -1;
  String? _lastThread;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Not sent while WAI is writing; the typed text stays in the box. The box
  /// is not made read-only meanwhile: changing readOnly on the focused field
  /// tripped a debug check in the Flutter web engine and froze the page in
  /// the debugger.
  void _send([String? text]) {
    final value = text ?? _input.text;
    if (value.trim().isEmpty || widget.state.waiTyping) return;
    widget.state.send(value);
    if (text == null) _input.clear();
    _inputFocus.requestFocus();
  }

  /// Scrolls down to a new message; while a reply streams it follows the
  /// text without animation if already at the bottom. Starting a new
  /// animation per chunk made scrolling jitter. If the user scrolled up, it
  /// stays put.
  void _scrollToEndIfNeeded() {
    final state = widget.state;
    final messages = state.activeMessages;
    final count = messages.length;
    final length = messages.isEmpty ? 0 : messages.last.text.length;
    final threadChanged = state.activeThreadId != _lastThread;
    final newMessage = count != _lastCount;
    if (!threadChanged && !newMessage && length == _lastLength) return;
    _lastThread = state.activeThreadId;
    _lastCount = count;
    _lastLength = length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      final end = position.maxScrollExtent;
      if (threadChanged) {
        _scroll.jumpTo(end);
      } else if (newMessage) {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else if (end - position.pixels < 240 &&
          !position.isScrollingNotifier.value) {
        _scroll.jumpTo(end);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state.activeThreadId == null) return _StartPanel(state: state);
    final thread = state.activeThread!;
    final messages = thread.messages;
    final busy = state.waiTyping;
    final suggestions = thread.mode == WaiMode.story
        ? _storySuggestions
        : _overviewSuggestions;
    final hint = switch (thread.mode) {
      WaiMode.story => 'Ask WAI anything about this story…',
      WaiMode.latest => 'Ask about your latest developments…',
      WaiMode.area => 'Ask about ${thread.title}…',
    };
    _scrollToEndIfNeeded();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _ChatHeader(thread: thread),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
              children: [
                for (final m in messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _MessageView(message: m, state: state),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in suggestions)
                    PillButton(
                      label: s,
                      selected: false,
                      dense: true,
                      onTap: () => _send(s),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Ask by voice',
                    onPressed: () {},
                    icon: const Icon(
                      Icons.mic_none_rounded,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      autofocus: true,
                      onSubmitted: (_) => _send(),
                      cursorColor: AppColors.accentLight,
                      style: GoogleFonts.inter(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                      ),
                      decoration: InputDecoration(
                        hintText: busy ? 'WAI is answering…' : hint,
                        hintStyle: GoogleFonts.inter(
                          color: AppColors.textMuted,
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Send (Enter)',
                    child: Hoverable(
                      onTap: busy ? null : _send,
                      builder: (context, hovered) => Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hovered
                              ? AppColors.textPrimary
                              : AppColors.accentLight,
                        ),
                        child: const Icon(
                          Icons.arrow_upward_rounded,
                          color: onAccent,
                          size: 22,
                        ),
                      ),
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

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.thread});

  final WaiThread thread;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'WAI',
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: AppColors.accentLight,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  thread.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.mint,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      thread.subtitle.isNotEmpty
                          ? thread.subtitle
                          : 'News assistant · online',
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.message, required this.state});

  final ChatMessage message;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (message.article != null) return _SentNews(news: message.article!);
    if (message.role == ChatRole.user) return _UserBubble(message: message);
    return _AssistantBubble(message: message, state: state);
  }
}

class _SentNews extends StatelessWidget {
  const _SentNews({required this.news});

  final Article news;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.reply_rounded,
              size: 14,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              'Shared story',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Hoverable(
            onTap: () => showArticleDialog(context, news),
            builder: (context, hovered) => Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: hovered ? AppColors.quoteBg : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: NewsImage(news.image, width: 76, height: 60),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          news.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.playfairDisplay(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          news.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.sourceSerif4(
                            color: AppColors.textBody,
                            fontSize: 13.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: const BoxDecoration(
              color: AppColors.accentLight,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: SelectableText(
              message.text,
              style: GoogleFonts.inter(
                color: onAccent,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          formatTime(message.time),
          style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.message, required this.state});

  final ChatMessage message;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final waiting = message.streaming && message.text.isEmpty;
    final error = message.isError;

    final Widget content;
    if (waiting) {
      content = const _TypingIndicator();
    } else if (error) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.dislike,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message.text,
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    } else if (message.streaming) {
      content = SelectableText(
        '${message.text}▍',
        style: GoogleFonts.sourceSerif4(
          color: AppColors.textPrimary,
          fontSize: 16.5,
          height: 1.65,
        ),
      );
    } else {
      // WAI may use bullets and **bold**; numbers like [1] refer to the
      // "What WAI read" list on the right.
      content = SelectionArea(
        child: SimpleMarkdown(message.text, fontSize: 16),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IconOrb(
          size: 34,
          child: Icon(
            Icons.auto_awesome_rounded,
            size: 16,
            color: AppColors.accentLight,
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: error
                        ? AppColors.dislike.withValues(alpha: 0.10)
                        : AppColors.surfaceAlt,
                    border: error
                        ? Border.all(
                            color: AppColors.dislike.withValues(alpha: 0.4),
                          )
                        : null,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(6),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    ),
                  ),
                  child: content,
                ),
                if (!message.streaming) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (error)
                        _MiniAction(
                          icon: Icons.refresh_rounded,
                          label: 'Retry',
                          onTap: () => state.retry(message),
                        )
                      else ...[
                        _MiniAction(
                          icon: message.helpful
                              ? Icons.thumb_up_alt_rounded
                              : Icons.thumb_up_alt_outlined,
                          label: 'Helpful',
                          active: message.helpful,
                          onTap: () => state.toggleHelpful(message),
                        ),
                        const SizedBox(width: 6),
                        _MiniAction(
                          icon: Icons.copy_rounded,
                          label: 'Copy',
                          onTap: () {
                            Clipboard.setData(
                              ClipboardData(text: message.text),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                behavior: SnackBarBehavior.floating,
                                width: 260,
                                backgroundColor: AppColors.surfaceAlt,
                                content: Text(
                                  'Answer copied to clipboard',
                                  style: GoogleFonts.inter(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                      const SizedBox(width: 10),
                      Text(
                        formatTime(message.time),
                        style: GoogleFonts.inter(
                          color: AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// No chat chosen yet: pick a story and ask WAI about it.
class _StartPanel extends StatefulWidget {
  const _StartPanel({required this.state});

  final AppState state;

  @override
  State<_StartPanel> createState() => _StartPanelState();
}

class _StartPanelState extends State<_StartPanel> {
  @override
  void initState() {
    super.initState();
    widget.state.ensureFeed();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state.hasServerUser) return _AreaPicker(state: state);
    final Widget list;
    if (state.feed.isEmpty && state.feedError != null) {
      list = ErrorView(error: state.feedError!, onRetry: state.loadMoreFeed);
    } else if (state.feed.isEmpty) {
      list = const LoadingView(message: 'Loading stories…');
    } else {
      list = ListView.separated(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: state.feed.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final a = state.feed[i];
          return Hoverable(
            onTap: () => state.askAbout(a),
            builder: (context, hovered) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: hovered ? AppColors.surfaceAlt : AppColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hovered
                      ? AppColors.accent.withValues(alpha: 0.45)
                      : AppColors.border,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: NewsImage(a.image, width: 56, height: 56),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OverlineLabel(a.category, color: AppColors.mint),
                        const SizedBox(height: 4),
                        Text(
                          a.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.playfairDisplay(
                            color: AppColors.textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.forum_outlined,
                    size: 20,
                    color: hovered
                        ? AppColors.accentLight
                        : AppColors.textMuted,
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pick a story to ask WAI about',
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'WAI answers strictly from the story you choose — ask it to '
                  'simplify, explain why it matters, or find what is missing.',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: hovered || active ? AppColors.surfaceAlt : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? AppColors.like : AppColors.textMuted,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                color: active ? AppColors.like : AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(16),
            ),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentLight.withValues(
                          alpha: ((_c.value * 3 - i) % 3) < 1 ? 1 : 0.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'WAI is thinking…',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Right panel
// ---------------------------------------------------------------------------
class _ContextPanel extends StatelessWidget {
  const _ContextPanel({required this.news});

  final Article news;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: PanelCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const OverlineLabel('Chat context'),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: NewsImage(news.image),
              ),
            ),
            const SizedBox(height: 14),
            OverlineLabel(news.category, color: AppColors.mint),
            const SizedBox(height: 6),
            Text(
              news.title,
              style: GoogleFonts.playfairDisplay(
                color: AppColors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              news.summary,
              style: GoogleFonts.sourceSerif4(
                color: AppColors.textBody,
                fontSize: 14.5,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              sourceLine(news),
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: WebButton(
                    label: 'Open story',
                    icon: Icons.open_in_new_rounded,
                    onTap: () => showArticleDialog(context, news),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Center(child: BookmarkButton(news)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilitiesPanel extends StatelessWidget {
  const _CapabilitiesPanel();

  static const _items = [
    (
      Icons.compress_rounded,
      'Simplify',
      'Explains complex stories in a single paragraph.',
    ),
    (
      Icons.balance_rounded,
      'Opposing views',
      'Summarizes the arguments of each side.',
    ),
    (Icons.link_rounded, 'Source tracking', 'Shows where a story comes from.'),
    (
      Icons.headphones_outlined,
      'Audio brief',
      'Turns answers into an audio bulletin.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OverlineLabel('What can WAI do?'),
          const SizedBox(height: 16),
          for (final (icon, title, body) in _items)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 18, color: AppColors.accentLight),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.inter(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          body,
                          style: GoogleFonts.inter(
                            color: AppColors.textMuted,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Area picker (chat opened from the WAI tab)
// ---------------------------------------------------------------------------
/// The user's own areas are large, their subtopics medium, the remaining
/// categories and subtopics small. WAI reads the picked area's latest stories
/// and opens the chat itself.
class _AreaPicker extends StatefulWidget {
  const _AreaPicker({required this.state});

  final AppState state;

  @override
  State<_AreaPicker> createState() => _AreaPickerState();
}

class _AreaPickerState extends State<_AreaPicker> {
  @override
  void initState() {
    super.initState();
    widget.state.loadTaxonomy();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final taxonomy = state.taxonomy;
    final Widget body;
    if (taxonomy == null) {
      body = state.taxonomyError != null
          ? ErrorView(error: state.taxonomyError!, onRetry: state.loadTaxonomy)
          : const LoadingView(message: 'Loading areas…');
    } else {
      final mine = state.interests.toSet();
      final myTags = state.interestTags.toSet();
      final myCategories = [
        for (final macro in state.interests)
          ...taxonomy.where((c) => c.macro == macro),
      ];
      final myTopics = [
        for (final c in taxonomy)
          for (final t in c.microTags)
            if (myTags.contains(t.tag)) (c, t),
      ];
      final otherCategories = [
        for (final c in taxonomy)
          if (!mine.contains(c.macro)) c,
      ];
      final otherTopics = [
        for (final c in taxonomy)
          for (final t in c.microTags)
            if (!myTags.contains(t.tag)) (c, t),
      ];

      body = ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          if (myCategories.isNotEmpty) ...[
            const OverlineLabel('Your areas'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final c in myCategories)
                  _AreaTile.large(
                    label: c.displayName,
                    icon: categoryIcon(c.macro),
                    color: categoryColor(c.macro),
                    onTap: () => state.askArea(c.macro, label: c.displayName),
                  ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          if (myTopics.isNotEmpty) ...[
            const OverlineLabel('Your topics'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (c, t) in myTopics)
                  _AreaTile.medium(
                    label: t.label,
                    icon: categoryIcon(c.macro),
                    color: categoryColor(c.macro),
                    onTap: () => state.askArea(t.tag, label: t.label),
                  ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          const OverlineLabel('More areas'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in otherCategories)
                _AreaTile.small(
                  label: c.displayName,
                  icon: categoryIcon(c.macro),
                  color: categoryColor(c.macro),
                  onTap: () => state.askArea(c.macro, label: c.displayName),
                ),
              for (final (c, t) in otherTopics)
                _AreaTile.small(
                  label: t.label,
                  color: categoryColor(c.macro),
                  onTap: () => state.askArea(t.tag, label: t.label),
                ),
            ],
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'What do you want to talk about?',
                  style: GoogleFonts.playfairDisplay(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Pick an area. WAI reads its latest stories and opens the '
                  'conversation; it answers only from what it read.',
                  style: GoogleFonts.inter(
                    color: AppColors.textMuted,
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

enum _AreaSize { large, medium, small }

/// Area tile in three sizes: the user's areas, their subtopics, the rest.
class _AreaTile extends StatelessWidget {
  const _AreaTile.large({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
  }) : size = _AreaSize.large;

  const _AreaTile.medium({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
  }) : size = _AreaSize.medium;

  const _AreaTile.small({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
  }) : size = _AreaSize.small;

  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;
  final _AreaSize size;

  @override
  Widget build(BuildContext context) {
    final (width, height, iconSize, fontSize, radius) = switch (size) {
      _AreaSize.large => (230.0, 108.0, 26.0, 17.0, 20.0),
      _AreaSize.medium => (186.0, 58.0, 18.0, 14.0, 16.0),
      _AreaSize.small => (null, 34.0, 14.0, 12.5, 17.0),
    };
    return Semantics(
      button: true,
      label: label,
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: width,
          height: height,
          padding: EdgeInsets.symmetric(
            horizontal: size == _AreaSize.small ? 12 : 16,
            vertical: size == _AreaSize.large ? 16 : 0,
          ),
          decoration: BoxDecoration(
            color: color.withValues(
              alpha: hovered ? 0.22 : (size == _AreaSize.small ? 0.06 : 0.12),
            ),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: color.withValues(alpha: hovered ? 0.8 : 0.35),
            ),
          ),
          child: size == _AreaSize.large
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(icon, size: iconSize, color: color),
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: AppColors.textPrimary,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: iconSize, color: color),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          color: size == _AreaSize.small
                              ? AppColors.textBody
                              : AppColors.textPrimary,
                          fontSize: fontSize,
                          fontWeight: size == _AreaSize.small
                              ? FontWeight.w500
                              : FontWeight.w600,
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

// ---------------------------------------------------------------------------
// Stories WAI read (latest developments and area chats)
// ---------------------------------------------------------------------------
class _SourcesPanel extends StatelessWidget {
  const _SourcesPanel({required this.thread});

  final WaiThread thread;

  @override
  Widget build(BuildContext context) {
    final sources = thread.sources;
    return PanelCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OverlineLabel('What WAI read'),
          const SizedBox(height: 6),
          Text(
            sources.isEmpty
                ? 'WAI is reading…'
                : '${sources.length} stories. The numbers match WAI\'s '
                      'answers.',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView.separated(
              itemCount: sources.length,
              separatorBuilder: (_, _) =>
                  const Divider(color: AppColors.border, height: 20),
              itemBuilder: (context, i) {
                final a = sources[i];
                return Hoverable(
                  onTap: () => showArticleDialog(context, a),
                  builder: (context, hovered) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: GoogleFonts.inter(
                            color: AppColors.accentLight,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                color: hovered
                                    ? AppColors.accentLight
                                    : AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              sourceLine(a),
                              style: GoogleFonts.inter(
                                color: AppColors.textMuted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
