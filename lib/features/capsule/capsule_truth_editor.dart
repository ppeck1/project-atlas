import 'package:flutter/material.dart';

import '../../services/project_capsule_truth_service.dart';
import '../../shared/models/project_capsule_truth.dart';
import '../../shared/models/project_metadata.dart';
import '../../services/workload_planning_service.dart';

typedef CapsuleTruthAcceptor =
    Future<void> Function(
      Map<String, Object?> fields,
      String expectedRevisionId,
      String? reason,
    );

Future<bool> showCapsuleTruthEditor({
  required BuildContext context,
  required ProjectCapsuleTruth truth,
  required String revisionId,
  required CapsuleTruthAcceptor onAccept,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CapsuleTruthEditorDialog(
          initialTruth: truth,
          revisionId: revisionId,
          onAccept: onAccept,
        ),
      ) ??
      false;
}

Future<void> showCapsuleTruthHistory({
  required BuildContext context,
  required List<ProjectCapsuleAcceptedRevision> revisions,
  required String? currentRevisionId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Accepted truth history',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close history',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Immutable accepted revisions. Work, evidence, and freshness remain live derived state.',
              ),
              const SizedBox(height: 16),
              Expanded(
                child: revisions.isEmpty
                    ? const Center(
                        child: Text('No accepted truth revision is recorded.'),
                      )
                    : ListView.separated(
                        key: const Key('capsule-truth-history-list'),
                        itemCount: revisions.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final revision = revisions[index];
                          return Card(
                            margin: EdgeInsets.zero,
                            child: ExpansionTile(
                              initiallyExpanded: index == 0,
                              title: Text(
                                'Truth revision ${revision.revisionNumber}',
                              ),
                              subtitle: Text(
                                '${revision.actorLabel} · ${_timestamp(revision.acceptedAt)}',
                              ),
                              trailing: revision.id == currentRevisionId
                                  ? const Chip(label: Text('Current head'))
                                  : index == 0 && currentRevisionId == null
                                  ? const Chip(label: Text('Latest recorded'))
                                  : null,
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                0,
                                16,
                                16,
                              ),
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Source: ${workloadLabel(revision.sourceKind)}',
                                  ),
                                ),
                                if (revision.reason != null) ...[
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('Note: ${revision.reason}'),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                if (revision.changedFields.isEmpty)
                                  const Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('Baseline accepted truth.'),
                                  )
                                else
                                  for (final entry
                                      in revision.changedFields.entries)
                                    _TruthDiffRow(
                                      fieldKey: entry.key,
                                      change: entry.value,
                                    ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CapsuleTruthEditorDialog extends StatefulWidget {
  final ProjectCapsuleTruth initialTruth;
  final String revisionId;
  final CapsuleTruthAcceptor onAccept;

  const _CapsuleTruthEditorDialog({
    required this.initialTruth,
    required this.revisionId,
    required this.onAccept,
  });

  @override
  State<_CapsuleTruthEditorDialog> createState() =>
      _CapsuleTruthEditorDialogState();
}

class _CapsuleTruthEditorDialogState extends State<_CapsuleTruthEditorDialog> {
  late final Map<String, TextEditingController> _controllers;
  late String _status;
  String? _phase;
  String? _priority;
  final _reasonController = TextEditingController();
  ProjectCapsuleTruth? _proposed;
  Map<String, ProjectCapsuleTruthChange> _changes = const {};
  String? _error;
  bool _saving = false;

  bool get _reviewing => _proposed != null;

  @override
  void initState() {
    super.initState();
    final truth = widget.initialTruth;
    _controllers = {
      'title': TextEditingController(text: truth.title),
      'owner': TextEditingController(text: truth.owner ?? ''),
      'category': TextEditingController(text: truth.category ?? ''),
      'description': TextEditingController(text: truth.description ?? ''),
      'desiredOutcome': TextEditingController(text: truth.desiredOutcome ?? ''),
      'successCriteria': TextEditingController(
        text: truth.successCriteria ?? '',
      ),
      'scopeIncluded': TextEditingController(text: truth.scopeIncluded ?? ''),
      'scopeExcluded': TextEditingController(text: truth.scopeExcluded ?? ''),
      'outcomeSummary': TextEditingController(text: truth.outcomeSummary ?? ''),
    };
    _status = truth.status;
    _phase = truth.phase;
    _priority = truth.priority;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _reasonController.dispose();
    super.dispose();
  }

  ProjectCapsuleTruth _readTruth() {
    return ProjectCapsuleTruth.fromJson({
      for (final entry in _controllers.entries) entry.key: entry.value.text,
      'status': _status,
      'phase': _phase,
      'priority': _priority,
    });
  }

  void _review() {
    if (_controllers['title']!.text.trim().isEmpty) {
      setState(() {
        _error = 'Project title is required.';
        _proposed = null;
        _changes = const {};
      });
      return;
    }
    final proposed = _readTruth();
    final errors = proposed.validate();
    final changes = widget.initialTruth.diff(proposed);
    setState(() {
      _error = errors.isNotEmpty
          ? errors.join(' ')
          : changes.isEmpty
          ? 'No accepted truth fields changed.'
          : null;
      if (_error == null) {
        _proposed = proposed;
        _changes = changes;
      }
    });
  }

  Future<void> _save() async {
    final proposed = _proposed;
    if (proposed == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onAccept(
        {for (final entry in _changes.entries) entry.key: entry.value.after},
        widget.revisionId,
        _clean(_reasonController.text),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is ProjectCapsuleTruthConflict
            ? 'Accepted truth changed while this editor was open. Your input '
                  'is still here; reopen against the current revision before saving.'
            : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(_reviewing ? Icons.compare_arrows : Icons.edit_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _reviewing
                          ? 'Review accepted truth changes'
                          : 'Edit accepted project truth',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _reviewing
                    ? 'Nothing changes until you explicitly save this reviewed diff.'
                    : 'Edit human-authored project truth. Live work, evidence, risks, decisions, and recommendations remain derived.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Material(
                  key: const Key('capsule-edit-error'),
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(_error!),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Expanded(child: _reviewing ? _reviewView() : _editView()),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (_reviewing) {
                              setState(() {
                                _proposed = null;
                                _changes = const {};
                                _error = null;
                              });
                            } else {
                              Navigator.pop(context, false);
                            }
                          },
                    child: Text(_reviewing ? 'Back to edit' : 'Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (_reviewing)
                    FilledButton.icon(
                      key: const Key('capsule-save-accepted'),
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined),
                      label: const Text('Save accepted truth'),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('capsule-review-changes'),
                      onPressed: _review,
                      icon: const Icon(Icons.compare_arrows),
                      label: const Text('Review changes'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editView() {
    return ListView(
      key: const Key('capsule-truth-editor-fields'),
      children: [
        _EditorGroup(
          title: 'Identity',
          children: [
            _field('title', 'Project title', key: 'capsule-edit-title'),
            _field('owner', 'Owner'),
            _field('category', 'Category'),
          ],
        ),
        _EditorGroup(
          title: 'Intent',
          children: [
            _field('description', 'Description', multiline: true),
            _field(
              'desiredOutcome',
              'Desired outcome',
              key: 'capsule-edit-desired-outcome',
              multiline: true,
            ),
            _field('successCriteria', 'Success criteria', multiline: true),
          ],
        ),
        _EditorGroup(
          title: 'Operating state',
          children: [
            DropdownButtonFormField<String>(
              key: const Key('capsule-edit-status'),
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [
                for (final option in projectStatusOptions)
                  DropdownMenuItem(
                    value: option.value,
                    child: Text(option.label),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _status = value);
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              key: const Key('capsule-edit-phase'),
              initialValue: _phase,
              decoration: const InputDecoration(labelText: 'Phase'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Not set'),
                ),
                for (final value in projectCapsulePhaseValues)
                  DropdownMenuItem(
                    value: value,
                    child: Text(workloadLabel(value)),
                  ),
              ],
              onChanged: (value) => setState(() => _phase = value),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              key: const Key('capsule-edit-priority'),
              initialValue: _priority,
              decoration: const InputDecoration(labelText: 'Priority'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Not set'),
                ),
                for (final value in projectCapsulePriorityValues)
                  DropdownMenuItem(
                    value: value,
                    child: Text(workloadLabel(value)),
                  ),
              ],
              onChanged: (value) => setState(() => _priority = value),
            ),
          ],
        ),
        _EditorGroup(
          title: 'Scope',
          children: [
            _field('scopeIncluded', 'Included', multiline: true),
            _field('scopeExcluded', 'Excluded', multiline: true),
          ],
        ),
        _EditorGroup(
          title: 'Accepted summary',
          children: [
            _field('outcomeSummary', 'Outcome summary', multiline: true),
          ],
        ),
      ],
    );
  }

  Widget _reviewView() {
    return ListView(
      key: const Key('capsule-truth-review-diff'),
      children: [
        for (final entry in _changes.entries)
          _TruthDiffRow(fieldKey: entry.key, change: entry.value),
        const SizedBox(height: 10),
        TextField(
          controller: _reasonController,
          decoration: const InputDecoration(
            labelText: 'Acceptance note (optional)',
            hintText: 'Why this truth changed',
          ),
          maxLines: 2,
        ),
      ],
    );
  }

  Widget _field(
    String fieldKey,
    String label, {
    String? key,
    bool multiline = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        key: key == null ? null : Key(key),
        controller: _controllers[fieldKey],
        decoration: InputDecoration(labelText: label),
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 5 : 1,
      ),
    );
  }
}

class _EditorGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _EditorGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _TruthDiffRow extends StatelessWidget {
  final String fieldKey;
  final ProjectCapsuleTruthChange change;

  const _TruthDiffRow({required this.fieldKey, required this.change});

  @override
  Widget build(BuildContext context) {
    final label = projectCapsuleTruthFieldLabels[fieldKey] ?? fieldKey;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 7),
            Text('Current: ${_display(change.before)}'),
            const SizedBox(height: 4),
            Text('Proposed: ${_display(change.after)}'),
          ],
        ),
      ),
    );
  }
}

String _display(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? 'Not defined' : text;
}

String _timestamp(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

String? _clean(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
