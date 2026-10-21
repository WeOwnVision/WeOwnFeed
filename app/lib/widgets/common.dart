import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Small UI pieces shared between screens.

/// Brand dot (logo, live indicator).
class AccentDot extends StatelessWidget {
  const AccentDot({super.key, this.size = 6});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      color: AppColors.accent,
      shape: BoxShape.circle,
    ),
  );
}

/// Round icon background (WAI, chats without an image).
class IconOrb extends StatelessWidget {
  const IconOrb({super.key, this.size = 32, this.child});

  final double size;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: AppColors.surfaceAlt,
      border: Border.all(color: AppColors.border),
    ),
    child: child,
  );
}

/// User avatar; falls back to an icon if [url] cannot load.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, this.size = 32, this.url});

  final double size;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(
      Icons.person_outline_rounded,
      size: size * 0.53,
      color: AppColors.textMuted,
    );
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.surfaceAlt,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? fallback
          : Image.network(
              url!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // The avatar server may not send CORS headers; use <img>.
              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

/// Story image: [path] is the link of the real image the server found
/// (`http…`) or a local placeholder. Decoded at its on-screen size; opening
/// 1200 px files at full size even for 50 px thumbnails made cards stutter
/// when they first appeared.
class NewsImage extends StatelessWidget {
  const NewsImage(this.path, {super.key, this.width, this.height});

  final String path;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = width ?? (c.hasBoundedWidth ? c.maxWidth : 1200.0);
        final h = height ?? (c.hasBoundedHeight ? c.maxHeight : 0.0);
        // BoxFit.cover crops, so in narrow areas the height matters too
        // (images are about 4:3). Steps of 100 px stop the same image from
        // being decoded again for every small size difference.
        final needed = math.max(w, h * 4 / 3) * ratio;
        final cacheWidth = ((needed / 100).ceil() * 100).clamp(100, 1200);
        if (path.startsWith('http://') || path.startsWith('https://')) {
          return Image.network(
            path,
            width: width,
            height: height,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            // If the publisher sends no CORS headers, the browser's <img> is used.
            webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
            errorBuilder: (_, _, _) => Image.asset(
              'assets/images/headline.jpg',
              width: width,
              height: height,
              fit: BoxFit.cover,
              cacheWidth: cacheWidth,
            ),
          );
        }
        return Image.asset(
          path,
          width: width,
          height: height,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
        );
      },
    );
  }
}

/// Standart koyu kart.
class WofCard extends StatelessWidget {
  const WofCard({super.key, required this.child, this.padding = 16});

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

/// "WOF•" logosu.
class WofLogo extends StatelessWidget {
  const WofLogo({super.key, this.fontSize = 20, this.text = 'WOF'});

  final double fontSize;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: GoogleFonts.playfairDisplay(
            color: AppColors.textPrimary,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        SizedBox(width: fontSize * 0.25),
        Padding(
          padding: EdgeInsets.only(bottom: fontSize * 0.2),
          child: AccentDot(size: fontSize * 0.27),
        ),
      ],
    );
  }
}

/// Mobile top bar: logo, search, notifications, profile.
class MobileTopBar extends StatelessWidget {
  const MobileTopBar({super.key});

  @override
  Widget build(BuildContext context) {
    Widget iconBtn(IconData icon) => InkResponse(
      onTap: () {},
      radius: 20,
      child: Icon(icon, color: AppColors.iconMuted, size: 21),
    );

    return Row(
      children: [
        const WofLogo(),
        const Spacer(),
        iconBtn(Icons.search_rounded),
        const SizedBox(width: 16),
        iconBtn(Icons.notifications_none_rounded),
        const SizedBox(width: 16),
        const UserAvatar(),
      ],
    );
  }
}

class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 38,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
      child: InkWell(
        customBorder: const CircleBorder(),
        hoverColor: AppColors.surfaceAlt,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: AppColors.iconMuted, size: size * 0.5),
        ),
      ),
    );
  }
}
