import 'package:flutter/material.dart';

import '../../../shared/theme/atlas_colors.dart';

// Small shared building blocks for the project detail screen and its
// extracted section widgets. Moved out of project_detail_screen.dart
// (C3 tranche 1); names dropped their leading underscore so both the
// origin file and the extracted sections can import them.

String compactDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
String compactDateTime(DateTime? value) {
  if (value == null) return 'n/a';
  return '${compactDate(value)} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

String libraryRouteForProject(
  String projectId, {
  String? entryType,
  String? entryId,
}) {
  final queryParameters = <String, String>{'projectId': projectId};
  if (entryType != null) queryParameters['entryType'] = entryType;
  if (entryId != null) queryParameters['entryId'] = entryId;
  return Uri(path: '/library', queryParameters: queryParameters).toString();
}

class Pill extends StatelessWidget {
  final String label;
  final Color color;
  final String? tooltip;
  const Pill({
    super.key,
    required this.label,
    required this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(34),
        border: Border.all(color: color.withAlpha(68)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

class MiniPill extends StatelessWidget {
  final String label;
  final String value;
  const MiniPill(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 11, color: Colors.white70),
      ),
    );
  }
}

class FieldRow extends StatelessWidget {
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback? onEdit;

  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value?.trim().isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onEdit,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      hasValue ? value! : placeholder,
                      style: TextStyle(
                        fontSize: 13,
                        color: hasValue
                            ? const Color(0xDEFFFFFF)
                            : Colors.white24,
                        height: 1.5,
                      ),
                    ),
                  ),
                  if (onEdit != null) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.edit_outlined,
                      size: 13,
                      color: Colors.white24,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
