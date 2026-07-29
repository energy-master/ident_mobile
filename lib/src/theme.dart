/// Visual language, carried over from the web app so the two read as one product.
///
/// The palette is lifted from styles.css and dashboard.php: the near-black
/// #0b0d12 shell the spectrogram tiles sit on, and the three status-light
/// colours used for the stream dots. Keeping these numerically identical
/// matters — an operator glancing between a desktop dashboard and a phone
/// should not have to re-learn what amber means.
library;

import 'package:flutter/material.dart';

import 'models.dart';

abstract final class IdentColors {
  /// Dashboard shell background (dashboard.php).
  static const shell = Color(0xFF0B0D12);
  static const surface = Color(0xFF141821);
  static const surfaceRaised = Color(0xFF1C2230);

  /// Status lights (styles.css .stream-dot).
  static const ok = Color(0xFF4CAF72);
  static const warn = Color(0xFFE0A32E);
  static const error = Color(0xFFE0524A);
  static const idle = Color(0xFF6C757D);

  /// Accent — the blue used for focus rings in the web app.
  static const accent = Color(0xFF6EA8FE);

  static const textPrimary = Color(0xFFE9ECEF);
  static const textSecondary = Color(0xFFAEB8C6);

  static Color forStatus(CheckStatus s) => switch (s) {
        CheckStatus.ok => ok,
        CheckStatus.warn => warn,
        CheckStatus.error => error,
      };
}

ThemeData buildIdentTheme() {
  const scheme = ColorScheme.dark(
    primary: IdentColors.accent,
    secondary: IdentColors.ok,
    surface: IdentColors.surface,
    error: IdentColors.error,
    onPrimary: Color(0xFF06121F),
    onSurface: IdentColors.textPrimary,
    onError: Color(0xFF2A0A08),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: IdentColors.shell,
    appBarTheme: const AppBarTheme(
      backgroundColor: IdentColors.shell,
      foregroundColor: IdentColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: IdentColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0x2AFFFFFF)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: IdentColors.surfaceRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0x2AFFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0x2AFFFFFF)),
      ),
    ),
    dividerColor: const Color(0x1FFFFFFF),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: IdentColors.textPrimary),
      bodySmall: TextStyle(color: IdentColors.textSecondary),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: IdentColors.accent,
    ),
  );
}
