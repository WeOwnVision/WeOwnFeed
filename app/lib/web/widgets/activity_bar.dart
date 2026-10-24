import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../state/app_state.dart';
import '../../theme/app_colors.dart';

/// Puts the [ActivityBar] above everything the app shows, dialogs included
/// (`MaterialApp.builder`).
class ActivityBarHost extends StatelessWidget {
  const ActivityBarHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        const Positioned(
          top: 14,
          left: 16,
          right: 16,
          child: Center(child: ActivityBar()),
        ),
      ],
    );
  }
}

/// One row per running Fact Check or Research: which method, which story,
/// the server's current step and a clock that counts up. The line under it
/// fills toward the method's typical length, then keeps moving until the
/// result arrives.
class ActivityBar extends StatefulWidget {
  const ActivityBar({super.key});

  @override
  State<ActivityBar> createState() => _ActivityBarState();
}

class _ActivityBarState extends State<ActivityBar> {
  final _state = AppState.instance;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
    _syncClock();
  }

  void _onState() {
    _syncClock();
    if (mounted) setState(() {});
  }

  /// The clock ticks only while something runs.
  void _syncClock() {
    final running = _state.runningTasks.isNotEmpty;
    if (running && _clock == null) {
      _clock = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    } else if (!running) {
      _clock?.cancel();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _state.runningTasks;
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TaskRow(task: t),
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final RunningTask task;

  static String _clock(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final factCheck = task.kind == TaskKind.factCheck;
    final elapsed = DateTime.now().difference(task.started);
    final overdue = elapsed > task.expected;
    final step =
        task.step ??
        (factCheck
            ? 'Checking each claim against independent sources'
            : 'Tavily is reading sources and writing a cited report');

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.55)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                factCheck
                    ? Icons.verified_user_rounded
                    : Icons.travel_explore_rounded,
                size: 18,
                color: AppColors.accentLight,
              ),
              const SizedBox(width: 8),
              Text(
                factCheck ? 'Fact Check' : 'Research',
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.article.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    color: AppColors.textBody,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _clock(elapsed),
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: overdue
                  ? null
                  : elapsed.inMilliseconds / task.expected.inMilliseconds,
              backgroundColor: AppColors.border,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            overdue ? '$step · taking a little longer' : step,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
