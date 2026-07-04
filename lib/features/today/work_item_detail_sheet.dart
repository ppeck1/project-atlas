import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../services/workload_planning_service.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/document_preview.dart';
import '../../shared/widgets/contact_picker.dart';
import '../work/status_priority_helpers.dart';

/// Opens a bottom sheet to view/edit a work item.
Future<void> showWorkItemDetailSheet(
  BuildContext context,
  String itemId,
) async {
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
  late AppState _state;
  WorkItem? _item;
  bool _loading = true;
  bool _saving = false;
  bool _didLoad = false;
  bool _draftingEmail = false;
  bool _runningAnalysis = false;
  Document? _selectedDocument;

  late TextEditingController _titleCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _ownerCtrl;
  late TextEditingController _blockedCtrl;
  late TextEditingController _nextActionCtrl;
  late TextEditingController _planningNotesCtrl;
  late TextEditingController _emailInstCtrl;
  late TextEditingController _noteCtrl;

  String _status = 'next';
  String _priority = 'normal';
  String _readiness = 'ready';
  String _size = 'medium';
  String _risk = 'low_code';
  String _suggestedActor = 'user';
  String _verificationNeeded = 'none';
  DateTime? _dueAt;
  bool _phoneQueue = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _ownerCtrl = TextEditingController();
    _blockedCtrl = TextEditingController();
    _nextActionCtrl = TextEditingController();
    _planningNotesCtrl = TextEditingController();
    _emailInstCtrl = TextEditingController();
    _noteCtrl = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = AppStateScope.of(context);
    if (_didLoad) return;
    _didLoad = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    try {
      await _state.db.logEvent(
        area: 'ui',
        action: 'work_item_open_request',
        entityType: 'work_item',
        entityId: widget.itemId,
      );
      final item = await _state.getWorkItem(widget.itemId);
      if (!mounted) return;
      setState(() {
        _item = item;
        if (item != null) {
          _titleCtrl.text = item.title;
          _descCtrl.text = item.description ?? '';
          _ownerCtrl.text = item.owner ?? '';
          _blockedCtrl.text = item.blockedReason ?? '';
          _nextActionCtrl.text = item.nextAction ?? '';
          _planningNotesCtrl.text = item.planningNotes ?? '';
          _status = normalizeStatusValue(item.status);
          _priority = normalizePriorityValue(item.priority);
          _readiness = normalizeWorkloadReadiness(item.readiness);
          _size = normalizeWorkloadSize(item.size);
          _risk = normalizeWorkloadRisk(item.risk);
          _suggestedActor = normalizeWorkloadActor(item.suggestedActor);
          _verificationNeeded = normalizeWorkloadVerification(
            item.verificationNeeded,
          );
          _dueAt = item.dueAt;
          _phoneQueue = item.phoneQueue;
        }
        _loading = false;
      });
      if (item == null) {
        await _state.db.logEvent(
          level: 'error',
          area: 'ui',
          action: 'work_item_detail_load_missing',
          entityType: 'work_item',
          entityId: widget.itemId,
          inputJson: widget.itemId,
        );
      } else {
        await _state.db.logEvent(
          area: 'ui',
          action: 'work_item_open_success',
          entityType: 'work_item',
          entityId: widget.itemId,
        );
      }
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _item = null;
        _loading = false;
      });
      await _state.db.logError(
        area: 'work_item_detail',
        action: 'load_failed',
        entityType: 'work_item',
        entityId: widget.itemId,
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _state.updateWorkItem(
      id: widget.itemId,
      title: _titleCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      owner: _ownerCtrl.text.trim(),
      status: normalizeStatusValue(_status),
      priority: normalizePriorityValue(_priority),
      clearDueAt: _dueAt == null,
      dueAt: _dueAt,
      blockedReason: _blockedCtrl.text.trim(),
      clearBlockedReason: _blockedCtrl.text.trim().isEmpty,
      phoneQueue: _phoneQueue,
      readiness: _readiness,
      size: _size,
      risk: _risk,
      suggestedActor: _suggestedActor,
      verificationNeeded: _verificationNeeded,
      nextAction: _nextActionCtrl.text.trim(),
      clearNextAction: _nextActionCtrl.text.trim().isEmpty,
      planningNotes: _planningNotesCtrl.text.trim(),
      clearPlanningNotes: _planningNotesCtrl.text.trim().isEmpty,
    );
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Work item saved.')));
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
    if (inst.isEmpty || _draftingEmail) return;
    setState(() => _draftingEmail = true);
    final result = await _state.draftEmailForTask(widget.itemId, inst);
    if (!mounted) return;
    setState(() => _draftingEmail = false);

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
          await _state.saveDraft(
            kind: 'email_draft',
            title: result.title,
            body: result.output!,
            workItemId: widget.itemId,
          );
        },
      ),
    );
  }

  Future<void> _addNote() async {
    final body = _noteCtrl.text.trim();
    if (body.isEmpty) return;
    await _state.addWorkItemNote(widget.itemId, body);
    _noteCtrl.clear();
  }

  Future<void> _editNote(WorkItemNote note) async {
    final ctrl = TextEditingController(text: note.body);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit note'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (updated != null) await _state.updateWorkItemNote(note.id, updated);
  }

  Future<void> _deleteNote(WorkItemNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This note will be removed from the work item.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await _state.deleteWorkItemNote(note.id);
  }

  Future<void> _linkExistingDocument(List<Document> alreadyLinked) async {
    final linkedIds = alreadyLinked.map((d) => d.id).toSet();
    final document = await showDialog<Document>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 520,
          height: 520,
          child: StreamBuilder<List<Document>>(
            stream: _state.watchDocuments(),
            builder: (context, snap) {
              final docs = snap.data ?? const <Document>[];
              return Column(
                children: [
                  const ListTile(title: Text('Link existing document')),
                  const Divider(height: 1),
                  Expanded(
                    child: docs.isEmpty
                        ? const Center(child: Text('No library documents yet.'))
                        : ListView.builder(
                            itemCount: docs.length,
                            itemBuilder: (context, index) {
                              final d = docs[index];
                              final linked = linkedIds.contains(d.id);
                              return ListTile(
                                leading: const Icon(Icons.description_outlined),
                                title: Text(d.title),
                                subtitle: Text(d.originalFilename),
                                enabled: !linked,
                                trailing: linked ? const Text('Linked') : null,
                                onTap: linked
                                    ? null
                                    : () => Navigator.pop(ctx, d),
                              );
                            },
                          ),
                  ),
                  ButtonBar(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (document != null) {
      await _state.linkDocumentToWorkItem(document.id, widget.itemId);
      if (mounted) setState(() => _selectedDocument = document);
    }
  }

  Future<void> _importDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    try {
      await _state.importDocumentFromPath(path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Document imported. Use Link existing document to attach it.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _importMedia() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    try {
      for (final file in result.files) {
        final path = file.path;
        if (path == null || path.trim().isEmpty) continue;
        await _state.importWorkItemMediaFromPath(widget.itemId, path);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Media attached.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Media import failed: $e')));
      }
    }
  }

  Future<void> _runAnalysis() async {
    if (_runningAnalysis) return;
    setState(() => _runningAnalysis = true);
    final result = await _state.analyzeWorkItemReadOnly(widget.itemId);
    if (!mounted) return;
    setState(() => _runningAnalysis = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? 'Analysis saved.'
              : 'AI analysis failed. Check Log for details.',
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
    _nextActionCtrl.dispose();
    _planningNotesCtrl.dispose();
    _emailInstCtrl.dispose();
    _noteCtrl.dispose();
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
      return SizedBox(
        height: 320,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 32),
                const SizedBox(height: 12),
                const Text(
                  'Work item could not be loaded.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text('Requested ID:'),
                SelectableText(widget.itemId),
                const SizedBox(height: 12),
                const Text(
                  'This usually means the row passed the wrong ID. Check Log for known work item IDs.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.96,
      builder: (_, scrollCtrl) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DefaultTabController(
          length: 6,
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
                        _item!.title,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: 'Details'),
                  Tab(text: 'Notes'),
                  Tab(text: 'Documents'),
                  Tab(text: 'AI Analysis'),
                  Tab(text: 'Email Draft'),
                  Tab(text: 'Activity'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _detailsTab(scrollCtrl),
                    _notesTab(),
                    _documentsTab(),
                    _analysisTab(),
                    _emailTab(),
                    _activityTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailsTab(ScrollController scrollCtrl) {
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.all(20),
      children: [
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
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Description',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: normalizeStatusValue(_status),
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: statusOptions
                    .map(
                      (s) => DropdownMenuItem(
                        value: s.value,
                        child: Text(s.label),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _status = v);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: normalizePriorityValue(_priority),
                decoration: const InputDecoration(
                  labelText: 'Priority',
                  border: OutlineInputBorder(),
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
                  if (v != null) setState(() => _priority = v);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: ContactOwnerField(controller: _ownerCtrl)),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickDueDate,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  _dueAt == null
                      ? 'No due date'
                      : '${_dueAt!.month}/${_dueAt!.day}/${_dueAt!.year}',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _blockedCtrl,
          decoration: const InputDecoration(
            labelText: 'Blocked reason',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _PlanningDropdown(
                label: 'Readiness',
                value: _readiness,
                values: workloadReadinessValues,
                onChanged: (value) => setState(() => _readiness = value),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PlanningDropdown(
                label: 'Size',
                value: _size,
                values: workloadSizeValues,
                onChanged: (value) => setState(() => _size = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _PlanningDropdown(
                label: 'Risk',
                value: _risk,
                values: workloadRiskValues,
                onChanged: (value) => setState(() => _risk = value),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PlanningDropdown(
                label: 'Actor',
                value: _suggestedActor,
                values: workloadActorValues,
                onChanged: (value) => setState(() => _suggestedActor = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PlanningDropdown(
          label: 'Verification needed',
          value: _verificationNeeded,
          values: workloadVerificationValues,
          onChanged: (value) => setState(() => _verificationNeeded = value),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nextActionCtrl,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Next action',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _planningNotesCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Planning notes',
            border: OutlineInputBorder(),
          ),
        ),
        SwitchListTile(
          value: _phoneQueue,
          onChanged: (v) => setState(() => _phoneQueue = v),
          title: const Text('Phone queue / follow-up call needed'),
          contentPadding: EdgeInsets.zero,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Save Details'),
          ),
        ),
      ],
    );
  }

  Widget _notesTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _noteCtrl,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Add note',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _addNote, child: const Text('Add')),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<WorkItemNote>>(
            stream: _state.watchNotesForWorkItem(widget.itemId),
            builder: (context, snap) {
              final notes = snap.data ?? const <WorkItemNote>[];
              if (notes.isEmpty)
                return const Center(child: Text('No notes yet.'));
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: notes.length,
                itemBuilder: (context, index) {
                  final n = notes[index];
                  return Card(
                    child: ListTile(
                      title: SelectableText(n.body),
                      subtitle: Text('Updated ${n.updatedAt}'),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            onPressed: () => _editNote(n),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => _deleteNote(n),
                            icon: const Icon(Icons.delete_outline),
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

  Widget _documentsTab() {
    return StreamBuilder<List<Document>>(
      stream: _state.watchDocumentsForWorkItem(widget.itemId),
      builder: (context, snap) {
        final docs = snap.data ?? const <Document>[];
        final selected =
            _selectedDocument != null &&
                docs.any((d) => d.id == _selectedDocument!.id)
            ? _selectedDocument!
            : (docs.isNotEmpty ? docs.first : null);
        return Row(
          children: [
            SizedBox(
              width: 300,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _linkExistingDocument(docs),
                          icon: const Icon(Icons.link),
                          label: const Text('Link existing document'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _importDocument,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Import document'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _importMedia,
                          icon: const Icon(Icons.perm_media_outlined),
                          label: const Text('Attach media'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: docs.isEmpty
                        ? const Center(child: Text('No linked documents yet.'))
                        : ListView.builder(
                            itemCount: docs.length,
                            itemBuilder: (context, index) {
                              final d = docs[index];
                              return ListTile(
                                selected: selected?.id == d.id,
                                leading: const Icon(Icons.description_outlined),
                                title: Text(
                                  d.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  d.originalFilename,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () =>
                                    setState(() => _selectedDocument = d),
                                trailing: IconButton(
                                  tooltip: 'Unlink',
                                  icon: const Icon(Icons.link_off),
                                  onPressed: () =>
                                      _state.unlinkDocumentFromWorkItem(
                                        d.id,
                                        widget.itemId,
                                      ),
                                ),
                              );
                            },
                          ),
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 210,
                    child: StreamBuilder<List<ProjectMediaItem>>(
                      stream: _state.watchMediaForWorkItem(widget.itemId),
                      builder: (context, mediaSnap) {
                        final media =
                            mediaSnap.data ?? const <ProjectMediaItem>[];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(12, 10, 12, 4),
                              child: Text(
                                'Attached media',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Expanded(
                              child: media.isEmpty
                                  ? const Center(
                                      child: Text('No media attached.'),
                                    )
                                  : ListView.builder(
                                      itemCount: media.length,
                                      itemBuilder: (context, index) {
                                        final item = media[index];
                                        return ListTile(
                                          dense: true,
                                          leading: Icon(
                                            _mediaIcon(item.mediaType),
                                            size: 18,
                                          ),
                                          title: Text(
                                            item.title,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: Text(
                                            item.originalFilename,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          trailing: Wrap(
                                            spacing: 4,
                                            children: [
                                              IconButton(
                                                tooltip: 'Open original',
                                                icon: const Icon(
                                                  Icons.open_in_new,
                                                  size: 18,
                                                ),
                                                onPressed: () => Process.start(
                                                  'explorer.exe',
                                                  [item.storedPath],
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Unlink media',
                                                icon: const Icon(
                                                  Icons.link_off,
                                                  size: 18,
                                                ),
                                                onPressed: () => _state
                                                    .unlinkProjectMediaFromWorkItem(
                                                      widget.itemId,
                                                      item.id,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? const Center(
                      child: Text('Select a linked document to preview it.'),
                    )
                  : Column(
                      children: [
                        ListTile(
                          title: Text(
                            selected.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                tooltip: 'Open original',
                                icon: const Icon(Icons.open_in_new),
                                onPressed: selected.storedPath == null
                                    ? null
                                    : () => Process.start('explorer.exe', [
                                        selected.storedPath!,
                                      ]),
                              ),
                              IconButton(
                                tooltip: 'Copy text',
                                icon: const Icon(Icons.copy),
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text:
                                          selected.renderedMarkdown ??
                                          selected.extractedText ??
                                          '',
                                    ),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Copied document text.'),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(child: DocumentPreview(document: selected)),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _analysisTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Read-only analysis can summarize, identify blockers, list next actions, flag ambiguity, and estimate risk. It does not mutate tasks, documents, or notes.',
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _runningAnalysis ? null : _runAnalysis,
                icon: _runningAnalysis
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.psychology_outlined),
                label: const Text('Run Analysis'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<List<WorkItemAnalysis>>(
            stream: _state.watchAnalysesForWorkItem(widget.itemId),
            builder: (context, snap) {
              final analyses = snap.data ?? const <WorkItemAnalysis>[];
              if (analyses.isEmpty)
                return const Center(child: Text('No saved analyses yet.'));
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: analyses.length,
                itemBuilder: (context, index) {
                  final a = analyses[index];
                  return Card(
                    child: ExpansionTile(
                      title: Text(
                        a.model == null
                            ? 'Saved analysis'
                            : 'Saved analysis - ${a.model}',
                      ),
                      subtitle: Text(a.createdAt.toString()),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(a.output),
                        ),
                      ],
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

  Widget _emailTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Output is shown for your review before saving.'),
        const SizedBox(height: 12),
        TextField(
          controller: _emailInstCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'e.g. Follow up on delayed delivery',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _draftingEmail ? null : _showEmailDraft,
            icon: _draftingEmail
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: const Text('Draft Email'),
          ),
        ),
      ],
    );
  }

  Widget _activityTab() {
    return StreamBuilder<List<EventLogData>>(
      stream: _state.watchRecentEvents(),
      builder: (context, snap) {
        final events = (snap.data ?? const <EventLogData>[])
            .where(
              (e) =>
                  e.entityId == widget.itemId ||
                  e.inputJson?.contains(widget.itemId) == true,
            )
            .toList(growable: false);
        if (events.isEmpty)
          return const Center(
            child: Text('No activity logged for this work item yet.'),
          );
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: events.length,
          itemBuilder: (context, index) {
            final e = events[index];
            return Card(
              child: ExpansionTile(
                title: Text('${e.area}.${e.action}'),
                subtitle: Text('${e.level} - ${e.timestamp}'),
                children: [
                  if (e.inputJson != null)
                    ListTile(
                      title: const Text('Input'),
                      subtitle: SelectableText(e.inputJson!),
                    ),
                  if (e.outputJson != null)
                    ListTile(
                      title: const Text('Output'),
                      subtitle: SelectableText(e.outputJson!),
                    ),
                  if (e.error != null)
                    ListTile(
                      title: const Text('Error'),
                      subtitle: SelectableText(e.error!),
                    ),
                  if (e.stackTrace != null)
                    ListTile(
                      title: const Text('Stack'),
                      subtitle: SelectableText(e.stackTrace!),
                    ),
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
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Saved to Drafts.')));
            }
          },
          child: const Text('Save Draft'),
        ),
      ],
    );
  }
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
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: values
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: Text(workloadLabel(value)),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

IconData _mediaIcon(String mediaType) {
  return switch (mediaType) {
    'image' => Icons.image_outlined,
    'video' => Icons.movie_outlined,
    'audio' => Icons.audiotrack_outlined,
    'folder' => Icons.folder_outlined,
    _ => Icons.perm_media_outlined,
  };
}
