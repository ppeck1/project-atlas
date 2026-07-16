import 'package:flutter/material.dart';

/// Design-system color tokens for Project Atlas.
///
/// Register via [ThemeData.extensions] in [buildAtlasTheme] and read with:
///   `Theme.of(context).extension<AtlasColors>()!`
@immutable
class AtlasColors extends ThemeExtension<AtlasColors> {
  const AtlasColors({
    required this.bg,
    required this.panel,
    required this.line,
    required this.primary,
    required this.inactive,
    required this.selectedFill,
    required this.surfaceDeep,
  });

  /// App scaffold background. #0F1115
  final Color bg;

  /// Card / panel background. #151A22
  final Color panel;

  /// Border / divider colour. #273044
  final Color line;

  /// Brand accent (nav, icons, chips). #79A7FF
  final Color primary;

  /// Unselected / muted icon colour. #879AB5
  final Color inactive;

  /// Selected-item pill background on the nav rail. 0x26799AFF
  // TODO(paul): the color bits here are 799AFF while [primary] uses 79A7FF
  // (transposed "A7" vs "99"). Decide whether this is an intentional tint or
  // a long-standing typo before collapsing into a derived value.
  final Color selectedFill;

  /// Slightly darker surface used for task tiles and non-general group panels.
  /// #10141B
  final Color surfaceDeep;

  /// Canonical Atlas palette.
  static const AtlasColors defaults = AtlasColors(
    bg: Color(0xFF0F1115),
    panel: Color(0xFF151A22),
    line: Color(0xFF273044),
    primary: Color(0xFF79A7FF),
    inactive: Color(0xFF879AB5),
    selectedFill: Color(0x26799AFF),
    surfaceDeep: Color(0xFF10141B),
  );

  @override
  AtlasColors copyWith({
    Color? bg,
    Color? panel,
    Color? line,
    Color? primary,
    Color? inactive,
    Color? selectedFill,
    Color? surfaceDeep,
  }) {
    return AtlasColors(
      bg: bg ?? this.bg,
      panel: panel ?? this.panel,
      line: line ?? this.line,
      primary: primary ?? this.primary,
      inactive: inactive ?? this.inactive,
      selectedFill: selectedFill ?? this.selectedFill,
      surfaceDeep: surfaceDeep ?? this.surfaceDeep,
    );
  }

  @override
  AtlasColors lerp(AtlasColors? other, double t) {
    if (other == null) return this;
    return AtlasColors(
      bg: Color.lerp(bg, other.bg, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      line: Color.lerp(line, other.line, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      inactive: Color.lerp(inactive, other.inactive, t)!,
      selectedFill: Color.lerp(selectedFill, other.selectedFill, t)!,
      surfaceDeep: Color.lerp(surfaceDeep, other.surfaceDeep, t)!,
    );
  }
}
