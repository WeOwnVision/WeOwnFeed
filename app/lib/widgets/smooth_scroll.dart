import 'package:flutter/material.dart';

/// Controller that smooths mouse-wheel scrolling. Flutter web jumps the page
/// at once on every wheel notch; this controller covers the same distance with
/// a short animation. Notches in a row add to the target, so the animation
/// does not restart on fast scrolling.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({super.initialScrollOffset, super.debugLabel});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Where the running animation is heading; a new notch continues from here.
  double? _target;

  @override
  void pointerScroll(double delta) {
    // Touchpads send small, frequent steps and are already smooth.
    if (delta.abs() < 40) {
      _target = null;
      super.pointerScroll(delta);
      return;
    }
    final from = _target != null && isScrollingNotifier.value
        ? _target!
        : pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    _target = target;
    animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }
}

/// Uses a [SmoothScrollController] where there is no State of its own:
/// creates the controller and disposes it when done.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
