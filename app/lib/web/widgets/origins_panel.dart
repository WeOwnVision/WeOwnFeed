import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../theme/app_colors.dart';

/// "7 outlets → 2 independent origins". The outlets that ran a story first
/// show side by side, then collapse into their origins: a wire agency and
/// the outlets that reprinted it, or an outlet's own reporting. Tapping the
/// heading switches between the two views.
class OriginsPanel extends StatefulWidget {
  const OriginsPanel({super.key, required this.article, required this.onOpen});

  final Article article;

  /// Opens an outlet's copy.
  final ValueChanged<String> onOpen;

  @override
  State<OriginsPanel> createState() => _OriginsPanelState();
}

class _OriginsPanelState extends State<OriginsPanel> {
  bool _grouped = false;
  Timer? _collapse;

  @override
  void initState() {
    super.initState();
    _collapse = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _grouped = true);
    });
  }

  @override
  void dispose() {
    _collapse?.cancel();
    super.dispose();
  }

  /// Outlet → link of its copy (the story itself for its own outlet).
  Map<String, String> get _links => {
    widget.article.source: widget.article.url,
    for (final c in widget.article.alsoPublishedBy) c.source: c.url,
  };

  @override
  Widget build(BuildContext context) {
    final a = widget.article;
    final outlets = a.alsoPublishedByCount + 1;
    final origins = a.origins.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              _collapse?.cancel();
              setState(() => _grouped = !_grouped);
            },
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                const Icon(
                  Icons.layers_outlined,
                  size: 18,
                  color: AppColors.mint,
                ),
                const SizedBox(width: 8),
                Text(
                  '$outlets outlets',
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _grouped ? 1 : 0,
                  child: Text(
                    '  →  $origins independent '
                    '${origins == 1 ? 'origin' : 'origins'}',
                    style: GoogleFonts.inter(
                      color: AppColors.mint,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(
                  _grouped
                      ? Icons.unfold_more_rounded
                      : Icons.unfold_less_rounded,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topLeft,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.04),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: _grouped
                  ? _groupedView(a)
                  : KeyedSubtree(
                      key: const ValueKey('flat'),
                      child: _flatView(a),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flatView(Article a) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final o in a.origins)
        for (final outlet in o.outlets) _chip(outlet),
    ],
  );

  Widget _groupedView(Article a) => Column(
    key: const ValueKey('grouped'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final o in a.origins)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Icon(
                  o.wire ? Icons.cell_tower_rounded : Icons.edit_note_rounded,
                  size: 16,
                  color: o.wire ? AppColors.contested : AppColors.mint,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 190,
                child: Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    o.wire
                        ? '${o.name} wire · ${o.outlets.length} '
                              '${o.outlets.length == 1 ? 'outlet' : 'outlets'}'
                        : 'Own reporting',
                    style: GoogleFonts.inter(
                      color: o.wire ? AppColors.contested : AppColors.textBody,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final outlet in o.outlets) _chip(outlet)],
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _chip(String outlet) {
    final link = _links[outlet] ?? '';
    return ActionChip(
      label: Text(
        outlet,
        style: GoogleFonts.inter(fontSize: 12, color: AppColors.textPrimary),
      ),
      backgroundColor: AppColors.surface,
      side: const BorderSide(color: AppColors.border),
      onPressed: link.isEmpty ? null : () => widget.onOpen(link),
    );
  }
}
