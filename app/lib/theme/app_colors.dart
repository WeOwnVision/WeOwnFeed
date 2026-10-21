import 'package:flutter/material.dart';

/// WOF color palette: "Receipt". Ink background, paper text; the single
/// brand color (stamp red) is used only where attention is needed. Evidence
/// colors only describe evidence status; none of them is red, because a
/// story that cannot be verified is not "false".
class AppColors {
  AppColors._();

  static const background = Color(0xFF111110);
  static const surface = Color(0xFF1A1A18);
  static const surfaceAlt = Color(0xFF232220);
  static const quoteBg = Color(0xFF1F1E1B);

  /// Brand color: main button, selected tab, live indicator.
  static const accent = Color(0xFFD4553A);

  /// Brand-color text and icons on a dark background.
  static const accentLight = Color(0xFFE0745C);
  static const accentDeep = Color(0xFFA9412B);

  /// Text on a brand-color background.
  static const onAccent = Color(0xFFFFF4EE);

  /// Secondary accent (personalization reasons, check marks).
  static const mint = Color(0xFF7FA889);

  static const textPrimary = Color(0xFFECE8E1);
  static const textBody = Color(0xFFB9B4AB);
  static const textMuted = Color(0xFF8A857D);
  static const iconMuted = Color(0xFFC4BFB6);
  static const barInactive = Color(0xFF34322F);
  static const border = Color(0xFF2E2D2A);

  static const like = accent;
  static const dislike = Color(0xFF9A948B);

  // Evidence states.
  static const supported = Color(0xFF7FA889);
  static const contested = Color(0xFFC99A3E);
  static const unverified = Color(0xFF8A857D);
}
