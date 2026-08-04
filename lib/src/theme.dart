/// Visual language, carried over from the web app so the two read as one product.
///
/// The dark palette is lifted from styles.css and dashboard.php: the near-black
/// shell the spectrogram tiles sit on, and the status-light colours used for
/// the stream dots. Keeping these numerically identical matters — an operator
/// glancing between a desktop dashboard and a phone should not have to re-learn
/// what amber means.
///
/// The light palette is derived from the same reference: shell/surface flip to
/// paper tones, text inverts, and the status colours pick their higher-contrast
/// variants so a dot stays legible on white the same way it does on black.
///
/// Callers reach the current palette via `identColors(context)` rather than a
/// static class, so a theme swap actually recolours the app. The palette is
/// carried as a Material [ThemeExtension] so widgets that live below a nested
/// [Theme] inherit the right one.
library;

import 'package:flutter/material.dart';

import 'models.dart';

/// The colours a screen may need to reach for that Material's [ColorScheme]
/// does not carry — the near-black shell distinct from surface, the status
/// lights, an idle grey that is neither disabled nor error.
@immutable
class IdentPalette {
  const IdentPalette({
    required this.shell,
    required this.surface,
    required this.surfaceRaised,
    required this.ok,
    required this.warn,
    required this.error,
    required this.idle,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.onAccent,
    required this.hairline,
  });

  /// Dashboard shell background — sits behind the surface cards.
  final Color shell;
  final Color surface;
  final Color surfaceRaised;

  /// Status lights, matching styles.css `.stream-dot`.
  final Color ok;
  final Color warn;
  final Color error;
  final Color idle;

  /// The blue used for focus rings and primary actions in the web app.
  final Color accent;

  final Color textPrimary;
  final Color textSecondary;

  /// Ink on top of an accent-filled cell — used when a heatmap cell is dark
  /// enough that light text would wash out.
  final Color onAccent;

  /// The one-pixel divider colour used throughout — a low-alpha white on dark,
  /// a low-alpha black on light, so it reads as a hairline either way.
  final Color hairline;

  Color forStatus(CheckStatus s) => switch (s) {
        CheckStatus.ok => ok,
        CheckStatus.warn => warn,
        CheckStatus.error => error,
      };
}

/// The dark palette — the original desktop look, and the mobile default.
const IdentPalette _darkPalette = IdentPalette(
  shell: Color(0xFF0B0D12),
  surface: Color(0xFF141821),
  surfaceRaised: Color(0xFF1C2230),
  ok: Color(0xFF4CAF72),
  warn: Color(0xFFE0A32E),
  error: Color(0xFFE0524A),
  idle: Color(0xFF6C757D),
  accent: Color(0xFF6EA8FE),
  textPrimary: Color(0xFFE9ECEF),
  textSecondary: Color(0xFFAEB8C6),
  onAccent: Color(0xFF06121F),
  hairline: Color(0x1FFFFFFF),
);

/// The light palette — the same shapes, on paper.
///
/// The greens/ambers/reds are shifted a touch darker than their dark-mode
/// counterparts so a status dot on a white lane still has the contrast it
/// carries on the near-black shell.
const IdentPalette _lightPalette = IdentPalette(
  shell: Color(0xFFF5F6F8),
  surface: Color(0xFFFFFFFF),
  surfaceRaised: Color(0xFFF0F2F5),
  ok: Color(0xFF2F8F52),
  warn: Color(0xFFB07B12),
  error: Color(0xFFC0392E),
  idle: Color(0xFF6C757D),
  accent: Color(0xFF2B6CDA),
  textPrimary: Color(0xFF15181F),
  textSecondary: Color(0xFF525A66),
  onAccent: Color(0xFFFFFFFF),
  hairline: Color(0x1F000000),
);

class IdentPaletteExt extends ThemeExtension<IdentPaletteExt> {
  const IdentPaletteExt(this.palette);
  final IdentPalette palette;

  @override
  IdentPaletteExt copyWith({IdentPalette? palette}) =>
      IdentPaletteExt(palette ?? this.palette);

  @override
  IdentPaletteExt lerp(ThemeExtension<IdentPaletteExt>? other, double t) {
    if (other is! IdentPaletteExt) return this;
    return IdentPaletteExt(
      IdentPalette(
        shell: Color.lerp(palette.shell, other.palette.shell, t)!,
        surface: Color.lerp(palette.surface, other.palette.surface, t)!,
        surfaceRaised:
            Color.lerp(palette.surfaceRaised, other.palette.surfaceRaised, t)!,
        ok: Color.lerp(palette.ok, other.palette.ok, t)!,
        warn: Color.lerp(palette.warn, other.palette.warn, t)!,
        error: Color.lerp(palette.error, other.palette.error, t)!,
        idle: Color.lerp(palette.idle, other.palette.idle, t)!,
        accent: Color.lerp(palette.accent, other.palette.accent, t)!,
        textPrimary:
            Color.lerp(palette.textPrimary, other.palette.textPrimary, t)!,
        textSecondary:
            Color.lerp(palette.textSecondary, other.palette.textSecondary, t)!,
        onAccent: Color.lerp(palette.onAccent, other.palette.onAccent, t)!,
        hairline: Color.lerp(palette.hairline, other.palette.hairline, t)!,
      ),
    );
  }
}

/// The active palette for [context]. Throws if a caller sits above [MaterialApp]
/// — better than silently returning a default and hiding the wiring bug.
IdentPalette identColors(BuildContext context) =>
    Theme.of(context).extension<IdentPaletteExt>()!.palette;

ThemeData buildIdentTheme({Brightness brightness = Brightness.dark}) {
  final palette = brightness == Brightness.dark ? _darkPalette : _lightPalette;
  final scheme = brightness == Brightness.dark
      ? ColorScheme.dark(
          primary: palette.accent,
          secondary: palette.ok,
          surface: palette.surface,
          error: palette.error,
          onPrimary: palette.onAccent,
          onSurface: palette.textPrimary,
          onError: const Color(0xFF2A0A08),
        )
      : ColorScheme.light(
          primary: palette.accent,
          secondary: palette.ok,
          surface: palette.surface,
          error: palette.error,
          onPrimary: palette.onAccent,
          onSurface: palette.textPrimary,
          onError: const Color(0xFFFFF3F2),
        );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.shell,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.shell,
      foregroundColor: palette.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.hairline),
      ),
    ),
    dividerColor: palette.hairline,
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: palette.textPrimary),
      bodySmall: TextStyle(color: palette.textSecondary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
    extensions: [IdentPaletteExt(palette)],
  );
}
