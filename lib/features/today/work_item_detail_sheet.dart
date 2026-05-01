import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/document_preview.dart';
import '../work/status_priority_helpers.dart';

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
  Document? _selectedDocument;
  bool _loading = true;
  bool _saving = false;
  bool _analyzing = false;

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
    try {
      final state = AppStateScope.of(context);
      await state.logEvent(
        area: 'work_item_detail',
        action: 'opened',
        entityType: 'work_item',
        entityId: widget.itemId,
      );
      final item = await state.getWorkItem(widget.itemId);

      if (!mounted) return;

      if (item == null) {
        setState(() {
          _item = null;
          _loading = false;
        });
        return;
      }

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
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _item = null;
        _loading = false;
      });

      final state = AppStateScope.of(context);
      await state.logEvent(
        level: 'error',
        area: 'work_item_detail',
        action: 'load_failed',
        entityType: 'work_item',
        entityId: widget.itemId,
        error: e.toString(),
        stackTrace: st.toString(),
      );
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
    Navigator.of(context).pop();

    if (!result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ollama not available or returned empty response.'),
        ),
      );
      return;
    }

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

  Future<void> _editNote([WorkItemNote? note]) async {
    final ctrl = TextEditingController(text: note?.body ?? '');
    final body = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note == null ? 'Add note' : 'Edit note'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (body == null || body.trim().isEmpty) return;
    if (!mounted) return;
    final state = AppStateScope.of(context);
    if (note == null) {
      await state.addWorkItemNote(widget.itemId, body);
    } else {
      await state.updateWorkItemNote(note.id, body);
    }
  }

  Future<String?> _promptPath(String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Local file path',
            hintText: r'C:\Users\you\Documents\spec.md',
          ),
          onSubmitted: (_) => Navigator.of(context).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _importAndLinkDocument() async {
    final path = await _promptPath('Import and link document');
    if (path == null || path.trim().isEmpty) return;
    if (!mounted) return;
    final state = AppStateScope.of(context);
    try {
      await state.importAndLinkDocumentToWorkItem(path, widget.itemId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Imported and linked document.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  Future<void> _linkExistingDocument() async {
    final state = AppStateScope.of(context);
    final doc = await showDialog<Document>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link existing document'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: StreamBuilder<List<Document>>(
            stream: state.watchDocuments(),
            builder: (context, snap) {
              final docs = snap.data ?? const <Document>[];
              if (docs.isEmpty) {
                return const Center(child: Text('No documents imported yet.'));
              }
              return ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(doc.title),
                    subtitle: Text('${doc.status}${doc.extension != null ? ' .${doc.extension}' : ''}'),
                    onTap: () => Navigator.of(context).pop(doc),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (doc == null) return;
    await state.linkDocumentToWorkItem(doc.id, widget.itemId);
  }

  Future<void> _openOriginal(Document doc) async {
    final path = doc.storedPath;
    if (path == null || path.isEmpty) return;
    try {
      await Process.start('explorer.exe', [path]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Opened original file.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Open failed: $e')),
        );
      }
    }
  }

  Future<void> _copyDocumentText(Document doc) async {
    await Clipboard.setData(
      ClipboardData(text: doc.extractedText ?? doc.renderedMarkdown ?? ''),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied document text.')),
      );
    }
  }

  Future<void> _runAnalysis() async {
    final state = AppStateScope.of(context);
    setState(() => _analyzing = true);
    final result = await state.analyzeWorkItemReadOnly(widget.itemId);
    if (!mounted) return;
    setState(() => _analyzing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? 'AI analysis saved.'
              : 'Ollama unavailable or returned empty output.',
        ),
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
        height: 260,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_item == null) {
      return const SizedBox(
        height: 260,
        child: Center(
          child: Text('Work item could not be loaded. Check Log for details.'),
        ),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.97,
      builder: (_, scrollCtrl) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: DefaultTabController(
          length: 5,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _titleCtrl.text.isEmpty ? 'Work Item' : _titleCtrl.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ],
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: 'Overview'),
                  Tab(text: 'Notes'),
                  Tab(text: 'Documents'),
                  Tab(text: 'AI Analysis'),
                  Tab(text: 'Activity Log'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _OverviewTab(
                      scrollCtrl: scrollCtrl,
                      titleCtrl: _titleCtrl,
                      descCtrl: _descCtrl,
                      ownerCtrl: _ownerCtrl,
                      blockedCtrl: _blockedCtrl,
                      emailInstCtrl: _emailInstCtrl,
                      status: _status,
                      priority: _priority,
                      dueAt: _dueAt,
                      phoneQueue: _phoneQueue,
                      onStatusChanged: (v) => setState(() => _status = v),
                      onPriorityChanged: (v) => setState(() => _priority = v),
                      onDueDatePick: _pickDueDate,
                      onClearDueDate: () => setState(() => _dueAt = null),
                      onPhoneQueueChanged: (v) => setState(() => _phoneQueue = v),
                      onDraftEmail: _showEmailDraft,
                    ),
                    _NotesTab(
                      workItemId: widget.itemId,
                      onAdd: () => _editNote(),
                      onEdit: _editNote,
                    ),
                    _DocumentsTab(
                      workItemId: widget.itemId,
                      selected: _selectedDocument,
                      onSelected: (doc) => setState(() => _selectedDocument = doc),
                      onLinkExisting: _linkExistingDocument,
                      onImportAndLink: _importAndLinkDocument,
                      onOpenOriginal: _openOriginal,
                      onCopyText: _copyDocumentText,
                    ),
                    _AnalysisTab(
                      workItemId: widget.itemId,
                      analyzing: _analyzing,
                      onAnalyze: _runAnalysis,
                    ),
                    _ActivityTab(workItemId: widget.itemId),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final ScrollController scrollCtrl;
  final TextEditingController titleCtrl;
  final TextEditingController descCtrl;
  final TextEditingController ownerCtrl;
  final TextEditingController blockedCtrl;
  final TextEditingController emailInstCtrl;
  final String status;
  final String priority;
  final DateTime? dueAt;
  final bool phoneQueue;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String> onPriorityChanged;
  final VoidCallback onDueDatePick;
  final VoidCallback onClearDueDate;
  final ValueChanged<bool> onPhoneQueueChanged;
  final VoidCallback onDraftEmail;

  const _OverviewTab({
    required this.scrollCtrl,
    required this.titleCtrl,
    required this.descCtrl,
    required this.ownerCtrl,
    required this.blockedCtrl,
    required this.emailInstCtrl,
    required this.status,
    required this.priority,
    required this.dueAt,
    required this.phoneQueue,
    required this.onStatusChanged,
    required this.onPriorityChanged,
    required this.onDueDatePick,
    required this.onClearDueDate,
    required this.onPhoneQueueChanged,
    required this.onDraftEmail,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        TextField(
          controller: titleCtrl,
          decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: descCtrl,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status', border: OutlineInputBorder()),
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
                  if (v != null) onStatusChanged(v);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: priority,
                decoration: const InputDecoration(labelText: 'Priority', border: OutlineInputBorder()),
                items: priorityOptions
                    .map((p) => DropdownMenuItem(
                          value: p.value,
                          child: Row(
                            children: [
                              Container(width: 10, height: 10, decoration: BoxDecoration(color: p.color, shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Text(p.label),
                            ],
                          ),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) onPriorityChanged(v);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: ownerCtrl,
                decoration: const InputDecoration(labelText: 'Owner', prefixIcon: Icon(Icons.person_outline, size: 18), border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: onDueDatePick,
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Due date', prefixIcon: Icon(Icons.calendar_today, size: 18), border: OutlineInputBorder()),
                  child: Row(
                    children: [
                      Expanded(child: Text(dueAt != null ? '${dueAt!.month}/${dueAt!.day}/${dueAt!.year}' : 'None')),
                      if (dueAt != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: onClearDueDate,
                          icon: const Icon(Icons.clear, size: 16),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: blockedCtrl,
          decoration: const InputDecoration(labelText: 'Blocked reason', prefixIcon: Icon(Icons.block, size: 18, color: Colors.red), border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          value: phoneQueue,
          onChanged: onPhoneQueueChanged,
          title: const Text('Phone queue / Follow-up call needed'),
          secondary: const Icon(Icons.phone, size: 20),
          contentPadding: EdgeInsets.zero,
        ),
        const Divider(height: 28),
        Text('Draft email with AI', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: emailInstCtrl,
                decoration: const InputDecoration(hintText: 'e.g. Follow up on delayed delivery', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onDraftEmail, child: const Text('Draft')),
          ],
        ),
      ],
    );
  }
}

class _NotesTab extends StatelessWidget {
  final String workItemId;
  final VoidCallback onAdd;
  final ValueChanged<WorkItemNote> onEdit;

  const _NotesTab({required this.workItemId, required this.onAdd, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add note')),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<WorkItemNote>>(
            stream: state.watchNotesForWorkItem(workItemId),
            builder: (context, snap) {
              final notes = snap.data ?? const <WorkItemNote>[];
              if (notes.isEmpty) return const Center(child: Text('No notes yet.'));
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: notes.length,
                itemBuilder: (context, index) {
                  final note = notes[index];
                  return Card(
                    child: ListTile(
                      title: SelectableText(note.body),
                      subtitle: Text('Updated ${note.updatedAt}'),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            tooltip: 'Edit note',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => onEdit(note),
                          ),
                          IconButton(
                            tooltip: 'Delete note',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => state.deleteWorkItemNote(note.id),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DocumentsTab extends StatelessWidget {
  final String workItemId;
  final Document? selected;
  final ValueChanged<Document> onSelected;
  final VoidCallback onLinkExisting;
  final VoidCallback onImportAndLink;
  final ValueChanged<Document> onOpenOriginal;
  final ValueChanged<Document> onCopyText;

  const _DocumentsTab({
    required this.workItemId,
    required this.selected,
    required this.onSelected,
    required this.onLinkExisting,
    required this.onImportAndLink,
    required this.onOpenOriginal,
    required this.onCopyText,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(onPressed: onLinkExisting, icon: const Icon(Icons.link), label: const Text('Link existing document')),
              OutlinedButton.icon(onPressed: onImportAndLink, icon: const Icon(Icons.upload_file), label: const Text('Import and link document')),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Document>>(
            stream: state.watchDocumentsForWorkItem(workItemId),
            builder: (context, snap) {
              final docs = snap.data ?? const <Document>[];
              final active = selected != null && docs.any((d) => d.id == selected!.id)
                  ? selected!
                  : (docs.isNotEmpty ? docs.first : null);
              if (docs.isEmpty) {
                return const Center(child: Text('No documents linked to this work item.'));
              }
              return Row(
                children: [
                  SizedBox(
                    width: 300,
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        return Card(
                          child: ListTile(
                            selected: active?.id == doc.id,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${doc.status}${doc.extension != null ? ' .${doc.extension}' : ''}'),
                            onTap: () => onSelected(doc),
                            trailing: IconButton(
                              tooltip: 'Unlink document',
                              icon: const Icon(Icons.link_off),
                              onPressed: () => state.unlinkDocumentFromWorkItem(doc.id, workItemId),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: active == null
                        ? const Center(child: Text('Select a document.'))
                        : Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(active.title, style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 4),
                                Text('Status: ${active.status} | Stored: ${active.storedPath ?? 'n/a'}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    OutlinedButton.icon(onPressed: () => onOpenOriginal(active), icon: const Icon(Icons.open_in_new), label: const Text('Open original')),
                                    OutlinedButton.icon(onPressed: () => onCopyText(active), icon: const Icon(Icons.copy), label: const Text('Copy text')),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withAlpha(8),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white12),
                                    ),
                                    child: SingleChildScrollView(child: DocumentPreview(document: active)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnalysisTab extends StatelessWidget {
  final String workItemId;
  final bool analyzing;
  final VoidCallback onAnalyze;

  const _AnalysisTab({required this.workItemId, required this.analyzing, required this.onAnalyze});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: analyzing ? null : onAnalyze,
              icon: analyzing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.psychology_outlined),
              label: const Text('Run read-only analysis'),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<WorkItemAnalysis>>(
            stream: state.watchAnalysesForWorkItem(workItemId),
            builder: (context, snap) {
              final analyses = snap.data ?? const <WorkItemAnalysis>[];
              if (analyses.isEmpty) return const Center(child: Text('No AI analyses saved yet.'));
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                itemCount: analyses.length,
                itemBuilder: (context, index) {
                  final analysis = analyses[index];
                  return Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.psychology_outlined),
                      title: Text('Analysis ${analysis.createdAt}'),
                      subtitle: Text(analysis.model ?? 'model not recorded'),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [SelectableText(analysis.output)],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ActivityTab extends StatelessWidget {
  final String workItemId;

  const _ActivityTab({required this.workItemId});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<EventLogData>>(
      stream: state.watchRecentEvents(),
      builder: (context, snap) {
        final rows = (snap.data ?? const <EventLogData>[])
            .where((e) => e.entityId == workItemId || e.inputJson?.contains(workItemId) == true)
            .toList();
        if (rows.isEmpty) return const Center(child: Text('No activity logged for this work item yet.'));
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final e = rows[index];
            return Card(
              child: ExpansionTile(
                leading: Icon(Icons.circle, size: 10, color: e.level == 'error' ? Colors.redAccent : e.level == 'warn' ? Colors.orangeAccent : Colors.white70),
                title: Text('${e.area}.${e.action}'),
                subtitle: Text('${e.timestamp} | ${e.level}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  if (e.inputJson != null) SelectableText('Input:\n${e.inputJson}'),
                  if (e.outputJson != null) SelectableText('Output:\n${e.outputJson}'),
                  if (e.error != null) SelectableText('Error:\n${e.error}'),
                  if (e.stackTrace != null) SelectableText('Stack:\n${e.stackTrace}', style: const TextStyle(fontSize: 11)),
                ],
              ),
            );
          },
        );
      },
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
