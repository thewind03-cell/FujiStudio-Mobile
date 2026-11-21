import 'package:material_ui/material_ui.dart';

/// Darkroom Neutral palette & mechanical Fujifilm design tokens.
abstract final class FujiColors {
  static const Color canvas = Color(0xFF0E0F11);
  static const Color surface = Color(0xFF17191D);
  static const Color surfaceElevated = Color(0xFF1E2127);
  static const Color border = Color(0xFF2A2D34);
  static const Color textPrimary = Color(0xFFF2F2F0);
  static const Color textSecondary = Color(0xFF8C919C);
  static const Color keep = Color(0xFF2FB36D);
  static const Color reject = Color(0xFFD94A4A);
  static const Color accent = Color(0xFFE5A93C);
}

abstract final class FujiTheme {
  static const List<FontFeature> tabularFeatures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      surface: FujiColors.surface,
      primary: FujiColors.accent,
      onPrimary: FujiColors.canvas,
      secondary: FujiColors.keep,
      onSecondary: FujiColors.canvas,
      error: FujiColors.reject,
      onError: FujiColors.textPrimary,
      onSurface: FujiColors.textPrimary,
      outline: FujiColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: FujiColors.canvas,
      canvasColor: FujiColors.canvas,
      dividerColor: FujiColors.border,
      appBarTheme: const AppBarTheme(
        backgroundColor: FujiColors.canvas,
        foregroundColor: FujiColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: FujiColors.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
      cardTheme: CardThemeData(
        color: FujiColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: FujiColors.border, width: 1),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: FujiColors.surfaceElevated,
        contentTextStyle: TextStyle(color: FujiColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
