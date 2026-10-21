import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_colors.dart';

/// Floating, rounded bottom navigation bar.
class WofBottomNav extends StatelessWidget {
  const WofBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const items = <WofNavItem>[
    WofNavItem(Icons.home_outlined, Icons.home_rounded, 'Home'),
    WofNavItem(Icons.view_carousel_outlined, Icons.view_carousel, 'Feed'),
    WofNavItem(Icons.forum_outlined, Icons.forum, 'Chat', glow: true),
    WofNavItem(Icons.explore_outlined, Icons.explore, 'Discover'),
    WofNavItem(Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      padding: EdgeInsets.fromLTRB(
        22,
        8,
        22,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Container(
        height: 68,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: List.generate(items.length, (i) {
            final item = items[i];
            final selected = i == currentIndex;
            return Expanded(
              child: InkResponse(
                onTap: () => onTap(i),
                radius: 30,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: item.glow && !selected
                          ? BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  AppColors.accent.withValues(alpha: 0.35),
                                  AppColors.accent.withValues(alpha: 0.0),
                                ],
                              ),
                            )
                          : null,
                      child: Icon(
                        selected ? item.activeIcon : item.icon,
                        size: 22,
                        color: selected
                            ? AppColors.accentLight
                            : AppColors.iconMuted,
                      ),
                    ),
                    if (selected)
                      Text(
                        item.label,
                        style: GoogleFonts.inter(
                          color: AppColors.accentLight,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class WofNavItem {
  const WofNavItem(this.icon, this.activeIcon, this.label, {this.glow = false});

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool glow;
}
