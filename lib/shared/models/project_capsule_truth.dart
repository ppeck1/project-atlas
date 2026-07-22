import 'dart:convert';

import 'package:crypto/crypto.dart';

const projectCapsuleTruthFieldKeys = <String>[
  'title',
  'owner',
  'status',
  'category',
  'phase',
  'priority',
  'description',
  'desiredOutcome',
  'successCriteria',
  'scopeIncluded',
  'scopeExcluded',
  'outcomeSummary',
];

const projectCapsuleTruthFieldLabels = <String, String>{
  'title': 'Project title',
  'owner': 'Owner',
  'status': 'Status',
  'category': 'Category',
  'phase': 'Phase',
  'priority': 'Priority',
  'description': 'Description',
  'desiredOutcome': 'Desired outcome',
  'successCriteria': 'Success criteria',
  'scopeIncluded': 'Scope included',
  'scopeExcluded': 'Scope excluded',
  'outcomeSummary': 'Outcome summary',
};

const projectCapsuleLedgerSeed = 'atlas.project_capsule_ledger.v1';

String projectCapsuleLedgerDigest({
  required String previousDigest,
  required String revisionId,
  required String projectId,
  required int revisionNumber,
  required String? parentRevisionId,
  required String contentHash,
  required String changedFieldsJson,
  required String actorType,
  required String actorLabel,
  required String sourceKind,
  required String? sourceId,
  required String? reason,
  required DateTime acceptedAt,
}) {
  final envelope = <String, Object?>{
    'previousDigest': previousDigest,
    'revisionId': revisionId,
    'projectId': projectId,
    'revisionNumber': revisionNumber,
    'parentRevisionId': parentRevisionId,
    'contentHash': contentHash,
    'changedFields': jsonDecode(changedFieldsJson),
    'actorType': actorType,
    'actorLabel': actorLabel,
    'sourceKind': sourceKind,
    'sourceId': sourceId,
    'reason': reason,
    'acceptedAtEpochSeconds': acceptedAt.millisecondsSinceEpoch ~/ 1000,
  };
  return sha256
      .convert(utf8.encode(jsonEncode(_canonicalJsonValue(envelope))))
      .toString();
}

class ProjectCapsuleTruthChange {
  final Object? before;
  final Object? after;

  const ProjectCapsuleTruthChange({required this.before, required this.after});

  Map<String, Object?> toJson() => {'before': before, 'after': after};

  factory ProjectCapsuleTruthChange.fromJson(Map<String, Object?> json) =>
      ProjectCapsuleTruthChange(before: json['before'], after: json['after']);
}

class ProjectCapsuleTruthLedgerException extends FormatException {
  ProjectCapsuleTruthLedgerException(String message) : super(message);
}

class ProjectCapsuleTruth {
  static const schemaName = 'atlas.project_capsule_truth.v1';
  static const maxFieldLength = 20000;
  static const maxTotalLength = 64000;

  final String title;
  final String? owner;
  final String status;
  final String? category;
  final String? phase;
  final String? priority;
  final String? description;
  final String? desiredOutcome;
  final String? successCriteria;
  final String? scopeIncluded;
  final String? scopeExcluded;
  final String? outcomeSummary;

  const ProjectCapsuleTruth({
    required this.title,
    required this.owner,
    required this.status,
    required this.category,
    required this.phase,
    required this.priority,
    required this.description,
    required this.desiredOutcome,
    required this.successCriteria,
    required this.scopeIncluded,
    required this.scopeExcluded,
    required this.outcomeSummary,
  });

  factory ProjectCapsuleTruth.fromProjectMap(Map<String, Object?> values) {
    final sanitized = Map<String, Object?>.from(values);
    final scopeIncluded = _clean(sanitized['scopeIncluded']);
    if (scopeIncluded != null &&
        scopeIncluded.startsWith('Local project root:')) {
      sanitized['scopeIncluded'] = null;
    }
    final description = _clean(sanitized['description']);
    if (description != null) {
      final lines = description
          .split('\n')
          .where(
            (line) =>
                !line.trimLeft().startsWith('Local path:') &&
                !line.trimLeft().startsWith('Git root:'),
          )
          .join('\n')
          .trim();
      sanitized['description'] = lines.isEmpty ? null : lines;
    }
    return ProjectCapsuleTruth.fromJson(sanitized);
  }

  factory ProjectCapsuleTruth.fromJson(Map<String, Object?> values) {
    return ProjectCapsuleTruth(
      title: _clean(values['title']) ?? 'Untitled project',
      owner: _clean(values['owner']),
      status: _clean(values['status']) ?? 'active',
      category: _clean(values['category']),
      phase: _clean(values['phase']),
      priority: _clean(values['priority']),
      description: _clean(values['description']),
      desiredOutcome: _clean(values['desiredOutcome']),
      successCriteria: _clean(values['successCriteria']),
      scopeIncluded: _clean(values['scopeIncluded']),
      scopeExcluded: _clean(values['scopeExcluded']),
      outcomeSummary: _clean(values['outcomeSummary']),
    );
  }

  Map<String, Object?> toJson() => {
    'schema': schemaName,
    'title': title,
    'owner': owner,
    'status': status,
    'category': category,
    'phase': phase,
    'priority': priority,
    'description': description,
    'desiredOutcome': desiredOutcome,
    'successCriteria': successCriteria,
    'scopeIncluded': scopeIncluded,
    'scopeExcluded': scopeExcluded,
    'outcomeSummary': outcomeSummary,
  };

  Map<String, Object?> toProjectFields() => {
    for (final key in projectCapsuleTruthFieldKeys) key: toJson()[key],
  };

  String get contentHash => sha256
      .convert(utf8.encode(jsonEncode(_canonicalJsonValue(toJson()))))
      .toString();

  ProjectCapsuleTruth applyPatch(Map<String, Object?> patch) {
    final values = toProjectFields();
    for (final key in projectCapsuleTruthFieldKeys) {
      if (patch.containsKey(key)) values[key] = patch[key];
    }
    return ProjectCapsuleTruth.fromJson(values);
  }

  Map<String, ProjectCapsuleTruthChange> diff(ProjectCapsuleTruth proposed) {
    final before = toProjectFields();
    final after = proposed.toProjectFields();
    return {
      for (final key in projectCapsuleTruthFieldKeys)
        if (before[key] != after[key])
          key: ProjectCapsuleTruthChange(
            before: before[key],
            after: after[key],
          ),
    };
  }

  List<String> validate() {
    final errors = <String>[];
    if (title.trim().isEmpty) errors.add('Project title is required.');
    var totalLength = 0;
    for (final entry in toProjectFields().entries) {
      final value = entry.value;
      if (value is! String) continue;
      totalLength += value.length;
      if (value.length > maxFieldLength) {
        errors.add(
          '${projectCapsuleTruthFieldLabels[entry.key] ?? entry.key} exceeds '
          '$maxFieldLength characters.',
        );
      }
    }
    if (totalLength > maxTotalLength) {
      errors.add('Project truth exceeds $maxTotalLength total characters.');
    }
    return List.unmodifiable(errors);
  }
}

Map<String, ProjectCapsuleTruthChange> decodeProjectCapsuleTruthChanges(
  String rawJson,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException catch (error) {
    throw ProjectCapsuleTruthLedgerException(
      'Capsule revision changed-fields JSON is malformed: ${error.message}',
    );
  }
  if (decoded is! Map) {
    throw ProjectCapsuleTruthLedgerException(
      'Capsule revision changed-fields JSON must be an object.',
    );
  }
  final changes = <String, ProjectCapsuleTruthChange>{};
  for (final entry in decoded.entries) {
    final key = '${entry.key}';
    if (!projectCapsuleTruthFieldKeys.contains(key)) {
      throw ProjectCapsuleTruthLedgerException(
        'Capsule revision changed-fields JSON has an unknown field: $key.',
      );
    }
    if (entry.value is! Map) {
      throw ProjectCapsuleTruthLedgerException(
        'Capsule revision changed-fields entry for $key must be an object.',
      );
    }
    final value = (entry.value as Map).map(
      (field, fieldValue) => MapEntry('$field', fieldValue),
    );
    if (!value.containsKey('before') || !value.containsKey('after')) {
      throw ProjectCapsuleTruthLedgerException(
        'Capsule revision changed-fields entry for $key must contain before and after.',
      );
    }
    changes[key] = ProjectCapsuleTruthChange.fromJson(value);
  }
  return Map<String, ProjectCapsuleTruthChange>.unmodifiable(changes);
}

String encodeProjectCapsuleTruthChanges(
  Map<String, ProjectCapsuleTruthChange> changes,
) => jsonEncode({
  for (final entry in changes.entries) entry.key: entry.value.toJson(),
});

String? _clean(Object? value) {
  if (value == null) return null;
  final normalized = '$value'.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final trimmed = normalized.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Object? _canonicalJsonValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map(
              (entry) =>
                  MapEntry('${entry.key}', _canonicalJsonValue(entry.value)),
            )
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: entry.value,
    };
  }
  if (value is Iterable) return value.map(_canonicalJsonValue).toList();
  return value;
}
