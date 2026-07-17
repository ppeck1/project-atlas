import 'package:flutter/material.dart';

import '../shared/theme/atlas_colors.dart';

ThemeData buildAtlasTheme() {
  const colors = AtlasColors.defaults;

  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: colors.bg,
    colorScheme: base.colorScheme.copyWith(
      surface: colors.panel,
      outline: colors.line,
      primary: colors.primary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.line),
      ),
    ),
    extensions: const <ThemeExtension<dynamic>>[
      AtlasColors.defaults,
    ],
  );
}
