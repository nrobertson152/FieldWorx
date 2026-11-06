// SPDX-License-Identifier: GPL-3.0-or-later
// Themes: the family's colour tokens (OpenSchematix's gui/theme.py, as OpenMeridian and RevisionWorx use them), so
// FieldWorx looks like the desktop programs theme for theme. Widgets take colours from FxColors only.

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class FxTokens {
  const FxTokens(this.label, this.dark, this.t);
  final String label;
  final bool dark;
  final Map<String, int> t;
  Color c(String name) => Color(t[name]!);
}

const Map<String, FxTokens> fxThemes = {
  'modern_light': FxTokens('Modern Light', false, {
    'bg': 0xFFF3F4F6, 'surface': 0xFFFFFFFF, 'surface2': 0xFFF7F8FA, 'border': 0xFFDCDFE4, 'border_strong': 0xFFC3C8CF, //
    'text': 0xFF1B1F24, 'muted': 0xFF626B75, 'faint': 0xFF8A929B, 'accent': 0xFF2563EB, 'accent_text': 0xFFFFFFFF,
    'accent_soft': 0xFFE0EAFF, 'hover': 0xFFECEEF1, 'pressed': 0xFFDFE3E8, 'input': 0xFFFFFFFF,
    'select_bg': 0xFFDBE6FF, 'select_fg': 0xFF10244D, 'danger': 0xFFD9364F, 'warning': 0xFFC27803,
    'success': 0xFF1F8A46, 'info': 0xFF2563EB, 'focus': 0xFF2563EB,
  }),
  'modern_dark': FxTokens('Modern Dark', true, {
    'bg': 0xFF16181C, 'surface': 0xFF1E2126, 'surface2': 0xFF23272D, 'border': 0xFF2E333A, 'border_strong': 0xFF3B4149, //
    'text': 0xFFE6E8EB, 'muted': 0xFF9AA3AD, 'faint': 0xFF6C757F, 'accent': 0xFF4C8DFF, 'accent_text': 0xFFFFFFFF,
    'accent_soft': 0xFF1F3355, 'hover': 0xFF2A2F36, 'pressed': 0xFF343A42, 'input': 0xFF14161A,
    'select_bg': 0xFF24406E, 'select_fg': 0xFFFFFFFF, 'danger': 0xFFFF6B81, 'warning': 0xFFF5B649,
    'success': 0xFF51CF66, 'info': 0xFF74A7FF, 'focus': 0xFF4C8DFF,
  }),
  'graphite': FxTokens('Graphite', true, {
    'bg': 0xFF2B2D30, 'surface': 0xFF323538, 'surface2': 0xFF383B3F, 'border': 0xFF45494E, 'border_strong': 0xFF55595F, //
    'text': 0xFFE3E3E3, 'muted': 0xFFA7ABB0, 'faint': 0xFF7D8186, 'accent': 0xFFE8A33D, 'accent_text': 0xFF1C1C1C,
    'accent_soft': 0xFF4A3F2C, 'hover': 0xFF3D4044, 'pressed': 0xFF474A4F, 'input': 0xFF26282B,
    'select_bg': 0xFF5A4A2E, 'select_fg': 0xFFFFFFFF, 'danger': 0xFFFF7B72, 'warning': 0xFFE8A33D,
    'success': 0xFF7EE787, 'info': 0xFF79C0FF, 'focus': 0xFFE8A33D,
  }),
  'neutral_gray': FxTokens('Neutral Gray', false, {
    'bg': 0xFFD9DBDE, 'surface': 0xFFE8E9EB, 'surface2': 0xFFE1E3E5, 'border': 0xFFC2C5CA, 'border_strong': 0xFFA9ADB3, //
    'text': 0xFF1D2023, 'muted': 0xFF555B62, 'faint': 0xFF7B8188, 'accent': 0xFF3B6EA8, 'accent_text': 0xFFFFFFFF,
    'accent_soft': 0xFFCFDCEC, 'hover': 0xFFD4D7DA, 'pressed': 0xFFC9CCD0, 'input': 0xFFF4F5F6,
    'select_bg': 0xFFC3D5EA, 'select_fg': 0xFF10233A, 'danger': 0xFFC0392B, 'warning': 0xFFA46A00,
    'success': 0xFF25803D, 'info': 0xFF3B6EA8, 'focus': 0xFF3B6EA8,
  }),
  'blueprint': FxTokens('Blueprint', true, {
    'bg': 0xFF0B2140, 'surface': 0xFF0F2A52, 'surface2': 0xFF13325F, 'border': 0xFF1F4478, 'border_strong': 0xFF2A5591, //
    'text': 0xFFE6F0FF, 'muted': 0xFF9FB9DC, 'faint': 0xFF6F8FBB, 'accent': 0xFF5AB0FF, 'accent_text': 0xFF06203F,
    'accent_soft': 0xFF173F72, 'hover': 0xFF16386A, 'pressed': 0xFF1D4580, 'input': 0xFF0A1D38,
    'select_bg': 0xFF1F4E8F, 'select_fg': 0xFFFFFFFF, 'danger': 0xFFFF8A8A, 'warning': 0xFFFFD166,
    'success': 0xFF7EE2A8, 'info': 0xFF5AB0FF, 'focus': 0xFF5AB0FF,
  }),
  'high_contrast': FxTokens('High Contrast', true, {
    'bg': 0xFF000000, 'surface': 0xFF000000, 'surface2': 0xFF0D0D0D, 'border': 0xFFFFFFFF, 'border_strong': 0xFFFFFFFF, //
    'text': 0xFFFFFFFF, 'muted': 0xFFFFFFFF, 'faint': 0xFFD0D0D0, 'accent': 0xFFFFFF00, 'accent_text': 0xFF000000,
    'accent_soft': 0xFF333300, 'hover': 0xFF1F1F1F, 'pressed': 0xFF333333, 'input': 0xFF000000,
    'select_bg': 0xFFFFFF00, 'select_fg': 0xFF000000, 'danger': 0xFFFF4040, 'warning': 0xFFFFFF00,
    'success': 0xFF00FF00, 'info': 0xFF00FFFF, 'focus': 0xFFFFFF00,
  }),
};
const String defaultTheme = 'modern_light';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Color mix(Color a, Color b, double t) => Color.from(
      alpha: 1,
      red: a.r + (b.r - a.r) * t,
      green: a.g + (b.g - a.g) * t,
      blue: a.b + (b.b - a.b) * t,
    );

/// [fg] moved towards black or white only as far as needed to read at 4.5:1 on [bg] (OpenMeridian's rule).
Color readable(Color fg, Color bg) {
  final towards = _lum(bg) > 0.4 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  for (var step = 0; step <= 20; step++) {
    final c = mix(fg, towards, step / 20);
    if (contrast(c, bg) >= 4.5) return c;
  }
  return towards;
}

/// [bg] moved towards black or white just enough for [fg] on it to reach 4.5:1 (unchanged if it already does).
Color fillFor(Color bg, Color fg) {
  final towards = _lum(fg) > 0.4 ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  for (var step = 0; step <= 20; step++) {
    final c = mix(bg, towards, step / 20);
    if (contrast(fg, c) >= 4.5) return c;
  }
  return towards;
}

enum Tone { ok, warn, danger, info, neutral, accent }

/// Every colour FieldWorx draws with.
@immutable
class FxColors extends ThemeExtension<FxColors> {
  const FxColors(this.name, this.tokens);
  final String name;
  final FxTokens tokens;

  Color get bg => tokens.c('bg');
  Color get surface => tokens.c('surface');
  Color get surface2 => tokens.c('surface2');
  Color get border => tokens.c('border');
  Color get borderStrong => tokens.c('border_strong');
  Color get text => tokens.c('text');
  Color get muted => readable(tokens.c('muted'), surface);
  Color get faint => tokens.c('faint');
  Color get accent => tokens.c('accent');
  Color get accentText => tokens.c('accent_text');

  /// The accent behind [accentText] (filled buttons): the family accent, darkened just enough where the palette's
  /// own pair falls short of 4.5:1 (Modern Dark's blue under white text).
  Color get accentFill => fillFor(accent, accentText);
  Color get accentSoft => tokens.c('accent_soft');
  Color get selectBg => tokens.c('select_bg');
  Color get selectFg => tokens.c('select_fg');
  Color get focus => tokens.c('focus');
  bool get dark => tokens.dark;

  Color _toneBase(Tone t) => switch (t) {
        Tone.ok => tokens.c('success'),
        Tone.warn => tokens.c('warning'),
        Tone.danger => tokens.c('danger'),
        Tone.info => tokens.c('info'),
        Tone.neutral => tokens.c('muted'),
        Tone.accent => tokens.c('accent'),
      };

  /// Background of a chip or banner in tone [t].
  Color toneBg(Tone t) => name == 'high_contrast' ? surface : mix(surface, _toneBase(t), dark ? 0.22 : 0.13);

  /// Text on [toneBg], at least 4.5:1.
  Color toneFg(Tone t) => readable(_toneBase(t), toneBg(t));

  /// The tone itself, for icons and borders on the plain surface.
  Color tone(Tone t) => readable(_toneBase(t), surface);

  @override
  FxColors copyWith({String? name}) => name == null ? this : FxColors(name, fxThemes[name] ?? tokens);

  @override
  FxColors lerp(ThemeExtension<FxColors>? other, double t) => t < 0.5 || other is! FxColors ? this : other;
}

extension FxContext on BuildContext {
  FxColors get fx => Theme.of(this).extension<FxColors>()!;
}

ThemeData buildTheme(String name) {
  final tk = fxThemes[name] ?? fxThemes[defaultTheme]!;
  final fx = FxColors(fxThemes.containsKey(name) ? name : defaultTheme, tk);
  final scheme = ColorScheme(
    brightness: tk.dark ? Brightness.dark : Brightness.light,
    primary: fx.accentFill,
    onPrimary: fx.accentText,
    primaryContainer: fx.accentSoft,
    onPrimaryContainer: readable(fx.accent, fx.accentSoft),
    secondary: fx.accentFill,
    onSecondary: fx.accentText,
    error: fx.tone(Tone.danger),
    onError: tk.dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
    surface: fx.surface,
    onSurface: fx.text,
    onSurfaceVariant: fx.muted,
    surfaceContainerLowest: fx.surface,
    surfaceContainerLow: fx.surface,
    surfaceContainer: fx.surface2,
    surfaceContainerHigh: fx.surface2,
    surfaceContainerHighest: fx.bg,
    outline: fx.borderStrong,
    outlineVariant: fx.border,
  );
  const radius = BorderRadius.all(Radius.circular(10));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: fx.bg,
    canvasColor: fx.surface,
    dividerColor: fx.border,
    extensions: [fx],
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: AppBarTheme(
      backgroundColor: fx.surface,
      foregroundColor: fx.text,
      surfaceTintColor: const Color(0x00000000),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: fx.text, fontSize: 19, fontWeight: FontWeight.w600),
      shape: Border(bottom: BorderSide(color: fx.border)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: fx.surface,
      indicatorColor: fx.accentSoft,
      surfaceTintColor: const Color(0x00000000),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? fx.text : fx.muted)),
    ),
    cardTheme: CardThemeData(
      color: fx.surface,
      surfaceTintColor: const Color(0x00000000),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: fx.border)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: fx.muted,
      textColor: fx.text,
      subtitleTextStyle: TextStyle(color: fx.muted, fontSize: 13),
      minVerticalPadding: 10,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fx.tokens.c('input'),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: fx.borderStrong)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: fx.borderStrong)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: fx.focus, width: 2)),
      labelStyle: TextStyle(color: fx.muted),
      hintStyle: TextStyle(color: fx.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: fx.accentFill,
        foregroundColor: fx.accentText,
        minimumSize: const Size(64, 52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: fx.text,
        minimumSize: const Size(64, 48),
        side: BorderSide(color: fx.borderStrong),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: fx.accentFill,
      foregroundColor: fx.accentText,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: readable(fx.accent, fx.surface))),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tk.dark ? fx.surface2 : const Color(0xFF1F2329),
      contentTextStyle: TextStyle(color: tk.dark ? fx.text : const Color(0xFFF5F6F8)),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: DividerThemeData(color: fx.border, space: 1, thickness: 1),
  );
}
