import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Simple viewer for the Markdown the server generates (synthesize).
///
/// Supported: `#` headings, lines that are only `**bold**` (treated as
/// headings), `-`/`*`/`1.` list items, `---` rules, `|` tables and inline
/// `**bold**` / `*italic*`.
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(this.data, {super.key, this.fontSize = 15.5});

  final String data;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final body = GoogleFonts.sourceSerif4(
      color: AppColors.textBody,
      fontSize: fontSize,
      height: 1.6,
    );
    final heading = GoogleFonts.playfairDisplay(
      color: AppColors.textPrimary,
      fontSize: fontSize + 3,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );

    final children = <Widget>[];
    void gap(double h) {
      if (children.isNotEmpty) children.add(SizedBox(height: h));
    }

    for (final raw in data.split('\n')) {
      final line = raw.trimRight();
      final t = line.trim();
      if (t.isEmpty) continue;

      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
        gap(8);
        children.add(const Divider(color: AppColors.border, height: 16));
        continue;
      }

      final h = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(t);
      final boldOnly = RegExp(r'^\*\*(.+?)\*\*:?$').firstMatch(t);
      if (h != null || boldOnly != null) {
        gap(14);
        children.add(
          Text(_strip(h?.group(1) ?? boldOnly!.group(1)!), style: heading),
        );
        continue;
      }

      if (t.startsWith('|')) {
        final cells = t
            .split('|')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        // Separator row: |---|:---:|
        if (cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) continue;
        gap(6);
        children.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text.rich(
              _inline(
                cells.join('  ·  '),
                body.copyWith(fontSize: fontSize - 1),
              ),
            ),
          ),
        );
        continue;
      }

      final bullet = RegExp(r'^([-*•]|\d+[.)])\s+(.*)$').firstMatch(t);
      if (bullet != null) {
        final indent = (line.length - line.trimLeft().length).clamp(0, 8);
        final marker = bullet.group(1)!;
        gap(4);
        children.add(
          Padding(
            padding: EdgeInsets.only(left: indent * 4.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    RegExp(r'\d').hasMatch(marker) ? marker : '•',
                    style: body.copyWith(color: AppColors.accentLight),
                  ),
                ),
                Expanded(child: Text.rich(_inline(bullet.group(2)!, body))),
              ],
            ),
          ),
        );
        continue;
      }

      gap(8);
      children.add(Text.rich(_inline(t, body)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  static String _strip(String s) =>
      s.replaceAll('**', '').replaceAll('__', '').trim();

  /// Splits out the `**bold**` and `*italic*` parts.
  static TextSpan _inline(String text, TextStyle base) {
    final spans = <TextSpan>[];
    final re = RegExp(
      r'\*\*(.+?)\*\*|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])',
    );
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: base, children: spans);
  }
}
