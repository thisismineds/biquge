import 'package:flutter/material.dart';

abstract final class ReaderTheme {
  static const ink = Color(0xFF254F43);
  static const paper = Color(0xFFF7F5EF);
  static const readingBackgrounds = [
    Color(0xFFF6F2EA),
    Color(0xFFF2E9D1),
    Color(0xFFE7F1E7),
    Color(0xFFE4EFF2),
    Color(0xFFF2E4E4),
  ];
  static ThemeData theme(bool dark) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: ink,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          surface: dark ? const Color(0xFF191D19) : paper,
          primary: dark ? const Color(0xFFA7CDB5) : ink,
          primaryContainer: dark
              ? const Color(0xFF354B3E)
              : const Color(0xFFE5EAE0),
          secondaryContainer: dark
              ? const Color(0xFF354B3E)
              : const Color(0xFFDCE5D9),
          onPrimaryContainer: dark ? const Color(0xFFCDE0CA) : ink,
          onSecondaryContainer: dark ? const Color(0xFFCDE0CA) : ink,
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
        headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16, height: 1.6),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .65),
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        showDragHandle: true,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
