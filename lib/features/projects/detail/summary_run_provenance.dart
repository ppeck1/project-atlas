import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

Map<String, Object?> _tryParseJsonObject(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
  } catch (e) {
    debugPrint('[Atlas] _tryParseJsonObject (summary_run_provenance): JSON decode failed: $e');
  }
  return const <String, Object?>{};
}

class SummaryRunProvenance extends StatefulWidget {
  final String projectId;

  const SummaryRunProvenance({super.key, required this.projectId});

  @override
  State<SummaryRunProvenance> createState() => _SummaryRunProvenanceState();
}

class _SummaryRunProvenanceState extends State<SummaryRunProvenance> {
  Stream<List<EventLogData>>? _watchRecentEvents;

  Object? _field(Map<String, Object?> map, String key) => map[key];

  Map<String, Object?> _nestedMap(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is Map) return value.map((k, v) => MapEntry('$k', v));
    return const <String, Object?>{};
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchRecentEvents ??= AppStateScope.of(context).watchRecentEvents();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return StreamBuilder<List<EventLogData>>(
      stream: _watchRecentEvents,
      builder: (context, snap) {
        final rows = (snap.data ?? const <EventLogData>[])
            .where(
              (event) =>
                  event.area == 'ai' &&
                  event.entityType == 'project_summary' &&
                  event.entityId == widget.projectId &&
                  const {
                    'project_summary_draft_saved',
                    'project_summary_failed',
                  }.contains(event.action),
            )
            .take(3)
            .toList(growable: false);
        if (rows.isEmpty) return const SizedBox.shrink();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(6),
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.history, size: 15, color: colors.primary),
                  const SizedBox(width: 6),
                  const Text(
                    'Recent summary runs',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...rows.map((event) {
                final data = _tryParseJsonObject(event.outputJson);
                final evidence = _nestedMap(data, 'evidence');
                final success = data['success'] == true;
                final model = (_field(data, 'model') ?? 'model n/a').toString();
                final trigger = (_field(data, 'trigger') ?? 'manual')
                    .toString();
                final docs = (_field(evidence, 'includedDocumentCount') ?? '-')
                    .toString();
                final chars = (_field(evidence, 'totalExcerptChars') ?? '0')
                    .toString();
                final codes = data['validationIssueCodes'];
                final codeText = codes is List && codes.isNotEmpty
                    ? codes.map((code) => '$code').join(', ')
                    : null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        success
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 14,
                        color: success
                            ? const Color(0xFF4CAF50)
                            : const Color(0xFFFF8A80),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${success ? 'Saved' : 'Failed'} - $model - $trigger',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                            ),
                            Text(
                              '${compactDateTime(event.timestamp)} - docs $docs - chars $chars${codeText == null ? '' : ' - $codeText'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}
