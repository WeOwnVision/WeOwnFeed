import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import 'web_ui.dart';

/// Tavily terminal: every Tavily call the server makes (Search, Extract,
/// Map, Crawl, Research) is written to the right-hand panel as it happens.
/// Data comes from `GET /api/tavily/calls`; there are no fake rows. While the
/// panel is open new calls are polled every 2 s, never while it is closed.
class TavilyTerminal extends ChangeNotifier {
  TavilyTerminal._();

  static final instance = TavilyTerminal._();

  static const endpoints = ['search', 'extract', 'map', 'crawl', 'research'];

  /// Most rows kept in memory.
  static const _maxLines = 300;

  bool open = false;
  final List<TavilyCall> calls = [];

  /// Rows that arrived in this session (added with a fade-in).
  final Set<int> fresh = {};
  int? creditsRemaining;
  bool loading = false;
  String? error;

  int _latestId = 0;
  bool _loaded = false;
  Timer? _poll;
  int _ticks = 0;

  ApiService get _api => AppState.instance.api;

  void toggle() {
    open = !open;
    if (open) {
      _start();
    } else {
      _poll?.cancel();
      _poll = null;
    }
    notifyListeners();
  }

  /// Counters under the panel: calls per endpoint among the loaded rows.
  Map<String, int> get counts => {
    for (final e in endpoints) e: calls.where((c) => c.endpoint == e).length,
  };

  Future<void> _start() async {
    if (!_loaded) {
      loading = true;
      notifyListeners();
      try {
        final page = await _api.getTavilyCalls(limit: 100);
        calls
          ..clear()
          ..addAll(page.calls);
        _latestId = page.latestId;
        _loaded = true;
        error = null;
      } on ApiException catch (e) {
        error = e.userMessage;
      }
      loading = false;
      _refreshCredits();
      notifyListeners();
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  Future<void> _tick() async {
    if (!_loaded) return _start();
    _ticks++;
    try {
      final page = await _api.getTavilyCalls(afterId: _latestId);
      error = null;
      if (page.calls.isNotEmpty) {
        calls.addAll(page.calls);
        fresh.addAll(page.calls.map((c) => c.id));
        if (calls.length > _maxLines) {
          calls.removeRange(0, calls.length - _maxLines);
        }
        _latestId = page.latestId;
        _refreshCredits();
      } else if (_ticks % 15 == 0) {
        _refreshCredits();
      }
      notifyListeners();
    } on ApiException catch (e) {
      error = e.userMessage;
      notifyListeners();
    }
  }

  Future<void> _refreshCredits() async {
    try {
      creditsRemaining = await _api.getTavilyCreditsRemaining();
      notifyListeners();
    } on ApiException {
      // The counter hides when the credits are unknown.
    }
  }
}

/// Terminal color of an endpoint.
Color tavilyColor(String endpoint) => switch (endpoint) {
  'search' => const Color(0xFF5FB8D9),
  'extract' => const Color(0xFFD9AE5F),
  'map' => const Color(0xFFC685D6),
  'crawl' => const Color(0xFF8B9EF2),
  'research' => const Color(0xFF7FD99A),
  _ => AppColors.textMuted,
};

/// Why the call was made, in words the jury can read.
String tavilyPurpose(String purpose) => switch (purpose) {
  'demand_ingestion' || 'ingestion' => 'topic feed',
  'personalized_ingestion' => 'personal topic feed',
  'follow_first_fetch' => '"+" follow, first fetch',
  'ingest_extract_fallback' => 'read full story',
  'support' => 'verify: who supports it',
  'contradiction' => 'verify: who contradicts it',
  'official' => 'verify: official source',
  'verification' => 'verify: independent sources',
  'evidence_extract' => 'read the evidence',
  'live_horizon' => 'live web search',
  'site_follow_map' => 'follow site: map pages',
  'site_follow_crawl' => 'follow site: newest posts',
  'site_watch' => 'daily site check',
  'site_watch_burst' => 'daily site check: new posts',
  'deep_inspect_research' => 'deep research report',
  _ => purpose.replaceAll('_', ' '),
};

const _mono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
);

/// The terminal panel on the right.
class TavilyTerminalPanel extends StatelessWidget {
  const TavilyTerminalPanel({super.key});

  static const double width = 420;
  static const _bg = Color(0xFF0C0C0B);

  @override
  Widget build(BuildContext context) {
    final t = TavilyTerminal.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) {
        final lines = t.calls.reversed.toList();
        return Container(
          width: width,
          decoration: const BoxDecoration(
            color: _bg,
            border: Border(left: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(t),
              _counters(t),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: t.loading
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.mint,
                          ),
                        ),
                      )
                    : lines.isEmpty
                    ? _empty(t)
                    // Newest row at the bottom; the list stays at the bottom as rows arrive.
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        itemCount: lines.length,
                        itemBuilder: (context, i) {
                          final c = lines[i];
                          return _CallLine(
                            key: ValueKey(c.id),
                            call: c,
                            animate: t.fresh.contains(c.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(TavilyTerminal t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _LiveDot(active: t.error == null),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tavily terminal',
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  t.error ??
                      'Every Tavily call the server makes, as it happens.',
                  style: GoogleFonts.inter(
                    color: t.error == null
                        ? AppColors.textMuted
                        : AppColors.dislike,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: t.toggle,
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.iconMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _counters(TavilyTerminal t) {
    final counts = t.counts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in TavilyTerminal.endpoints)
                _EndpointCount(endpoint: e, count: counts[e] ?? 0),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              'Last ${t.calls.length} calls',
              if (t.creditsRemaining != null)
                '${t.creditsRemaining} credits left',
            ].join(' · '),
            style: _mono.copyWith(color: AppColors.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _empty(TavilyTerminal t) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        t.error != null
            ? 'Waiting for the server…'
            : 'No Tavily calls yet. Follow a topic or a site, or run Deep '
                  'Inspect on a story.',
        style: _mono.copyWith(color: AppColors.textMuted, fontSize: 12.5),
      ),
    );
  }
}

class _EndpointCount extends StatelessWidget {
  const _EndpointCount({required this.endpoint, required this.count});

  final String endpoint;
  final int count;

  @override
  Widget build(BuildContext context) {
    final color = tavilyColor(endpoint);
    final active = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.5) : AppColors.border,
        ),
      ),
      child: Text(
        '${endpoint.toUpperCase()} $count',
        style: _mono.copyWith(
          color: active ? color : AppColors.textMuted,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One call: time, endpoint, reason; below it the query and the result.
class _CallLine extends StatelessWidget {
  const _CallLine({super.key, required this.call, required this.animate});

  final TavilyCall call;
  final bool animate;

  String _time(DateTime? d) {
    if (d == null) return '--:--:--';
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = tavilyColor(call.endpoint);
    final result = call.cacheHit
        ? 'cache · 0 cr'
        : '${call.resultCount} result${call.resultCount == 1 ? '' : 's'}'
              ' · ${call.latencyMs} ms'
              ' · ${call.credits.toStringAsFixed(call.credits % 1 == 0 ? 0 : 1)} cr';
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${_time(call.createdAt)}  ',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                TextSpan(
                  text: call.endpoint.toUpperCase().padRight(9),
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                TextSpan(
                  text: tavilyPurpose(call.purpose),
                  style: const TextStyle(color: AppColors.textBody),
                ),
              ],
            ),
            style: _mono.copyWith(fontSize: 12),
          ),
          if ((call.detail ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(
                '→ ${call.detail}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _mono.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2),
            child: Text(
              result,
              style: _mono.copyWith(
                color: call.cacheHit ? AppColors.mint : AppColors.textMuted,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
    if (!animate) return line;
    // A new row slides in from the left with a glow.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(-14 * (1 - v), 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10 * (1 - v)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          ),
        ),
      ),
      child: line,
    );
  }
}

/// "Live" dot: pulses slowly while connected.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});

  final bool active;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? AppColors.mint : AppColors.dislike;
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Right edge of the page: the terminal slides in from the right when opened.
class TavilyDock extends StatelessWidget {
  const TavilyDock({super.key});

  @override
  Widget build(BuildContext context) {
    final t = TavilyTerminal.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        width: t.open ? TavilyTerminalPanel.width : 0,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: TavilyTerminalPanel.width,
            maxWidth: TavilyTerminalPanel.width,
            child: const TavilyTerminalPanel(),
          ),
        ),
      ),
    );
  }
}

/// The "Tavily" button in the top bar: opens / closes the terminal.
class TavilyTerminalButton extends StatelessWidget {
  const TavilyTerminalButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = TavilyTerminal.instance;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => Tooltip(
        message: t.open ? 'Hide Tavily terminal' : 'Show live Tavily calls',
        child: Hoverable(
          onTap: t.toggle,
          builder: (context, hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: t.open
                  ? AppColors.mint.withValues(alpha: 0.14)
                  : (hovered ? AppColors.surfaceAlt : AppColors.surface),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(
                color: t.open
                    ? AppColors.mint.withValues(alpha: 0.6)
                    : AppColors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.terminal_rounded,
                  size: 18,
                  color: t.open ? AppColors.mint : AppColors.iconMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  'Tavily',
                  style: GoogleFonts.inter(
                    color: t.open ? AppColors.mint : AppColors.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
