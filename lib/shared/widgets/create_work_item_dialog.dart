import 'package:flutter/material.dart';
import '../../features/work/status_priority_helpers.dart';
import '../../services/workload_planning_service.dart';
import 'contact_picker.dart';

Future<Map<String, String?>?> showCreateWorkItemDialog(
  BuildContext context,
) async {
  final titleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final ownerCtrl = TextEditingController();
  final blockedCtrl = TextEditingController();
  final nextActionCtrl = TextEditingController();
  final planningNotesCtrl = TextEditingController();
  String status = 'next';
  String priority = 'normal';
  String readiness = 'ready';
  String size = 'medium';
  String risk = 'low_code';
  String suggestedActor = 'user';
  String verificationNeeded = 'none';
  DateTime? dueAt;

  return showDialog<Map<String, String?>?>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> pickDate() async {
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
            );
            if (picked != null) setState(() => dueAt = picked);
          }

          void submit() {
            final t = titleCtrl.text.trim();
            if (t.isEmpty) return;
            Navigator.of(context).pop({
              'title': t,
              'description': descCtrl.text.trim().isEmpty
                  ? null
                  : descCtrl.text.trim(),
              'owner': ownerCtrl.text.trim().isEmpty
                  ? null
                  : ownerCtrl.text.trim(),
              'status': normalizeStatusValue(status),
              'priority': normalizePriorityValue(priority),
              'blockedReason': blockedCtrl.text.trim().isEmpty
                  ? null
                  : blockedCtrl.text.trim(),
              'readiness': normalizeWorkloadReadiness(readiness),
              'size': normalizeWorkloadSize(size),
              'risk': normalizeWorkloadRisk(risk),
              'suggestedActor': normalizeWorkloadActor(suggestedActor),
              'verificationNeeded': normalizeWorkloadVerification(
                verificationNeeded,
              ),
              'nextAction': nextActionCtrl.text.trim().isEmpty
                  ? null
                  : nextActionCtrl.text.trim(),
              'planningNotes': planningNotesCtrl.text.trim().isEmpty
                  ? null
                  : planningNotesCtrl.text.trim(),
              // ISO 8601 date string, or null — parsed by work_screen.dart
              'dueAt': dueAt != null
                  ? '${dueAt!.year}-'
                        '${dueAt!.month.toString().padLeft(2, '0')}-'
                        '${dueAt!.day.toString().padLeft(2, '0')}'
                  : null,
            });
          }

          return AlertDialog(
            title: const Text('New task'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Title *',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Description (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: normalizeStatusValue(status),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Status',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            items: statusOptions
                                .where(
                                  (s) =>
                                      !['done', 'archived'].contains(s.value),
                                )
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s.value,
                                    child: Text(
                                      s.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setState(() => status = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: normalizePriorityValue(priority),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Priority',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            items: priorityOptions
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p.value,
                                    child: Text(
                                      p.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setState(() => priority = v);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ContactOwnerField(
                            controller: ownerCtrl,
                            label: 'Owner (optional)',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: pickDate,
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Due date',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(
                                  Icons.calendar_today,
                                  size: 18,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      dueAt != null
                                          ? '${dueAt!.month}/${dueAt!.day}'
                                          : 'None',
                                      style: TextStyle(
                                        color: dueAt != null
                                            ? Colors.white
                                            : Colors.white38,
                                      ),
                                    ),
                                  ),
                                  if (dueAt != null)
                                    GestureDetector(
                                      onTap: () => setState(() => dueAt = null),
                                      child: const Icon(
                                        Icons.clear,
                                        size: 16,
                                        color: Colors.white38,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: blockedCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Blocker reason',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _PlanningDropdown(
                            label: 'Readiness',
                            value: readiness,
                            values: workloadReadinessValues,
                            onChanged: (value) =>
                                setState(() => readiness = value),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PlanningDropdown(
                            label: 'Size',
                            value: size,
                            values: workloadSizeValues,
                            onChanged: (value) => setState(() => size = value),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _PlanningDropdown(
                            label: 'Risk',
                            value: risk,
                            values: workloadRiskValues,
                            onChanged: (value) => setState(() => risk = value),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PlanningDropdown(
                            label: 'Actor',
                            value: suggestedActor,
                            values: workloadActorValues,
                            onChanged: (value) =>
                                setState(() => suggestedActor = value),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _PlanningDropdown(
                      label: 'Verification needed',
                      value: verificationNeeded,
                      values: workloadVerificationValues,
                      onChanged: (value) =>
                          setState(() => verificationNeeded = value),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: nextActionCtrl,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Next action',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: planningNotesCtrl,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Planning notes',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: submit, child: const Text('Add')),
            ],
          );
        },
      );
    },
  );
}

class _PlanningDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  const _PlanningDropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: values
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: Text(
                workloadLabel(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}
