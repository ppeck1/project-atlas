import 'package:flutter/material.dart';

ThemeData buildAtlasTheme() {
  const bg = Color(0xFF0F1115);
  const panel = Color(0xFF151A22);
  const line = Color(0xFF273044);

  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: base.colorScheme.copyWith(
      surface: panel,
      outline: line,
      primary: const Color(0xFF79A7FF),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: panel,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: line),
      ),
    ),
  );
}
