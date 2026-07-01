import 'package:flutter/material.dart';

enum ProjectStatusDisposition { open, attention, inactive, closed }

class ProjectStatusOption {
  final String value;
  final String label;
  final String descriptor;
  final String description;
  final ProjectStatusDisposition disposition;
  final Color color;
  final bool summaryEligible;
  final bool needsAttention;

  const ProjectStatusOption({
    required this.value,
    required this.label,
    required this.descriptor,
    required this.description,
    required this.disposition,
    required this.color,
    this.summaryEligible = false,
    this.needsAttention = false,
  });
}

const projectStatusOptions = <ProjectStatusOption>[
  ProjectStatusOption(
    value: 'active',
    label: 'Active',
    descriptor: 'Open',
    description:
        'Current project or useful reference to keep in active work lists.',
    disposition: ProjectStatusDisposition.open,
    color: Color(0xFF4CAF50),
    summaryEligible: true,
  ),
  ProjectStatusOption(
    value: 'stale',
    label: 'Stale',
    descriptor: 'Review',
    description:
        'Possibly inactive or out of date; keep visible until reviewed.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFFFFB74D),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'needs_update',
    label: 'Needs update',
    descriptor: 'Review',
    description: 'Needs metadata, docs, or local state refreshed.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFFFF9800),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'needs_review',
    label: 'Needs review',
    descriptor: 'Review',
    description: 'Needs human review before the record should be trusted.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFFBA68C8),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'local_only',
    label: 'Local only',
    descriptor: 'Review',
    description:
        'Known locally, but not confirmed in a public or remote source.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFF64B5F6),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'public_mismatch',
    label: 'Public mismatch',
    descriptor: 'Review',
    description:
        'Local and public project evidence disagree and need reconciliation.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFFFF7043),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'paused',
    label: 'Paused',
    descriptor: 'Inactive',
    description: 'Intentionally on hold; not part of active summary refreshes.',
    disposition: ProjectStatusDisposition.inactive,
    color: Color(0xFFFF9800),
  ),
  ProjectStatusOption(
    value: 'blocked',
    label: 'Blocked',
    descriptor: 'Review',
    description: 'Open project with a blocker that needs attention.',
    disposition: ProjectStatusDisposition.attention,
    color: Color(0xFFF44336),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'completed',
    label: 'Completed',
    descriptor: 'Closed',
    description: 'Finished project retained for history and reference.',
    disposition: ProjectStatusDisposition.closed,
    color: Color(0xFF2196F3),
  ),
  ProjectStatusOption(
    value: 'archived',
    label: 'Archived',
    descriptor: 'Closed',
    description: 'Closed or parked record that stays out of active work lists.',
    disposition: ProjectStatusDisposition.closed,
    color: Color(0xFF607D8B),
  ),
];

const uncategorizedProjectCategory = 'Uncategorized';

Set<String> get projectStatusValues =>
    projectStatusOptions.map((option) => option.value).toSet();

Set<String> get summaryEligibleProjectStatuses => projectStatusOptions
    .where((option) => option.summaryEligible)
    .map((option) => option.value)
    .toSet();

Set<String> get attentionProjectStatuses => projectStatusOptions
    .where((option) => option.needsAttention)
    .map((option) => option.value)
    .toSet();

bool isSummaryEligibleProjectStatus(String? value) =>
    projectStatusFor(value).summaryEligible;

bool isAttentionProjectStatus(String? value) =>
    projectStatusFor(value).needsAttention;

ProjectStatusOption projectStatusFor(String? value) {
  final normalized = normalizeProjectStatusValue(value);
  return projectStatusOptions.firstWhere(
    (option) => option.value == normalized,
    orElse: () => projectStatusOptions.first,
  );
}

String normalizeProjectStatusValue(String? value) {
  final raw = (value ?? '').trim().toLowerCase().replaceAll(
    RegExp(r'[\s-]+'),
    '_',
  );
  return projectStatusOptions.any((option) => option.value == raw)
      ? raw
      : 'active';
}

String projectStatusLabel(String? value) => projectStatusFor(value).label;

String projectStatusDescriptor(String? value) =>
    projectStatusFor(value).descriptor;

String projectStatusDescription(String? value) =>
    projectStatusFor(value).description;

Color projectStatusColor(String? value) => projectStatusFor(value).color;

String? normalizeProjectCategory(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String projectCategoryLabel(String? value) =>
    normalizeProjectCategory(value) ?? uncategorizedProjectCategory;
