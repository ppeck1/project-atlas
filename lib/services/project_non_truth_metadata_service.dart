import 'dart:convert';

import '../db/app_db.dart';
import 'project_capsule_truth_service.dart';

const projectNonTruthMetadataFieldKeys = <String>{'lessonsLearned'};

/// Writes project metadata that is deliberately outside the accepted-truth
/// revision ledger. Keeping this boundary narrow prevents callers from
/// mutating accepted truth without producing a verified revision.
class ProjectNonTruthMetadataService {
  final AppDb db;

  const ProjectNonTruthMetadataService(this.db);

  Future<bool> updatePatch({
    required String projectId,
    required Map<String, Object?> fields,
    String actorLabel = 'Operator',
    bool recordProjectMetadataAudit = false,
  }) {
    return db.transaction(() async {
      final unsupportedFields =
          fields.keys
              .where((key) => !projectNonTruthMetadataFieldKeys.contains(key))
              .toList()
            ..sort();
      if (unsupportedFields.isNotEmpty) {
        throw ProjectCapsuleTruthValidationException([
          'Non-truth project metadata does not support: '
              '${unsupportedFields.join(', ')}.',
        ]);
      }
      final before = await db.getProjectFull(projectId);
      if (before == null) throw StateError('Project not found: $projectId');
      final normalized = <String, Object?>{
        for (final entry in fields.entries)
          entry.key: _cleanNonTruthValue(entry.value),
      };
      await db.updateProjectMeta(projectId, normalized);
      final after = await db.getProjectFull(projectId);
      if (after == null) {
        throw StateError('Project disappeared during update: $projectId');
      }
      final changes = <String, Object?>{};
      final beforeJson = before.toJson();
      final afterJson = after.toJson();
      for (final key in normalized.keys) {
        if (beforeJson[key] == afterJson[key]) continue;
        changes[key] = {'from': beforeJson[key], 'to': afterJson[key]};
      }
      if (recordProjectMetadataAudit && changes.isNotEmpty) {
        await db.logEvent(
          area: 'projects',
          action: 'project_non_truth_metadata_updated',
          entityType: 'project',
          entityId: projectId,
          inputJson: jsonEncode({'requestedFields': normalized.keys.toList()}),
          outputJson: jsonEncode({
            'agent': actorLabel,
            'changedFieldCount': changes.length,
            'changedFields': changes,
          }),
        );
      }
      return changes.isNotEmpty;
    });
  }
}

String? _cleanNonTruthValue(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
