import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/common.dart';
import '../../widgets/smooth_scroll.dart';
import '../widgets/interest_form.dart';
import '../widgets/web_ui.dart';

/// Profile (left) and settings (right) page.
class WebProfilePage extends StatefulWidget {
  const WebProfilePage({super.key});

  @override
  State<WebProfilePage> createState() => _WebProfilePageState();
}

class _WebProfilePageState extends State<WebProfilePage> {
  final state = AppState.instance;
  final _scroll = SmoothScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // `GET /api/users/{id}/preferences` and the taxonomy for tag names.
    state.refreshPreferences();
    state.loadFollows();
    if (state.hasServerUser) state.loadTaxonomy();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(40, 32, 40, 56),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 420,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ProfileCard(state: state),
                      const SizedBox(height: 20),
                      _LibraryTabs(state: state),
                    ],
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(child: _Settings(state: state)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile card
// ---------------------------------------------------------------------------
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 26),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.border,
                ),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: UserAvatar(size: 96, url: state.user?.avatarUrl),
                ),
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: Tooltip(
                  message: 'Edit profile',
                  child: Hoverable(
                    onTap: () {},
                    builder: (context, hovered) => Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: hovered
                            ? AppColors.textPrimary
                            : AppColors.accentLight,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 3),
                      ),
                      child: const Icon(
                        Icons.edit_rounded,
                        size: 14,
                        color: onAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            state.user?.username ?? 'Reader',
            style: GoogleFonts.playfairDisplay(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${state.saved.length} saved  ·  '
            '${state.liked.length} liked',
            style: GoogleFonts.inter(color: AppColors.textBody, fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saved / Liked
// ---------------------------------------------------------------------------
class _LibraryTabs extends StatefulWidget {
  const _LibraryTabs({required this.state});

  final AppState state;

  @override
  State<_LibraryTabs> createState() => _LibraryTabsState();
}

class _LibraryTabsState extends State<_LibraryTabs> {
  bool _showSaved = true;

  @override
  void initState() {
    super.initState();
    // Records left from earlier sessions may not be in the cache.
    widget.state.ensureArticles({...widget.state.saved, ...widget.state.liked});
  }

  @override
  Widget build(BuildContext context) {
    final List<Article> items = _showSaved
        ? widget.state.savedArticles
        : widget.state.likedArticles;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              _tab(
                label: 'Saved',
                icon: Icons.bookmark_rounded,
                selected: _showSaved,
                onTap: () => setState(() => _showSaved = true),
              ),
              _tab(
                label: 'Liked',
                icon: Icons.favorite_border_rounded,
                selected: !_showSaved,
                onTap: () => setState(() => _showSaved = false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              _showSaved ? 'No saved stories.' : 'No liked stories.',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 13.5,
              ),
            ),
          )
        else
          for (final n in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: NewsListTile(n, showBookmark: _showSaved),
            ),
      ],
    );
  }

  Widget _tab({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentLight
                : (hovered ? AppColors.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? onAccent : AppColors.textBody,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.inter(
                  color: selected ? onAccent : AppColors.textBody,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
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
// Ayarlar
// ---------------------------------------------------------------------------
class _Settings extends StatelessWidget {
  const _Settings({required this.state});

  final AppState state;

  static final _fontSizes = <double, String>{
    0.875: 'Small (14px)',
    1.0: 'Normal (16px)',
    1.125: 'Large (18px)',
    1.25: 'Extra large (20px)',
  };

  @override
  Widget build(BuildContext context) {
    final interests = state.interests;
    final topics = state.interestTags;
    final canEdit = state.hasServerUser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Row(
            children: [
              const OverlineLabel('Settings'),
              const Spacer(),
              Text(
                'v2.4 Pro',
                style: GoogleFonts.inter(
                  color: AppColors.accentLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              _SettingRow(
                icon: Icons.dark_mode_outlined,
                title: 'Theme',
                subtitle: 'Appearance mode',
                trailing: _Segmented<ThemeChoice>(
                  value: state.theme,
                  options: const {
                    ThemeChoice.light: 'Light',
                    ThemeChoice.dark: 'Dark',
                    ThemeChoice.system: 'System',
                  },
                  onChanged: state.setTheme,
                ),
              ),
              _SettingRow(
                icon: Icons.text_fields_rounded,
                title: 'Text Size',
                subtitle: 'Reading font size',
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _fontSizes[state.fontScale] ?? 'Custom',
                    style: GoogleFonts.inter(
                      color: AppColors.textBody,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                below: Row(
                  children: [
                    Text(
                      'Aa',
                      style: GoogleFonts.playfairDisplay(
                        color: AppColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppColors.accentLight,
                          inactiveTrackColor: AppColors.barInactive,
                          thumbColor: AppColors.accentLight,
                          overlayColor: AppColors.accent.withValues(
                            alpha: 0.15,
                          ),
                          trackHeight: 4,
                          showValueIndicator: ShowValueIndicator.never,
                        ),
                        child: Slider(
                          value: state.fontScale,
                          min: 0.875,
                          max: 1.25,
                          divisions: 3,
                          onChanged: state.setFontScale,
                        ),
                      ),
                    ),
                    Text(
                      'Aa',
                      style: GoogleFonts.playfairDisplay(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                      ),
                    ),
                  ],
                ),
              ),
              _SettingRow(
                icon: Icons.graphic_eq_rounded,
                title: 'Audio Brief Speed',
                subtitle: 'WAI narration playback',
                trailing: _Segmented<double>(
                  value: state.audioSpeed,
                  options: {1.0: '1x', 1.25: '1.25x', 1.5: '1.5x', 2.0: '2x'},
                  onChanged: state.setAudioSpeed,
                ),
              ),
              _SettingRow(
                icon: Icons.notifications_active_outlined,
                title: 'Notifications',
                subtitle: 'Key bulletins & breaking news',
                trailing: Switch(
                  value: state.notifications,
                  onChanged: state.setNotifications,
                  thumbColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected)
                        ? AppColors.accentDeep
                        : AppColors.textMuted,
                  ),
                  trackColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected)
                        ? AppColors.accentLight
                        : AppColors.surfaceAlt,
                  ),
                  trackOutlineColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                ),
              ),
              _SettingRow(
                icon: Icons.interests_outlined,
                title: 'Interests',
                subtitle: canEdit
                    ? 'Your Feed shows only these categories'
                    : 'Connect to the server to personalize your Feed',
                onTap: canEdit ? () => _editInterests(context) : null,
                trailing: canEdit
                    ? const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textMuted,
                      )
                    : const SizedBox.shrink(),
                below: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final i in interests) _Tag(i),
                        for (final f in state.follows) _Tag('+ ${f.name}'),
                        for (final t in topics.take(6))
                          _Tag(state.tagLabel(t), muted: true),
                        if (topics.length > 6)
                          _Tag('+${topics.length - 6}', muted: true),
                        if (interests.isEmpty)
                          Text(
                            'No interests selected yet.',
                            style: GoogleFonts.inter(
                              color: AppColors.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                    if (state.interestContext != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Your Feed helps you: “${state.interestContext}”',
                        style: GoogleFonts.sourceSerif4(
                          color: AppColors.textPrimary,
                          fontSize: 13.5,
                          fontStyle: FontStyle.italic,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if (state.interestSummary != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'WAI reads this as: “${state.interestSummary}”',
                        style: GoogleFonts.sourceSerif4(
                          color: AppColors.textMuted,
                          fontSize: 13.5,
                          fontStyle: FontStyle.italic,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _SettingRow(
                icon: Icons.language_rounded,
                title: 'Language',
                subtitle: 'Interface language',
                last: true,
                trailing: PopupMenuButton<String>(
                  tooltip: 'Choose language',
                  initialValue: state.language,
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  onSelected: state.setLanguage,
                  itemBuilder: (context) => [
                    for (final l in const ['English', 'Türkçe', 'Deutsch'])
                      PopupMenuItem(
                        value: l,
                        child: Text(
                          l,
                          style: GoogleFonts.inter(
                            color: AppColors.textPrimary,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.language,
                        style: GoogleFonts.inter(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(
                        Icons.expand_more_rounded,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: WebButton(
            label: 'Log out',
            icon: Icons.logout_rounded,
            primary: false,
            color: AppColors.dislike,
            onTap: state.logout,
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text(
            'WeOwnFeed © ${DateTime.now().year} · '
            'Privacy Policy',
            style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Opens the onboarding picker in a dialog; saving goes through
  /// `PUT /api/users/{id}/preferences`.
  Future<void> _editInterests(BuildContext context) {
    state.preferencesError = null;
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (context) => Dialog(
        backgroundColor: AppColors.background,
        insetPadding: const EdgeInsets.all(40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 880),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Edit interests',
                        style: GoogleFonts.playfairDisplay(
                          color: AppColors.textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.iconMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // The server rebuilds the interest vector from the new picks.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.dislike.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.dislike.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: AppColors.dislike,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Saving starts your Feed over from these choices. '
                          'What your likes have taught it so far will be '
                          'reset.',
                          style: GoogleFonts.inter(
                            color: AppColors.textBody,
                            fontSize: 13.5,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                InterestForm(
                  submitLabel: 'Save',
                  columns: 3,
                  initialMacros: state.interests,
                  initialMicros: state.interestTags,
                  initialFollows: state.follows,
                  initialContext: state.interestContext ?? '',
                  secondaryAction: WebButton(
                    label: 'Cancel',
                    primary: false,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  onSubmit: (macros, micros, follows, why) async {
                    final ok = await state.saveInterests(
                      macroTags: macros,
                      microTags: micros,
                      follows: follows,
                      context: why,
                    );
                    if (ok && context.mounted) Navigator.of(context).pop();
                    return ok;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.below,
    this.onTap,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final Widget? below;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, size: 20, color: AppColors.iconMuted),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              trailing,
            ],
          ),
          if (below != null) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(left: 58),
              child: Align(alignment: Alignment.centerLeft, child: below),
            ),
          ],
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: onTap == null
          ? content
          : Hoverable(
              onTap: onTap,
              builder: (context, hovered) => ColoredBox(
                color: hovered
                    ? AppColors.surfaceAlt.withValues(alpha: 0.5)
                    : Colors.transparent,
                child: content,
              ),
            ),
    );
  }
}

class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in options.entries)
            Hoverable(
              onTap: () => onChanged(e.key),
              builder: (context, hovered) {
                final selected = e.key == value;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.accentLight
                        : (hovered ? AppColors.surfaceAlt : null),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    e.value,
                    style: GoogleFonts.inter(
                      color: selected ? onAccent : AppColors.textBody,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.muted = false});

  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: muted ? AppColors.surfaceAlt : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          color: muted ? AppColors.textMuted : AppColors.accentLight,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
