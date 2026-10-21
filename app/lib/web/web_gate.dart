import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../widgets/common.dart';
import '../widgets/state_views.dart';
import 'pages/web_onboarding_page.dart';
import 'web_shell.dart';
import 'widgets/web_ui.dart';

/// Web entry: the sign-in screen without a session; [WebOnboardingPage]
/// if no interests are picked; [WebShell] when both are done.
class WebGate extends StatefulWidget {
  const WebGate({super.key});

  @override
  State<WebGate> createState() => _WebGateState();
}

class _WebGateState extends State<WebGate> {
  final _state = AppState.instance;

  @override
  void initState() {
    super.initState();
    _state.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        // Screens change (e.g. from sign-in to picking categories) with a
        // fade and a slight zoom.
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.97, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: _page(),
        );
      },
    );
  }

  Widget _page() {
    if (_state.user != null) {
      // If the server returned `onboarding_completed: false`, the 3-step
      // onboarding (pick → taste check → your feed is ready) runs.
      return _state.showOnboarding
          ? const WebOnboardingPage(key: ValueKey('onboarding'))
          : const WebShell(key: ValueKey('shell'));
    }
    if (_state.sessionLoading) {
      return const Scaffold(
        key: ValueKey('loading'),
        backgroundColor: AppColors.background,
        body: LoadingView(message: 'Signing you in…'),
      );
    }
    return _LoginScreen(key: const ValueKey('login'), state: _state);
  }
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({super.key, required this.state});

  final AppState state;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  late final _username = TextEditingController(
    text: widget.state.lastUsername ?? '',
  );
  final _password = TextEditingController();
  bool _createAccount = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _username.text.trim();
    if (name.isEmpty || _password.text.isEmpty || widget.state.loggingIn) {
      return;
    }
    widget.state.login(name, _password.text, createAccount: _createAccount);
  }

  InputDecoration _decoration(String hint, IconData icon, {Widget? suffix}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color),
    );
    return InputDecoration(
      hintText: hint,
      counterText: '',
      hintStyle: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 15),
      prefixIcon: Icon(icon, color: AppColors.iconMuted),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.surfaceAlt,
      enabledBorder: border(AppColors.border),
      disabledBorder: border(AppColors.border),
      focusedBorder: border(AppColors.accent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final error = state.sessionError;
    final offline =
        error != null &&
        (error.kind == ApiErrorKind.unavailable ||
            error.kind == ApiErrorKind.network);
    final fieldStyle = GoogleFonts.inter(
      color: AppColors.textPrimary,
      fontSize: 15,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: PanelCard(
              padding: const EdgeInsets.fromLTRB(36, 40, 36, 36),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const WofLogo(fontSize: 34),
                    const SizedBox(height: 6),
                    Text(
                      "We don't follow blogs. We follow topics.",
                      style: GoogleFonts.inter(
                        color: AppColors.textMuted,
                        fontSize: 13,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      _createAccount ? 'Create your account' : 'Welcome back',
                      style: GoogleFonts.playfairDisplay(
                        color: AppColors.textPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _createAccount
                          ? 'Pick a username and a password of at least 8 '
                                'characters.'
                          : 'Sign in to open your feed.',
                      style: GoogleFonts.inter(
                        color: AppColors.textBody,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _username,
                      autofocus: _username.text.isEmpty,
                      enabled: !state.loggingIn,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      maxLength: 32,
                      cursorColor: AppColors.accentLight,
                      style: fieldStyle,
                      decoration: _decoration(
                        'Username',
                        Icons.person_outline_rounded,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      autofocus: _username.text.isNotEmpty,
                      enabled: !state.loggingIn,
                      obscureText: !_showPassword,
                      autofillHints: [
                        _createAccount
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      onSubmitted: (_) => _submit(),
                      maxLength: 128,
                      cursorColor: AppColors.accentLight,
                      style: fieldStyle,
                      decoration: _decoration(
                        'Password',
                        Icons.lock_outline_rounded,
                        suffix: IconButton(
                          tooltip: _showPassword
                              ? 'Hide password'
                              : 'Show password',
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: AppColors.iconMuted,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            offline
                                ? Icons.cloud_off_rounded
                                : Icons.error_outline_rounded,
                            size: 18,
                            color: AppColors.dislike,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error.userMessage,
                              style: GoogleFonts.inter(
                                color: AppColors.dislike,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: state.loggingIn
                          ? const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppColors.accentLight,
                                ),
                              ),
                            )
                          : WebButton(
                              label: offline
                                  ? 'Try again'
                                  : _createAccount
                                  ? 'Create account'
                                  : 'Sign in',
                              icon: Icons.arrow_forward_rounded,
                              onTap: _submit,
                            ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: LinkButton(
                        _createAccount
                            ? 'I already have an account'
                            : 'New here? Create an account',
                        onTap: () {
                          if (state.loggingIn) return;
                          setState(() => _createAccount = !_createAccount);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
