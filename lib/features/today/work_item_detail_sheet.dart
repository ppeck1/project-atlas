import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../work/status_priority_helpers.dart';

/// Opens a bottom sheet to view/edit a work item.
Future<void> showWorkItemDetailSheet(BuildContext context, String itemId) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _WorkItemDetailSheet(itemId: itemId),
  );
}

class _WorkItemDetailSheet extends StatefulWidget {
  final String itemId;
  const _WorkItemDetailSheet({required this.itemId});

  @override
  State<_WorkItemDetailSheet> createState() => _WorkItemDetailSheetState();
}

class _WorkItemDetailSheetState extends State<_WorkItemDetailSheet> {
  WorkItem? _item;
  bool _loading = true;
  bool _saving = false;

  late TextEditingController _titleCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _ownerCtrl;
  late TextEditingController _blockedCtrl;
  late TextEditingController _emailInstCtrl;

  String _status = 'next';
  String _priority = 'normal';
  DateTime? _dueAt;
  bool _phoneQueue = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _ownerCtrl = TextEditingController();
    _blockedCtrl = TextEditingController();
    _emailInstCtrl = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final state = AppStateScope.of(context);
    final item = await state.getWorkItem(widget.itemId);
    if (item != null && mounted) {
      setState(() {
        _item = item;
        _titleCtrl.text = item.title;
        _descCtrl.text = item.description ?? '';
        _ownerCtrl.text = item.owner ?? '';
        _blockedCtrl.text = item.blockedReason ?? '';
        _status = item.status;
        _priority = item.priority;
        _dueAt = item.dueAt;
        _phoneQueue = item.phoneQueue;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final state = AppStateScope.of(context);
    setState(() => _saving = true);

    await state.updateWorkItem(
      id: widget.itemId,
      title: _titleCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      owner: _ownerCtrl.text.trim(),
      status: _status,
      priority: _priority,
      clearDueAt: _dueAt == null,
      dueAt: _dueAt,
      blockedReason: _blockedCtrl.text.trim(),
      clearBlockedReason: _blockedCtrl.text.trim().isEmpty,
      phoneQueue: _phoneQueue,
    );

    if (mounted) {
      setState(() => _saving = false);
      Navigator.of(context).pop();
    }
  }

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
    );
    if (picked != null) setState(() => _dueAt = picked);
  }

  Future<void> _showEmailDraft() async {
    final inst = _emailInstCtrl.text.trim();
    if (inst.isEmpty) return;

    final state = AppStateScope.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final result = await state.draftEmailForTask(widget.itemId, inst);

    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss loading

    if (!result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ollama not available or returned empty response.'),
        ),
      );
      return;
    }

    // Show the draft for human review
    await showDialog(
      context: context,
      builder: (ctx) => _OllamaDraftDialog(
        title: 'Email Draft',
        body: result.output!,
        onSave: () async {
          await state.saveDraft(
            kind: 'email_draft',
            title: result.title,
            body: result.output!,
            workItemId: widget.itemId,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _ownerCtrl.dispose();
    _blockedCtrl.dispose();
    _emailInstCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_item == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('Item not found.')),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  // Title
                  Text(
                    'Edit Task',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _descCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Status + Priority row
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Status',
                                style: TextStyle(fontSize: 12, color: Colors.white54)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: _status,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              items: statusOptions
                                  .map((s) => DropdownMenuItem(
                                        value: s.value,
                                        child: Row(
                                          children: [
                                            Icon(s.icon, size: 16, color: s.color),
                                            const SizedBox(width: 8),
                                            Text(s.label),
                                          ],
                                        ),
                                      ))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _status = v);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Priority',
                                style: TextStyle(fontSize: 12, color: Colors.white54)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: _priority,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              items: priorityOptions
                                  .map((p) => DropdownMenuItem(
                                        value: p.value,
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                color: p.color,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(p.label),
                                          ],
                                        ),
                                      ))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _priority = v);
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Owner + Due date row
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ownerCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Owner',
                            prefixIcon: Icon(Icons.person_outline, size: 18),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: _pickDueDate,
                          borderRadius: BorderRadius.circular(4),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Due date',
                              prefixIcon:
                                  Icon(Icons.calendar_today, size: 18),
                              border: OutlineInputBorder(),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _dueAt != null
                                        ? '${_dueAt!.month}/${_dueAt!.day}/${_dueAt!.year}'
                                        : 'None',
                                    style: TextStyle(
                                      color: _dueAt != null
                                          ? Colors.white
                                          : Colors.white38,
                                    ),
                                  ),
                                ),
                                if (_dueAt != null)
                                  GestureDetector(
                                    onTap: () =>
                                        setState(() => _dueAt = null),
                                    child: const Icon(Icons.clear,
                                        size: 16, color: Colors.white38),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Blocked reason
                  TextField(
                    controller: _blockedCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Blocked reason (leave empty if not blocked)',
                      prefixIcon: Icon(Icons.block, size: 18, color: Colors.red),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Phone queue toggle
                  SwitchListTile(
                    value: _phoneQueue,
                    onChanged: (v) => setState(() => _phoneQueue = v),
                    title: const Text('Phone queue / Follow-up call needed'),
                    secondary: const Icon(Icons.phone, size: 20),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(height: 24),

                  // Email draft via Ollama
                  const Text(
                    'Draft email with AI',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Output is shown for your review before saving.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _emailInstCtrl,
                          decoration: const InputDecoration(
                            hintText: 'e.g. "Follow up on delayed delivery"',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _showEmailDraft,
                        child: const Text('Draft'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Actions
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OllamaDraftDialog extends StatelessWidget {
  final String title;
  final String body;
  final Future<void> Function() onSave;

  const _OllamaDraftDialog({
    required this.title,
    required this.body,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Review the AI output below. Save it as a draft or discard.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(body),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () async {
            await onSave();
            if (context.mounted) {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Saved to Drafts.')),
              );
            }
          },
          child: const Text('Save Draft'),
        ),
      ],
    );
  }
}
