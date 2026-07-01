import 'package:flutter/material.dart';

class ProjectStatusOption {
  final String value;
  final String label;
  final Color color;
  final bool summaryEligible;
  final bool needsAttention;

  const ProjectStatusOption({
    required this.value,
    required this.label,
    required this.color,
    this.summaryEligible = false,
    this.needsAttention = false,
  });
}

const projectStatusOptions = <ProjectStatusOption>[
  ProjectStatusOption(
    value: 'active',
    label: 'Active',
    color: Color(0xFF4CAF50),
    summaryEligible: true,
  ),
  ProjectStatusOption(
    value: 'stale',
    label: 'Stale',
    color: Color(0xFFFFB74D),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'needs_update',
    label: 'Needs update',
    color: Color(0xFFFF9800),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'needs_review',
    label: 'Needs review',
    color: Color(0xFFBA68C8),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'local_only',
    label: 'Local only',
    color: Color(0xFF64B5F6),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'public_mismatch',
    label: 'Public mismatch',
    color: Color(0xFFFF7043),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'paused',
    label: 'Paused',
    color: Color(0xFFFF9800),
  ),
  ProjectStatusOption(
    value: 'blocked',
    label: 'Blocked',
    color: Color(0xFFF44336),
    summaryEligible: true,
    needsAttention: true,
  ),
  ProjectStatusOption(
    value: 'completed',
    label: 'Completed',
    color: Color(0xFF2196F3),
  ),
  ProjectStatusOption(
    value: 'archived',
    label: 'Archived',
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

ProjectStatusOption projectStatusFor(String? value) {
  final normalized = normalizeProjectStatusValue(value);
  return projectStatusOptions.firstWhere(
    (option) => option.value == normalized,
    orElse: () => projectStatusOptions.first,
  );
}

String normalizeProjectStatusValue(String? value) {
  final raw = (value ?? '').trim().toLowerCase();
  return projectStatusOptions.any((option) => option.value == raw)
      ? raw
      : 'active';
}

String projectStatusLabel(String? value) => projectStatusFor(value).label;

Color projectStatusColor(String? value) => projectStatusFor(value).color;

String? normalizeProjectCategory(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String projectCategoryLabel(String? value) =>
    normalizeProjectCategory(value) ?? uncategorizedProjectCategory;
