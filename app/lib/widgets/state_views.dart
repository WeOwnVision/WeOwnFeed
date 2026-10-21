import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';
import '../theme/app_colors.dart';

/// Loading indicator; can take a description for long operations.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message, this.hint, this.padding = 48});

  final String? message;
  final String? hint;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: padding, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.accentLight,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: AppColors.textBody,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error + "Try again" button. If [error] is an [ApiException] its English
/// message is shown.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
  });

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  static String messageFor(Object error) => error is ApiException
      ? error.userMessage
      : 'Something went wrong. Please try again.';

  bool get _offline =>
      error is ApiException &&
      ((error as ApiException).kind == ApiErrorKind.unavailable ||
          (error as ApiException).kind == ApiErrorKind.network);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 16 : 48,
        horizontal: 16,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _offline ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
              size: compact ? 28 : 40,
              color: AppColors.dislike,
            ),
            SizedBox(height: compact ? 8 : 14),
            Text(
              messageFor(error),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: AppColors.textBody,
                fontSize: compact ? 13 : 14.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: compact ? 10 : 18),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentLight,
                  side: const BorderSide(color: AppColors.border),
                  textStyle: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Empty state message.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.playfairDisplay(
                color: AppColors.textPrimary,
                fontSize: 22,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: AppColors.textMuted,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
