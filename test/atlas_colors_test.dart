import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/app/theme.dart';
import 'package:project_atlas/shared/theme/atlas_colors.dart';

void main() {
  group('AtlasColors theme extension', () {
    late ThemeData theme;

    setUp(() {
      theme = buildAtlasTheme();
    });

    test('extension is registered and non-null', () {
      final colors = theme.extension<AtlasColors>();
      expect(colors, isNotNull);
    });

    test('bg == Color(0xFF0F1115)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.bg, const Color(0xFF0F1115));
    });

    test('primary == Color(0xFF79A7FF)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.primary, const Color(0xFF79A7FF));
    });

    test('selectedFill == 15% primary', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.selectedFill, const Color(0x2679A7FF));
    });

    test('panel == Color(0xFF151A22)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.panel, const Color(0xFF151A22));
    });

    test('line == Color(0xFF273044)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.line, const Color(0xFF273044));
    });

    test('inactive == Color(0xFF879AB5)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.inactive, const Color(0xFF879AB5));
    });

    test('surfaceDeep == Color(0xFF10141B)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.surfaceDeep, const Color(0xFF10141B));
    });

    test('warningFill == Color(0x22FF9800)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.warningFill, const Color(0x22FF9800));
    });

    test('warningBorder == Color(0x55FF9800)', () {
      final colors = theme.extension<AtlasColors>()!;
      expect(colors.warningBorder, const Color(0x55FF9800));
    });

    test('copyWith overrides individual fields', () {
      final colors = theme.extension<AtlasColors>()!;
      final modified = colors.copyWith(bg: const Color(0xFF000000));
      expect(modified.bg, const Color(0xFF000000));
      expect(modified.primary, colors.primary);
    });

    test('lerp at t=0 returns original, t=1 returns other', () {
      const a = AtlasColors.defaults;
      const other = AtlasColors(
        bg: Color(0xFF000000),
        panel: Color(0xFF000000),
        line: Color(0xFF000000),
        primary: Color(0xFF000000),
        inactive: Color(0xFF000000),
        selectedFill: Color(0xFF000000),
        surfaceDeep: Color(0xFF000000),
        warningFill: Color(0xFF000000),
        warningBorder: Color(0xFF000000),
      );
      expect(a.lerp(other, 0.0).bg, a.bg);
      expect(a.lerp(other, 1.0).bg, other.bg);
    });
  });
}
