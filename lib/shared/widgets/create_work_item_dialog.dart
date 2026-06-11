import 'package:flutter/material.dart';
import '../../features/work/status_priority_helpers.dart';
import 'contact_picker.dart';

Future<Map<String, String?>?> showCreateWorkItemDialog(
  BuildContext context,
) async {
  final titleCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final ownerCtrl = TextEditingController();
  String status = 'next';
  String priority = 'normal';
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
              width: 420,
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
                                (s) => !['done', 'archived'].contains(s.value),
                              )
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s.value,
                                  child: Text(s.label),
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
                                  child: Text(p.label),
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
                              prefixIcon: Icon(Icons.calendar_today, size: 18),
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
                ],
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
