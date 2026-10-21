import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_fonts/google_fonts.dart';

import 'screens/home_page.dart';
import 'theme/app_colors.dart';
import 'web/web_gate.dart';

void main() {
  // Fonts ship with the app (assets/google_fonts). Downloading them at run
  // time made the text change and shift on first load.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in [
      ('Inter', 'Inter'),
      ('Playfair Display', 'PlayfairDisplay'),
      ('Source Serif 4', 'SourceSerif4'),
    ]) {
      final text = await rootBundle.loadString(
        'assets/google_fonts/$file-OFL.txt',
      );
      yield LicenseEntryWithLineBreaks([family], text);
    }
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeOwnFeed',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ),
        splashColor: AppColors.accent.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
      ),
      // A separate UI per platform: a left-menu layout for the web (desktop),
      // a bottom-menu layout for the mobile apps.
      home: kIsWeb ? const WebGate() : const HomePage(),
    );
  }
}
