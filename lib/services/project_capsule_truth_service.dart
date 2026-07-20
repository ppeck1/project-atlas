import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';

import '../db/app_db.dart';
import '../shared/models/project_capsule_truth.dart';
import '../shared/models/project_metadata.dart';

const projectCapsulePhaseValues = <String>{
  'idea',
  'design',
  'build',
  'test',
  'ship',
  'stabilize',
};

const projectCapsulePriorityValues = <String>{
  'low',
  'normal',
  'high',
  'urgent',
};

class ProjectCapsuleTruthConflict implements Exception {
  final String expectedRevisionId;
  final String actualRevisionId;

  const ProjectCapsuleTruthConflict({
    required this.expectedRevisionId,
    required this.actualRevisionId,
  });

  @override
  String toString() =>
      'Project truth changed after editing began. Expected '
      '$expectedRevisionId, found $actualRevisionId.';
}

class ProjectCapsuleTruthValidationException implements Exception {
  final List<String> errors;

  const ProjectCapsuleTruthValidationException(this.errors);

  @override
  String toString() => errors.join(' ');
}

class ProjectCapsuleAcceptedRevision {
  final String id;
  final String projectId;
  final int revisionNumber;
  final String? parentRevisionId;
  final String contentHash;
  final ProjectCapsuleTruth truth;
  final Map<String, ProjectCapsuleTruthChange> changedFields;
  final String actorType;
  final String actorLabel;
  final String sourceKind;
  final String? sourceId;
  final String? reason;
  final DateTime acceptedAt;

  const ProjectCapsuleAcceptedRevision({
    required this.id,
    required this.projectId,
    required this.revisionNumber,
    required this.parentRevisionId,
    required this.contentHash,
    required this.truth,
    required this.changedFields,
    required this.actorType,
    required this.actorLabel,
    required this.sourceKind,
    required this.sourceId,
    required this.reason,
    required this.acceptedAt,
  });

  factory ProjectCapsuleAcceptedRevision.fromRow(
    ProjectCapsuleRevisionRow row,
  ) {
    final decoded = jsonDecode(row.truthJson);
    if (decoded is! Map) {
      throw const FormatException('Capsule truth revision is not an object.');
    }
    final truth = ProjectCapsuleTruth.fromJson(
      decoded.map((key, value) => MapEntry('$key', value)),
    );
    if (truth.contentHash != row.contentHash) {
      throw FormatException(
        'Capsule truth revision ${row.id} failed its content hash check.',
      );
    }
    return ProjectCapsuleAcceptedRevision(
      id: row.id,
      projectId: row.projectId,
      revisionNumber: row.revisionNumber,
      parentRevisionId: row.parentRevisionId,
      contentHash: row.contentHash,
      truth: truth,
      changedFields: decodeProjectCapsuleTruthChanges(row.changedFieldsJson),
      actorType: row.actorType,
      actorLabel: row.actorLabel,
      sourceKind: row.sourceKind,
      sourceId: row.sourceId,
      reason: row.reason,
      acceptedAt: row.acceptedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'revisionNumber': revisionNumber,
    'parentRevisionId': parentRevisionId,
    'contentHash': contentHash,
    'changedFields': {
      for (final entry in changedFields.entries)
        entry.key: entry.value.toJson(),
    },
    'actorType': actorType,
    'actorLabel': actorLabel,
    'sourceKind': sourceKind,
    'sourceId': sourceId,
    'reason': reason,
    'acceptedAt': acceptedAt.toIso8601String(),
  };
}

class ProjectCapsuleTruthState {
  final Project project;
  final ProjectCapsuleTruth truth;
  final ProjectCapsuleAcceptedRevision? recordedHead;
  final int revisionCount;

  const ProjectCapsuleTruthState({
    required this.project,
    required this.truth,
    required this.recordedHead,
    required this.revisionCount,
  });

  bool get headMatchesCurrent =>
      recordedHead != null && recordedHead!.contentHash == truth.contentHash;

  String get revisionId => headMatchesCurrent
      ? recordedHead!.id
      : 'derived-${truth.contentHash.substring(0, 12)}';

  int? get revisionNumber =>
      headMatchesCurrent ? recordedHead!.revisionNumber : null;
}

class ProjectCapsuleTruthAcceptance {
  final bool changed;
  final ProjectCapsuleTruthState state;
  final ProjectCapsuleAcceptedRevision? revision;
  final Map<String, ProjectCapsuleTruthChange> changedFields;

  const ProjectCapsuleTruthAcceptance({
    required this.changed,
    required this.state,
    required this.revision,
    required this.changedFields,
  });
}

class ProjectCapsuleTruthService {
  final AppDb db;
  final DateTime Function() _now;

  ProjectCapsuleTruthService(this.db, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  Future<ProjectCapsuleTruthState?> load(String projectId) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) return null;
    final revisions = await _verifiedRevisions(projectId);
    final head = revisions.isEmpty ? null : revisions.first;
    return ProjectCapsuleTruthState(
      project: project,
      truth: ProjectCapsuleTruth.fromProjectMap(project.toJson()),
      recordedHead: head,
      revisionCount: revisions.length,
    );
  }

  Future<List<ProjectCapsuleAcceptedRevision>> listRevisions(
    String projectId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final revisions = await _verifiedRevisions(projectId);
    final start = offset.clamp(0, revisions.length);
    return List.unmodifiable(
      revisions.skip(start).take(limit.clamp(1, 200)),
    );
  }

  Future<ProjectCapsuleAcceptedRevision?> findAcceptedRevisionBySource({
    required String projectId,
    required String sourceKind,
    required String sourceId,
  }) async {
    final row =
        await (db.select(db.projectCapsuleRevisions)
              ..where(
                (table) =>
                    table.projectId.equals(projectId) &
                    table.sourceKind.equals(sourceKind) &
                    table.sourceId.equals(sourceId),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.revisionNumber)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : ProjectCapsuleAcceptedRevision.fromRow(row);
  }

  Future<ProjectCapsuleTruthAcceptance> acceptPatch({
    required String projectId,
    required Map<String, Object?> fields,
    String? expectedRevisionId,
    String actorLabel = 'Operator',
    String? actorType,
    String sourceKind = 'project_detail',
    String? sourceId,
    String? reason,
    bool recordProjectMetadataAudit = false,
    bool recordReconciliation = false,
  }) {
    return db.transaction(() async {
      final beforeState = await load(projectId);
      if (beforeState == null) {
        throw StateError('Project not found: $projectId');
      }
      final normalizedFields = _normalizeMetadataFields(fields);
      if (expectedRevisionId != null &&
          expectedRevisionId != beforeState.revisionId) {
        final acceptedBySource = sourceId == null
            ? null
            : await findAcceptedRevisionBySource(
                projectId: projectId,
                sourceKind: sourceKind,
                sourceId: sourceId,
              );
        if (acceptedBySource != null &&
            _revisionContainsPatch(acceptedBySource, normalizedFields)) {
          return ProjectCapsuleTruthAcceptance(
            changed: false,
            state: beforeState,
            revision: acceptedBySource,
            changedFields: acceptedBySource.changedFields,
          );
        }
        throw ProjectCapsuleTruthConflict(
          expectedRevisionId: expectedRevisionId,
          actualRevisionId: beforeState.revisionId,
        );
      }

      final truthPatch = <String, Object?>{
        for (final key in projectCapsuleTruthFieldKeys)
          if (normalizedFields.containsKey(key)) key: normalizedFields[key],
      };
      if (truthPatch.containsKey('title') &&
          _clean(truthPatch['title']) == null) {
        throw const ProjectCapsuleTruthValidationException([
          'Project title is required.',
        ]);
      }
      final proposedTruth = beforeState.truth.applyPatch(truthPatch);
      final validationErrors = validateProjectCapsuleTruth(proposedTruth);
      if (validationErrors.isNotEmpty) {
        throw ProjectCapsuleTruthValidationException(validationErrors);
      }

      await db.updateProjectMeta(projectId, normalizedFields);
      final project = await db.getProjectFull(projectId);
      if (project == null) {
        throw StateError('Project disappeared during update: $projectId');
      }
      final acceptedTruth = ProjectCapsuleTruth.fromProjectMap(
        project.toJson(),
      );
      final priorAcceptedTruth =
          beforeState.recordedHead?.truth ?? beforeState.truth;
      final changes = priorAcceptedTruth.diff(acceptedTruth);
      final metadataChanges = _projectMetaChanges(
        beforeState.project,
        project,
        normalizedFields.keys,
      );
      if (recordProjectMetadataAudit && metadataChanges.isNotEmpty) {
        final resolvedActorType = actorType ?? _actorType(actorLabel);
        await db.logEvent(
          area: 'projects',
          action: 'project_metadata_updated',
          entityType: 'project',
          entityId: projectId,
          inputJson: jsonEncode({
            'requestedFields': normalizedFields.keys.toList(),
          }),
          outputJson: jsonEncode({
            'agent': actorLabel,
            'actor': {
              'type': resolvedActorType == 'ai_model'
                  ? 'ai'
                  : resolvedActorType,
              'displayName': actorLabel,
            },
            'changedFieldCount': metadataChanges.length,
            'changedFields': metadataChanges,
          }),
        );
      }
      final reconcileUnrecordedTruth =
          recordReconciliation && !beforeState.headMatchesCurrent;
      if (changes.isEmpty && !reconcileUnrecordedTruth) {
        return ProjectCapsuleTruthAcceptance(
          changed: false,
          state: ProjectCapsuleTruthState(
            project: project,
            truth: acceptedTruth,
            recordedHead: beforeState.recordedHead,
            revisionCount: beforeState.revisionCount,
          ),
          revision: null,
          changedFields: const {},
        );
      }

      final revision = await _insertRevision(
        projectId: projectId,
        truth: acceptedTruth,
        parent: beforeState.recordedHead,
        revisionNumber: (beforeState.recordedHead?.revisionNumber ?? 0) + 1,
        changedFields: changes,
        actorType: actorType ?? _actorType(actorLabel),
        actorLabel: actorLabel,
        sourceKind: sourceKind,
        sourceId: sourceId,
        reason: _clean(reason),
      );
      return ProjectCapsuleTruthAcceptance(
        changed: true,
        state: ProjectCapsuleTruthState(
          project: project,
          truth: acceptedTruth,
          recordedHead: revision,
          revisionCount: beforeState.revisionCount + 1,
        ),
        revision: revision,
        changedFields: Map.unmodifiable(changes),
      );
    });
  }

  Future<List<ProjectCapsuleRevisionRow>> _revisionRows(String projectId) {
    return (db.select(db.projectCapsuleRevisions)
          ..where((table) => table.projectId.equals(projectId))
          ..orderBy([(table) => OrderingTerm.desc(table.revisionNumber)]))
        .get();
  }

  Future<List<ProjectCapsuleAcceptedRevision>> _verifiedRevisions(
    String projectId,
  ) async {
    final revisions = List<ProjectCapsuleAcceptedRevision>.unmodifiable(
      (await _revisionRows(
        projectId,
      )).map(ProjectCapsuleAcceptedRevision.fromRow),
    );
    if (revisions.isEmpty) {
      throw ProjectCapsuleTruthLedgerException(
        'Capsule revision ledger for $projectId has no baseline revision.',
      );
    }
    ProjectCapsuleAcceptedRevision? parent;
    var expectedNumber = 1;
    for (final revision in revisions.reversed) {
      if (revision.projectId != projectId) {
        throw ProjectCapsuleTruthLedgerException(
          'Capsule revision ${revision.id} belongs to ${revision.projectId}, '
          'not $projectId.',
        );
      }
      if (revision.revisionNumber != expectedNumber) {
        throw ProjectCapsuleTruthLedgerException(
          'Capsule revisions for $projectId are not contiguous at '
          'revision ${revision.revisionNumber}.',
        );
      }
      if (revision.parentRevisionId != parent?.id) {
        throw ProjectCapsuleTruthLedgerException(
          'Capsule revision ${revision.id} has an invalid parent link.',
        );
      }
      final expectedChanges = parent == null
          ? const <String, ProjectCapsuleTruthChange>{}
          : parent.truth.diff(revision.truth);
      if (!_changesMatch(expectedChanges, revision.changedFields)) {
        throw ProjectCapsuleTruthLedgerException(
          'Capsule revision ${revision.id} has an invalid recorded diff.',
        );
      }
      parent = revision;
      expectedNumber++;
    }
    return revisions;
  }

  Future<ProjectCapsuleAcceptedRevision> _insertRevision({
    required String projectId,
    required ProjectCapsuleTruth truth,
    required ProjectCapsuleAcceptedRevision? parent,
    required int revisionNumber,
    required Map<String, ProjectCapsuleTruthChange> changedFields,
    required String actorType,
    required String actorLabel,
    required String sourceKind,
    required String? sourceId,
    required String? reason,
  }) async {
    final acceptedAt = _now();
    final id = _revisionId(
      projectId: projectId,
      revisionNumber: revisionNumber,
      contentHash: truth.contentHash,
    );
    final row = ProjectCapsuleRevisionRow(
      id: id,
      projectId: projectId,
      revisionNumber: revisionNumber,
      parentRevisionId: parent?.id,
      contentHash: truth.contentHash,
      truthJson: jsonEncode(truth.toJson()),
      changedFieldsJson: encodeProjectCapsuleTruthChanges(changedFields),
      actorType: actorType,
      actorLabel: actorLabel,
      sourceKind: sourceKind,
      sourceId: sourceId,
      reason: reason,
      acceptedAt: acceptedAt,
    );
    await db.into(db.projectCapsuleRevisions).insert(row);
    return ProjectCapsuleAcceptedRevision.fromRow(row);
  }
}

bool _changesMatch(
  Map<String, ProjectCapsuleTruthChange> expected,
  Map<String, ProjectCapsuleTruthChange> actual,
) {
  if (expected.length != actual.length) return false;
  for (final entry in expected.entries) {
    final recorded = actual[entry.key];
    if (recorded == null ||
        recorded.before != entry.value.before ||
        recorded.after != entry.value.after) {
      return false;
    }
  }
  return true;
}

bool _revisionContainsPatch(
  ProjectCapsuleAcceptedRevision revision,
  Map<String, Object?> fields,
) {
  final accepted = revision.truth.toProjectFields();
  for (final key in projectCapsuleTruthFieldKeys) {
    if (!fields.containsKey(key)) continue;
    if (accepted[key] != fields[key]) return false;
  }
  return true;
}

Map<String, Object?> _normalizeMetadataFields(Map<String, Object?> fields) {
  final normalized = Map<String, Object?>.from(fields);
  if (normalized.containsKey('status')) {
    final raw = _clean(normalized['status']);
    final status = raw?.toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    if (status == null ||
        (!projectStatusValues.contains(status) && status != 'deleted')) {
      throw ProjectCapsuleTruthValidationException([
        'Unsupported project status: ${raw ?? 'empty'}.',
      ]);
    }
    normalized['status'] = status;
  }
  for (final key in projectCapsuleTruthFieldKeys) {
    if (!normalized.containsKey(key) || key == 'status') continue;
    normalized[key] = _clean(normalized[key]);
  }
  return normalized;
}

Map<String, Object?> _projectMetaChanges(
  Project before,
  Project after,
  Iterable<String> fieldKeys,
) {
  final beforeJson = before.toJson();
  final afterJson = after.toJson();
  final result = <String, Object?>{};
  for (final key in fieldKeys) {
    final oldValue = beforeJson[key];
    final newValue = afterJson[key];
    if (oldValue == newValue) continue;
    result[key] = {'from': oldValue, 'to': newValue};
  }
  return result;
}

List<String> validateProjectCapsuleTruth(ProjectCapsuleTruth truth) {
  final errors = [...truth.validate()];
  if (!projectStatusValues.contains(truth.status) &&
      truth.status != 'deleted') {
    errors.add('Unsupported project status: ${truth.status}.');
  }
  if (truth.phase != null && !projectCapsulePhaseValues.contains(truth.phase)) {
    errors.add('Unsupported project phase: ${truth.phase}.');
  }
  if (truth.priority != null &&
      !projectCapsulePriorityValues.contains(truth.priority)) {
    errors.add('Unsupported project priority: ${truth.priority}.');
  }
  return List.unmodifiable(errors);
}

String _actorType(String label) {
  final normalized = label.trim().toLowerCase();
  if (normalized == 'atlas agent' ||
      normalized == 'codex' ||
      normalized.startsWith('model:')) {
    return 'ai_model';
  }
  if (normalized == 'atlas' || normalized == 'system') return 'system';
  if (normalized.contains('import')) return 'import';
  return 'operator';
}

String _revisionId({
  required String projectId,
  required int revisionNumber,
  required String contentHash,
}) {
  final projectKey = sha256
      .convert(utf8.encode(projectId))
      .toString()
      .substring(0, 12);
  return 'truth-$projectKey-$revisionNumber-${contentHash.substring(0, 12)}';
}

String? _clean(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
