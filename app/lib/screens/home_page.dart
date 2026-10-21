import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/home_cards.dart';
import '../widgets/state_views.dart';
import '../widgets/wof_bottom_nav.dart';

/// Home screen of the mobile app. The web UI lives under `lib/web/`.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _state = AppState.instance;
  int _navIndex = 0;

  void _onNav(int i) => setState(() => _navIndex = i);

  @override
  void initState() {
    super.initState();
    _state.loadBrief();
  }

  List<Widget> _cards() {
    final feed = _state.feed;
    if (feed.isEmpty) {
      return [
        if (_state.feedError != null)
          ErrorView(
            error: _state.feedError!,
            onRetry: () => _state.refreshFeed().then((_) => _state.loadBrief()),
          )
        else
          const LoadingView(message: 'Loading the latest stories…'),
      ];
    }
    return [
      DailySummaryCard(article: feed.first),
      const SizedBox(height: 18),
      WrittenSummaryCard(
        sources: _state.briefArticles,
        brief: _state.brief,
        loading: _state.briefLoading,
        error: _state.briefError,
        onRetry: _state.loadBrief,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListenableBuilder(
              listenable: _state,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
                children: [
                  const _MobileTopBar(),
                  const SizedBox(height: 18),
                  const _MobilePageHeader(),
                  const SizedBox(height: 20),
                  ..._cards(),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: WofBottomNav(currentIndex: _navIndex, onTap: _onNav),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small pieces
// ---------------------------------------------------------------------------
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      color: AppColors.mint,
      shape: BoxShape.circle,
    ),
  );
}

class _GradientOrb extends StatelessWidget {
  const _GradientOrb();

  static const double size = 36;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppColors.accentLight, AppColors.accentDeep],
      ),
    ),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar();

  static const double size = 34;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      color: AppColors.accentLight,
      shape: BoxShape.circle,
    ),
    child: Icon(
      Icons.person_outline_rounded,
      size: size * 0.53,
      color: const Color(0xFF4C3A86),
    ),
  );
}

// ---------------------------------------------------------------------------
// Mobile top bar: WOF logo, search, notifications, profile
// ---------------------------------------------------------------------------
class _MobileTopBar extends StatelessWidget {
  const _MobileTopBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'WOF',
          style: GoogleFonts.playfairDisplay(
            color: AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 6),
        const Padding(padding: EdgeInsets.only(bottom: 4), child: _Dot()),
        const Spacer(),
        _iconBtn(Icons.search_rounded),
        const SizedBox(width: 18),
        _iconBtn(Icons.notifications_none_rounded),
        const SizedBox(width: 18),
        const _Avatar(),
      ],
    );
  }

  Widget _iconBtn(IconData icon) => InkResponse(
    onTap: () {},
    radius: 22,
    child: Icon(icon, color: AppColors.iconMuted, size: 22),
  );
}

// ---------------------------------------------------------------------------
// Mobile page title: gradient circle + "Home" + date
// ---------------------------------------------------------------------------
class _MobilePageHeader extends StatelessWidget {
  const _MobilePageHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _GradientOrb(),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Home',
                style: GoogleFonts.playfairDisplay(
                  color: AppColors.textPrimary,
                  fontSize: 21,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Good morning · October 10',
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        // Balance the circle on the left so the title stays centered.
        const SizedBox(width: 36),
      ],
    );
  }
}
