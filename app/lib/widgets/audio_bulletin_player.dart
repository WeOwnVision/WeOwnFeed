import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Audio bulletin player.
///
/// There is no real audio source yet; play, progress, speed and seeking are
/// simulated with a [Ticker]. Once audio exists, [_togglePlay], [_seekTo]
/// and [_cycleSpeed] can be wired to a real player.
class AudioBulletinPlayer extends StatefulWidget {
  const AudioBulletinPlayer({
    super.key,
    this.duration = const Duration(minutes: 2, seconds: 34),
    this.initialProgress = 0.0,
  });

  final Duration duration;

  /// Start position between 0.0 and 1.0.
  final double initialProgress;

  @override
  State<AudioBulletinPlayer> createState() => _AudioBulletinPlayerState();
}

class _AudioBulletinPlayerState extends State<AudioBulletinPlayer>
    with SingleTickerProviderStateMixin {
  static const _speeds = [1.0, 1.25, 1.5, 2.0];

  // Fixed bar heights (0-1), close to the waveform in the screenshot.
  static const List<double> _bars = [
    0.30,
    0.45,
    0.62,
    0.80,
    0.55,
    0.92,
    0.70,
    1.00,
    0.58,
    0.85,
    0.66,
    0.40,
    0.72,
    0.50,
    0.88,
    0.60,
    0.95,
    0.48,
    0.75,
    0.55,
    0.82,
    0.62,
    0.45,
    0.70,
    0.52,
    0.38,
    0.60,
    0.44,
    0.33,
    0.50,
    0.40,
    0.28,
    0.42,
    0.30,
  ];

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  late Duration _position;
  bool _isPlaying = false;
  int _speedIndex = 0;

  double get _progress =>
      (_position.inMilliseconds / widget.duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );

  @override
  void initState() {
    super.initState();
    _position = widget.duration * widget.initialProgress.clamp(0.0, 1.0);
    _ticker = createTicker(_onTick);
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    setState(() {
      _position += delta * _speeds[_speedIndex];
      if (_position >= widget.duration) {
        _position = Duration.zero;
        _pause();
      }
    });
  }

  void _togglePlay() => setState(() => _isPlaying ? _pause() : _play());

  void _play() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
    _isPlaying = true;
  }

  void _pause() {
    _ticker.stop();
    _isPlaying = false;
  }

  void _cycleSpeed() =>
      setState(() => _speedIndex = (_speedIndex + 1) % _speeds.length);

  void _seekTo(double fraction) {
    setState(() => _position = widget.duration * fraction.clamp(0.0, 1.0));
  }

  String _format(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _speedLabel {
    final v = _speeds[_speedIndex];
    return v == v.roundToDouble() ? '${v.toInt()}x' : '${v}x';
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.duration - _position;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _PlayButton(isPlaying: _isPlaying, onTap: _togglePlay),
          const SizedBox(width: 12),
          Expanded(child: _buildWaveform()),
          const SizedBox(width: 10),
          SizedBox(
            width: 36,
            child: Text(
              _format(remaining),
              textAlign: TextAlign.right,
              style: GoogleFonts.inter(
                color: AppColors.textBody,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: _cycleSpeed,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.barInactive,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _speedLabel,
                  style: GoogleFonts.inter(
                    color: AppColors.textBody,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveform() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void handle(double dx) => _seekTo(dx / width);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => handle(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => handle(d.localPosition.dx),
          child: SizedBox(
            height: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(_bars.length, (i) {
                final played = (i + 0.5) / _bars.length <= _progress;
                // A slight "live" shimmer while playing.
                final pulse = _isPlaying && played
                    ? 0.92 +
                          0.08 *
                              math.sin(_position.inMilliseconds / 120 + i * 0.9)
                    : 1.0;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: 40 * _bars[i] * pulse,
                  decoration: BoxDecoration(
                    color: played
                        ? AppColors.accentLight
                        : AppColors.barInactive,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ),
        );
      },
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.isPlaying, required this.onTap});

  final bool isPlaying;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(isPlaying),
              color: AppColors.onAccent,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}
