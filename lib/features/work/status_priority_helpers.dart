import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

class StatusOption {
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  const StatusOption(this.value, this.label, this.icon, this.color);
}

const statusOptions = [
  StatusOption('inbox', 'Inbox', Icons.inbox_outlined, Colors.grey),
  StatusOption('next', 'Next', Icons.arrow_forward_outlined, Colors.blue),
  StatusOption('doing', 'Doing', Icons.play_circle_outline, Colors.amber),
  StatusOption('waiting', 'Waiting', Icons.hourglass_empty, Colors.purple),
  StatusOption('done', 'Done', Icons.check_circle_outline, Colors.green),
  StatusOption('archived', 'Archived', Icons.archive_outlined, Colors.blueGrey),
];

StatusOption statusFor(String value) {
  return statusOptions.firstWhere(
    (s) => s.value == value,
    orElse: () => statusOptions[1],
  );
}

Widget statusChip(String status) {
  final s = statusFor(status);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: s.color.withAlpha(30),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: s.color.withAlpha(80)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(s.icon, size: 11, color: s.color),
        const SizedBox(width: 3),
        Text(
          s.label,
          style: TextStyle(
            fontSize: 10,
            color: s.color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Priority
// ---------------------------------------------------------------------------

class PriorityOption {
  final String value;
  final String label;
  final Color color;
  const PriorityOption(this.value, this.label, this.color);
}

const priorityOptions = [
  PriorityOption('low', 'Low', Colors.blueGrey),
  PriorityOption('normal', 'Normal', Colors.white54),
  PriorityOption('high', 'High', Colors.orange),
  PriorityOption('urgent', 'Urgent', Colors.red),
];

PriorityOption priorityFor(String value) {
  return priorityOptions.firstWhere(
    (p) => p.value == value,
    orElse: () => priorityOptions[1],
  );
}

Widget priorityDot(String priority) {
  final p = priorityFor(priority);
  if (p.value == 'normal' || p.value == 'low') return const SizedBox.shrink();
  return Container(
    width: 8,
    height: 8,
    margin: const EdgeInsets.only(right: 4),
    decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
  );
}

String normalizeStatusValue(String? value, {String fallback = 'next'}) {
  final raw = (value ?? '').trim().toLowerCase();
  final normalized = switch (raw) {
    'todo' || 'to_do' || 'open' => 'next',
    'in_progress' || 'in progress' => 'doing',
    'blocked' => 'waiting',
    'complete' || 'completed' => 'done',
    _ => raw,
  };
  return statusOptions.any((s) => s.value == normalized)
      ? normalized
      : fallback;
}

String? normalizedStatusOrNull(String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return null;
  final normalized = normalizeStatusValue(raw);
  return statusOptions.any((s) => s.value == normalized) ? normalized : null;
}

String normalizePriorityValue(String? value, {String fallback = 'normal'}) {
  final raw = (value ?? '').trim().toLowerCase();
  final normalized = switch (raw) {
    'medium' || 'med' || 'default' => 'normal',
    'critical' || 'blocker' => 'urgent',
    _ => raw,
  };
  return priorityOptions.any((p) => p.value == normalized)
      ? normalized
      : fallback;
}

String? normalizedPriorityOrNull(String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return null;
  final normalized = normalizePriorityValue(raw);
  return priorityOptions.any((p) => p.value == normalized) ? normalized : null;
}

List<DropdownMenuItem<String>> uniqueStringDropdownItems(
  Iterable<String> values, {
  String Function(String value)? labelFor,
}) {
  final seen = <String>{};
  final items = <DropdownMenuItem<String>>[];
  for (final value in values) {
    if (!seen.add(value)) continue;
    items.add(
      DropdownMenuItem<String>(
        value: value,
        child: Text(labelFor?.call(value) ?? value),
      ),
    );
  }
  return items;
}
