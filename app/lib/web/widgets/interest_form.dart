import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/api_models.dart';
import '../../services/api_service.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../widgets/state_views.dart';
import 'web_ui.dart';

/// Interest picker: categories, subtopic tags of the chosen categories,
/// "+" follows and the optional "why" sentence.
///
/// Options come from `GET /api/taxonomy` (a fixed list in the server's code).
/// Used on the onboarding screen and in the Profile editor dialog.
class InterestForm extends StatefulWidget {
  const InterestForm({
    super.key,
    required this.submitLabel,
    required this.onSubmit,
    this.initialMacros = const [],
    this.initialMicros = const [],
    this.initialFollows = const [],
    this.initialContext = '',
    this.secondaryAction,
    this.columns,
    this.stepped = false,
    this.headerBuilder,
  });

  final String submitLabel;

  /// Chosen categories (in pick order), subtopic tags, "+" follows and the
  /// "why" sentence ('' if empty; the server uses its standard sentence).
  /// Returns `true` when saving succeeded.
  final Future<bool> Function(
    List<String> macros,
    List<String> micros,
    List<UserFollow> follows,
    String context,
  )
  onSubmit;
  final List<String> initialMacros;
  final List<String> initialMicros;
  final List<UserFollow> initialFollows;
  final String initialContext;

  /// Left of the submit button (e.g. "Cancel").
  final Widget? secondaryAction;

  /// Number of category card columns; picked from the width if not given.
  final int? columns;

  /// Onboarding: each section is its own animated step. The Profile editor
  /// dialog shows all of them on one page.
  final bool stepped;

  /// Each step's heading in [stepped] mode (0: categories, 1: topics,
  /// 2: "+" follows, 3: sites, 4: sentence). The sections then skip their
  /// own headings.
  final Widget Function(int step)? headerBuilder;

  /// Most subtopic tags the server accepts.
  static const maxTopics = 12;

  /// One-tap examples for the "why" sentence.
  static const contextExamples = [
    'I invest',
    'I build products',
    'I study this',
    'I just follow the news',
  ];

  @override
  State<InterestForm> createState() => _InterestFormState();
}

class _InterestFormState extends State<InterestForm> {
  final _state = AppState.instance;

  /// Pick order is kept: the server builds the daily brief from the first category.
  late final LinkedHashSet<String> _macros = LinkedHashSet.of(
    widget.initialMacros,
  );
  late final Set<String> _micros = {...widget.initialMicros};
  bool _limitHit = false;

  /// "+" follows: a company, product or person the user types in.
  late final List<UserFollow> _follows = [...widget.initialFollows];
  final _followCtrl = TextEditingController();
  String? _followMacro;
  String? _followError;

  /// "Follow a site": the address field. Sites are saved at once (AppState).
  final _siteCtrl = TextEditingController();

  /// "Why" sentence: the feed ranks stories close in meaning to it higher.
  late final _contextCtrl = TextEditingController(text: widget.initialContext);

  /// The step and transition direction in [InterestForm.stepped] mode.
  int _step = 0;
  bool _forward = true;
  static const _lastStep = 4;

  /// The steps shown: offline sessions skip "+" follows (2) and sites (3),
  /// which need the server.
  List<int> get _shownSteps =>
      _state.isLive ? const [0, 1, 2, 3, 4] : const [0, 1, 4];

  /// The shown step before (-1) or after (+1) the current one.
  int _stepBy(int delta) {
    final steps = _shownSteps;
    final i = steps.indexOf(_step);
    return steps[(i < 0 ? 0 : i + delta).clamp(0, steps.length - 1)];
  }

  static final _urlish = RegExp(
    r'https?://|www\.|\.(com|net|org|io)\b',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _state.loadTaxonomy();
  }

  @override
  void dispose() {
    _followCtrl.dispose();
    _siteCtrl.dispose();
    _contextCtrl.dispose();
    super.dispose();
  }

  /// Category a follow attaches to: the chosen one, else the first picked category.
  String? _followMacroFor(List<String> macros) =>
      macros.contains(_followMacro) ? _followMacro : macros.firstOrNull;

  /// Same validation as the server's rules; errors show in the form.
  void _addFollow(List<TaxonomyCategory> taxonomy) {
    final name = _followCtrl.text.trim().split(RegExp(r'\s+')).join(' ');
    final macro = _followMacroFor(_selectedMacros(taxonomy));
    final draft = UserFollow(name: name, macro: macro ?? '');
    final String? error;
    if (macro == null) {
      error = 'Pick a category above first.';
    } else if (name.length < 2 || name.length > 40) {
      error = 'Use 2 to 40 characters.';
    } else if (_urlish.hasMatch(name)) {
      error = 'Type a name, not a link.';
    } else if (_follows.any((f) => f.key == draft.key)) {
      error = '$name is already in your list.';
    } else if (_follows.length >= ApiService.maxFollows) {
      error = 'You can follow up to ${ApiService.maxFollows} things.';
    } else {
      error = null;
    }
    setState(() {
      _followError = error;
      if (error == null) {
        _follows.add(draft);
        _followCtrl.clear();
      }
    });
  }

  /// A follow whose category is no longer picked moves to the first picked one.
  List<UserFollow> _followsFor(List<String> macros) => [
    for (final f in _follows)
      macros.contains(f.macro)
          ? f
          : UserFollow(id: f.id, name: f.name, macro: macros.first),
  ];

  /// Only subtopic tags of the picked categories, in taxonomy order.
  List<String> _selectedMicros(List<TaxonomyCategory> taxonomy) => [
    for (final c in taxonomy)
      if (_macros.contains(c.macro))
        for (final t in c.microTags)
          if (_micros.contains(t.tag)) t.tag,
  ];

  /// Old categories missing from the taxonomy are not sent.
  List<String> _selectedMacros(List<TaxonomyCategory> taxonomy) {
    final known = {for (final c in taxonomy) c.macro};
    return [
      for (final m in _macros)
        if (known.contains(m)) m,
    ];
  }

  void _toggleMacro(String macro) => setState(() {
    if (!_macros.remove(macro)) _macros.add(macro);
    _limitHit = false;
  });

  void _toggleMicro(List<TaxonomyCategory> taxonomy, String tag) =>
      setState(() {
        if (_micros.remove(tag)) {
          _limitHit = false;
          return;
        }
        if (_selectedMicros(taxonomy).length >= InterestForm.maxTopics) {
          _limitHit = true;
          return;
        }
        _micros.add(tag);
      });

  /// When the step changes the page scrolls to the top; the new step starts there.
  void _goTo(int step) {
    setState(() {
      _forward = step > _step;
      _step = step;
    });
    Scrollable.maybeOf(context)?.position.animateTo(
      0,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _submit(List<TaxonomyCategory> taxonomy) async {
    final macros = _selectedMacros(taxonomy);
    if (macros.isEmpty || _state.savingPreferences) return;
    await widget.onSubmit(
      macros,
      _selectedMicros(taxonomy),
      _followsFor(macros),
      _contextCtrl.text.trim().split(RegExp(r'\s+')).join(' '),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final taxonomy = _state.taxonomy;
        if (taxonomy == null) {
          final error = _state.taxonomyError;
          return error != null
              ? ErrorView(error: error, onRetry: _state.loadTaxonomy)
              : const LoadingView(message: 'Loading topics…');
        }
        if (widget.stepped) return _steppedBody(taxonomy);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CategoryGrid(
              taxonomy: taxonomy,
              selected: _macros,
              columns: widget.columns,
              onToggle: _toggleMacro,
            ),
            const SizedBox(height: 32),
            _topics(taxonomy),
            const SizedBox(height: 14),
            // "+" follows and sites need the server.
            if (_state.isLive) ...[
              _followSection(taxonomy),
              const SizedBox(height: 32),
              _siteSection(),
              const SizedBox(height: 32),
            ],
            _contextSection(),
            const SizedBox(height: 28),
            _footer(taxonomy),
          ],
        );
      },
    );
  }

  /// Onboarding: categories → topics → "+" follows → sites → sentence, one
  /// per screen. Steps slide and fade; going forward they come from the
  /// right, going back from the left.
  Widget _steppedBody(List<TaxonomyCategory> taxonomy) {
    final body = switch (_step) {
      0 => _CategoryGrid(
        taxonomy: taxonomy,
        selected: _macros,
        columns: widget.columns,
        onToggle: _toggleMacro,
        animateIn: true,
      ),
      1 => _topics(taxonomy, showHeading: false),
      2 => _followSection(taxonomy, showHeading: false),
      3 => _siteSection(showHeading: false),
      _ => _contextSection(showHeading: false),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.passthrough,
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            transitionBuilder: (child, animation) {
              final incoming = child.key == ValueKey(_step);
              final dx = incoming == _forward ? 0.06 : -0.06;
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: Offset(dx, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.headerBuilder != null) ...[
                    widget.headerBuilder!(_step),
                    const SizedBox(height: 32),
                  ],
                  body,
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _footer(taxonomy),
      ],
    );
  }

  /// Count shown instead of the heading in [InterestForm.stepped] mode;
  /// [warning] replaces it in red.
  Widget _counter(String text, {String? warning}) => Text(
    warning ?? text,
    style: GoogleFonts.inter(
      color: warning != null ? AppColors.dislike : AppColors.textMuted,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _topics(List<TaxonomyCategory> taxonomy, {bool showHeading = true}) {
    final chosen = [
      for (final c in taxonomy)
        if (_macros.contains(c.macro)) c,
    ];
    final count = _selectedMicros(taxonomy).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!showHeading)
          _counter(
            '$count / ${InterestForm.maxTopics} topics',
            warning: _limitHit
                ? 'Up to ${InterestForm.maxTopics} topics. Remove one first.'
                : null,
          )
        else ...[
          Row(
            children: [
              Text(
                'Fine-tune with topics',
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              const OverlineLabel('Optional'),
              const Spacer(),
              Text(
                '$count / ${InterestForm.maxTopics} topics',
                style: GoogleFonts.inter(
                  color: _limitHit ? AppColors.dislike : AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _limitHit
                ? 'You can pick up to ${InterestForm.maxTopics} topics. '
                      'Remove one to add another.'
                : 'Stories tagged with these topics rank higher in your Feed.',
            style: GoogleFonts.inter(
              color: _limitHit ? AppColors.dislike : AppColors.textMuted,
              fontSize: 13.5,
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (chosen.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              'Pick a category above to see its topics.',
              style: GoogleFonts.inter(
                color: AppColors.textMuted,
                fontSize: 13.5,
              ),
            ),
          )
        else
          for (final c in chosen)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OverlineLabel(c.displayName, color: categoryColor(c.macro)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in c.microTags)
                        PillButton(
                          label: t.label,
                          selected: _micros.contains(t.tag),
                          showCheck: true,
                          dense: true,
                          onTap: () => _toggleMicro(taxonomy, t.tag),
                        ),
                    ],
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// Following a specific company, product or person with "+".
  Widget _followSection(
    List<TaxonomyCategory> taxonomy, {
    bool showHeading = true,
  }) {
    final macros = _selectedMacros(taxonomy);
    final macro = _followMacroFor(macros);
    final full = _follows.length >= ApiService.maxFollows;
    final enabled = macros.isNotEmpty && !full;
    final names = {for (final c in taxonomy) c.macro: c.displayName};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!showHeading)
          _counter('${_follows.length} / ${ApiService.maxFollows}')
        else ...[
          Row(
            children: [
              Text(
                'Follow something specific',
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              const OverlineLabel('Optional'),
              const Spacer(),
              Text(
                '${_follows.length} / ${ApiService.maxFollows}',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'A company, product or person. Stories that mention it come first.',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 13.5,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _followCtrl,
                  enabled: enabled,
                  maxLength: 40,
                  onSubmitted: (_) => _addFollow(taxonomy),
                  cursorColor: AppColors.accentLight,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                  ),
                  decoration: _inputDecoration(
                    macros.isEmpty
                        ? 'Pick a category above first'
                        : full
                        ? 'You follow ${ApiService.maxFollows} things'
                        : 'Type a name, e.g. OpenAI',
                    prefixIcon: const Icon(
                      Icons.add_rounded,
                      color: AppColors.iconMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // The follow's category; adds context to the query ("Revolut finance").
              PopupMenuButton<String>(
                enabled: enabled && macros.length > 1,
                tooltip: 'Category',
                color: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: AppColors.border),
                ),
                onSelected: (m) => setState(() => _followMacro = m),
                itemBuilder: (context) => [
                  for (final m in macros)
                    PopupMenuItem(
                      value: m,
                      child: Text(
                        names[m] ?? m,
                        style: GoogleFonts.inter(
                          color: AppColors.textPrimary,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        macro ?? 'Category',
                        style: GoogleFonts.inter(
                          color: macro == null
                              ? AppColors.textMuted
                              : categoryColor(macro),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (macros.length > 1)
                        const Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              WebButton(
                label: 'Add',
                primary: false,
                onTap: () => _addFollow(taxonomy),
              ),
            ],
          ),
        ),
        if (_followError != null) ...[
          const SizedBox(height: 8),
          Text(
            _followError!,
            style: GoogleFonts.inter(color: AppColors.dislike, fontSize: 13),
          ),
        ],
        if (_follows.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _followsFor(macros.isEmpty ? [''] : macros))
                _FollowChip(
                  follow: f,
                  onRemove: () => setState(() {
                    _follows.removeWhere((x) => x.key == f.key);
                    _followError = null;
                  }),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _addSite() async {
    if (await _state.addSite(_siteCtrl.text)) _siteCtrl.clear();
  }

  /// "Follow a site": a newsroom or blog without RSS. The server maps the
  /// site with Tavily Map, adds the newest posts to the feed with Crawl, then
  /// checks for new posts once a day. Adding and removing are saved at once.
  Widget _siteSection({bool showHeading = true}) {
    final sites = _state.sites;
    final full = sites.length >= ApiService.maxSites;
    final enabled = _state.hasServerUser && !full && !_state.addingSite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!showHeading)
          _counter('${sites.length} / ${ApiService.maxSites}')
        else ...[
          Row(
            children: [
              Text(
                'Follow a site',
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 12),
              const OverlineLabel('Optional'),
              const Spacer(),
              Text(
                '${sites.length} / ${ApiService.maxSites}',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Any newsroom or blog, even without RSS.',
            style: GoogleFonts.inter(
              color: AppColors.textMuted,
              fontSize: 13.5,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Opacity(
          opacity: enabled || _state.addingSite ? 1 : 0.5,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _siteCtrl,
                  enabled: enabled,
                  onSubmitted: (_) => _addSite(),
                  cursorColor: AppColors.accentLight,
                  style: GoogleFonts.inter(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                  ),
                  decoration: _inputDecoration(
                    full
                        ? 'You follow ${ApiService.maxSites} sites'
                        : 'Paste a site address, e.g. anthropic.com/news',
                    prefixIcon: const Icon(
                      Icons.language_rounded,
                      color: AppColors.iconMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (_state.addingSite)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 22),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.accentLight,
                    ),
                  ),
                )
              else
                WebButton(label: 'Follow', primary: false, onTap: _addSite),
            ],
          ),
        ),
        if (_state.siteError != null) ...[
          const SizedBox(height: 8),
          Text(
            _state.siteError!,
            style: GoogleFonts.inter(color: AppColors.dislike, fontSize: 13),
          ),
        ],
        if (sites.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final site in sites)
                _SiteChip(site: site, onRemove: () => _state.removeSite(site)),
            ],
          ),
        ],
      ],
    );
  }

  /// "What should your feed help you with?": one optional sentence, in any
  /// language. The server translates it to English and builds the interest
  /// vector from it. With [showHeading] false the step's own title is the heading.
  Widget _contextSection({bool showHeading = true}) {
    return ListenableBuilder(
      listenable: _contextCtrl,
      builder: (context, _) {
        final text = _contextCtrl.text.trim();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeading) ...[
              Row(
                children: [
                  Flexible(
                    child: Text(
                      'What should your feed help you with?',
                      style: GoogleFonts.playfairDisplay(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const OverlineLabel('Optional'),
                  const Spacer(),
                  Text(
                    '${_contextCtrl.text.length} / ${ApiService.maxContextChars}',
                    style: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'One sentence, in any language. Stories closer to it rank '
                'higher in your Feed.',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _contextCtrl,
              autofocus: !showHeading,
              maxLength: ApiService.maxContextChars,
              minLines: 1,
              maxLines: 3,
              cursorColor: AppColors.accentLight,
              style: GoogleFonts.inter(
                color: AppColors.textPrimary,
                fontSize: 14.5,
              ),
              decoration: _inputDecoration(
                'e.g. I invest in fintech and want early signals on IPOs',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final example in InterestForm.contextExamples)
                  PillButton(
                    label: example,
                    dense: true,
                    selected: text == example,
                    onTap: () =>
                        _contextCtrl.text = text == example ? '' : example,
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Shared look of the form's text fields.
  InputDecoration _inputDecoration(String hint, {Widget? prefixIcon}) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.border),
    );
    return InputDecoration(
      hintText: hint,
      counterText: '',
      isDense: true,
      hintStyle: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 14.5),
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: AppColors.surface,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: AppColors.accent),
      ),
    );
  }

  Widget _footer(List<TaxonomyCategory> taxonomy) {
    final macros = _selectedMacros(taxonomy);
    final topics = _selectedMicros(taxonomy).length;
    final error = _state.preferencesError;
    final saving = _state.savingPreferences;
    final last = !widget.stepped || _step == _lastStep;
    final back = widget.stepped && _step > 0;

    final String summary;
    if (macros.isEmpty) {
      summary = 'Pick at least one category to continue.';
    } else {
      summary = [
        'Your Feed: ${macros.join(', ')}',
        if (topics > 0) '$topics topic${topics == 1 ? '' : 's'}',
        if (_follows.isNotEmpty)
          'following ${_follows.map((f) => f.name).join(', ')}',
      ].join(' · ');
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary,
                  style: GoogleFonts.inter(
                    color: macros.isEmpty
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (macros.isNotEmpty && !widget.stepped) ...[
                  const SizedBox(height: 3),
                  Text(
                    'Your Daily Brief covers ${macros.first}, your first pick.',
                    style: GoogleFonts.inter(
                      color: AppColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    error.userMessage,
                    style: GoogleFonts.inter(
                      color: AppColors.dislike,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (back) ...[
            const SizedBox(width: 12),
            WebButton(
              label: 'Back',
              primary: false,
              onTap: () => _goTo(_stepBy(-1)),
            ),
          ] else if (widget.secondaryAction != null) ...[
            const SizedBox(width: 12),
            widget.secondaryAction!,
          ],
          const SizedBox(width: 12),
          if (saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.accentLight,
                ),
              ),
            )
          else
            Opacity(
              opacity: macros.isEmpty ? 0.4 : 1,
              child: IgnorePointer(
                ignoring: macros.isEmpty,
                child: WebButton(
                  label: last ? widget.submitLabel : 'Next',
                  icon: Icons.arrow_forward_rounded,
                  onTap: last
                      ? () => _submit(taxonomy)
                      : () => _goTo(_stepBy(1)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Chip of a followed thing: name, category and a remove button.
class _FollowChip extends StatelessWidget {
  const _FollowChip({required this.follow, required this.onRemove});

  final UserFollow follow;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(follow.macro);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            follow.name,
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (follow.macro.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              follow.macro,
              style: GoogleFonts.inter(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(width: 4),
          Tooltip(
            message: 'Stop following ${follow.name}',
            child: Hoverable(
              onTap: onRemove,
              builder: (context, hovered) => Icon(
                Icons.close_rounded,
                size: 16,
                color: hovered ? AppColors.textPrimary : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A followed site: domain, scan status and a remove button.
class _SiteChip extends StatelessWidget {
  const _SiteChip({required this.site, required this.onRemove});

  final FollowedSite site;
  final VoidCallback onRemove;

  String get _statusText => switch (site.status) {
    'pending' => 'Queued',
    'mapping' => 'Mapping the site…',
    'crawling' => 'Reading newest posts…',
    'ready' => site.articleCount == 1 ? '1 post' : '${site.articleCount} posts',
    'no_articles' => 'No posts found',
    _ => "Couldn't scan",
  };

  @override
  Widget build(BuildContext context) {
    final problem = site.status == 'no_articles' || site.status == 'failed';
    final color = problem ? AppColors.dislike : AppColors.mint;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            site.name,
            style: GoogleFonts.inter(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          if (site.isWorking) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            _statusText,
            style: GoogleFonts.inter(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: 'Stop following ${site.name}',
            child: Hoverable(
              onTap: onRemove,
              builder: (context, hovered) => Icon(
                Icons.close_rounded,
                size: 16,
                color: hovered ? AppColors.textPrimary : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon per category.
IconData categoryIcon(String macro) => switch (macro) {
  'Tech' => Icons.code_rounded,
  'AI' => Icons.auto_awesome_rounded,
  'Hardware' => Icons.memory_rounded,
  'Automotive' => Icons.electric_car_rounded,
  'Gaming' => Icons.sports_esports_rounded,
  'Finance' => Icons.trending_up_rounded,
  'Science' => Icons.science_rounded,
  _ => Icons.label_outline_rounded,
};

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({
    required this.taxonomy,
    required this.selected,
    required this.onToggle,
    this.columns,
    this.animateIn = false,
  });

  final List<TaxonomyCategory> taxonomy;
  final LinkedHashSet<String> selected;
  final ValueChanged<String> onToggle;
  final int? columns;

  /// Cards rise in from below one after another (onboarding).
  final bool animateIn;

  @override
  Widget build(BuildContext context) {
    const gap = 16.0;
    return LayoutBuilder(
      builder: (context, c) {
        final cols =
            columns ?? ((c.maxWidth + gap) ~/ (240 + gap)).clamp(1, 4).toInt();
        final first = selected.isEmpty ? null : selected.first;
        // Row by row, equal width and fixed height: the longest title (2
        // lines) and description (4 lines) fit. IntrinsicHeight measured the
        // text too short here and pushed the description out of the card.
        final rows = [
          for (var i = 0; i < taxonomy.length; i += cols)
            taxonomy.sublist(i, math.min(i + cols, taxonomy.length)),
        ];
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              SizedBox(
                height: _CategoryCard.height,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  // Empty slots in the last row are filled with empty columns.
                  children: [
                    for (var i = 0; i < cols; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
                      Expanded(
                        child: i < rows[r].length
                            ? _card(rows[r][i], first, r * cols + i)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _card(TaxonomyCategory cat, String? first, int index) {
    final card = _CategoryCard(
      category: cat,
      selected: selected.contains(cat.macro),
      isFirst: cat.macro == first,
      onTap: () => onToggle(cat.macro),
    );
    if (!animateIn) return card;
    return _RiseIn(
      delay: Duration(milliseconds: 120 + 70 * index),
      child: card,
    );
  }
}

/// After [delay], rises from below and fades in; only on the first build.
class _RiseIn extends StatefulWidget {
  const _RiseIn({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<_RiseIn> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 460);
    return AnimatedSlide(
      offset: _shown ? Offset.zero : const Offset(0, 0.15),
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.selected,
    required this.isFirst,
    required this.onTap,
  });

  /// Fits an icon, a 2-line title and a 4-line description.
  static const double height = 204;

  final TaxonomyCategory category;
  final bool selected;

  /// The first picked category becomes the topic of the daily brief.
  final bool isFirst;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(category.macro);
    return Semantics(
      button: true,
      selected: selected,
      label: category.displayName,
      child: Hoverable(
        onTap: onTap,
        builder: (context, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 18),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.10)
                : (hovered ? AppColors.surfaceAlt : AppColors.surface),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.75)
                  : (hovered
                        ? AppColors.textMuted.withValues(alpha: 0.5)
                        : AppColors.border),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      categoryIcon(category.macro),
                      size: 20,
                      color: color,
                    ),
                  ),
                  const Spacer(),
                  if (isFirst) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.mint.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Daily Brief',
                        style: GoogleFonts.inter(
                          color: AppColors.mint,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? color : Colors.transparent,
                      border: Border.all(
                        color: selected ? color : AppColors.barInactive,
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? const Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: AppColors.background,
                          )
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                category.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  color: AppColors.textPrimary,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                category.description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
