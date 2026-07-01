import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/models/project_metadata.dart';
import '../../shared/widgets/contact_picker.dart';
import '../work/status_priority_helpers.dart';

const _dialogPanel = Color(0xFF151A22);
const _dialogLine = Color(0xFF273044);
const _categoryNone = '__none__';
const _categoryCustom = '__custom__';

const _projectPhases = [
  '',
  'idea',
  'design',
  'build',
  'test',
  'ship',
  'stabilize',
];
const _projectPriorities = ['low', 'normal', 'high', 'urgent'];

Future<bool?> showProjectMetadataDialog(
  BuildContext context,
  Project project,
) async {
  final state = AppStateScope.of(context);
  final projects = await state.getVisibleProjects();
  if (!context.mounted) return false;

  final categories = {
    for (final row in projects)
      if (normalizeProjectCategory(row.category) != null)
        normalizeProjectCategory(row.category)!,
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return showDialog<bool>(
    context: context,
    builder: (ctx) =>
        ProjectMetadataDialog(project: project, categories: categories),
  );
}

class ProjectMetadataDialog extends StatefulWidget {
  final Project project;
  final List<String> categories;
  final bool includeOwnerField;

  const ProjectMetadataDialog({
    super.key,
    required this.project,
    required this.categories,
    this.includeOwnerField = true,
  });

  @override
  State<ProjectMetadataDialog> createState() => _ProjectMetadataDialogState();
}

class _ProjectMetadataDialogState extends State<ProjectMetadataDialog> {
  late String _status = normalizeProjectStatusValue(widget.project.status);
  late String? _phase = _normalizeProjectPhase(widget.project.phase);
  late String? _priority = normalizePriorityValue(widget.project.priority);
  late final TextEditingController _titleCtrl;
  late final TextEditingController _ownerCtrl;
  late final TextEditingController _categoryCtrl;
  late bool _customCategory;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final category = normalizeProjectCategory(widget.project.category);
    _titleCtrl = TextEditingController(text: widget.project.title);
    _ownerCtrl = TextEditingController(text: widget.project.owner ?? '');
    _categoryCtrl = TextEditingController(text: category ?? '');
    _customCategory = category != null && !widget.categories.contains(category);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _ownerCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final selectedCategory = _selectedCategoryValue();
    final phaseValue = _normalizeProjectPhase(_phase);
    final phaseItems = _phaseDropdownItems(phaseValue);

    return AlertDialog(
      backgroundColor: _dialogPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _dialogLine),
      ),
      title: const Text('Edit project metadata'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_titleCtrl, 'Project name'),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                value: _status,
                items: projectStatusOptions
                    .map(
                      (s) => DropdownMenuItem(
                        value: s.value,
                        child: Text(s.label),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _status = value ?? _status),
                decoration: const InputDecoration(labelText: 'Status'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: selectedCategory,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                    value: _categoryNone,
                    child: Text('Uncategorized'),
                  ),
                  for (final category in widget.categories)
                    DropdownMenuItem(value: category, child: Text(category)),
                  const DropdownMenuItem(
                    value: _categoryCustom,
                    child: Text('New category...'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) {
                        setState(() {
                          if (value == _categoryNone || value == null) {
                            _customCategory = false;
                            _categoryCtrl.clear();
                          } else if (value == _categoryCustom) {
                            _customCategory = true;
                          } else {
                            _customCategory = false;
                            _categoryCtrl.text = value;
                          }
                        });
                      },
                decoration: const InputDecoration(labelText: 'Category'),
              ),
              if (_customCategory || widget.categories.isEmpty) ...[
                const SizedBox(height: 10),
                _field(_categoryCtrl, 'Category name'),
              ],
              DropdownButtonFormField<String>(
                value: phaseValue ?? '',
                items: phaseItems,
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _phase = _normalizeProjectPhase(value),
                      ),
                decoration: const InputDecoration(labelText: 'Phase'),
              ),
              DropdownButtonFormField<String>(
                value: normalizePriorityValue(_priority),
                items: uniqueStringDropdownItems(_projectPriorities),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _priority = value),
                decoration: const InputDecoration(labelText: 'Priority'),
              ),
              if (widget.includeOwnerField)
                ContactOwnerField(controller: _ownerCtrl),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _save(state),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  String _selectedCategoryValue() {
    if (_customCategory) return _categoryCustom;
    final category = normalizeProjectCategory(_categoryCtrl.text);
    if (category == null) return _categoryNone;
    return widget.categories.contains(category) ? category : _categoryCustom;
  }

  Future<void> _save(AppState state) async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Project name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await state.updateProjectMeta(widget.project.id, {
        'title': title,
        'status': _status,
        'category': normalizeProjectCategory(_categoryCtrl.text),
        'phase': _normalizeProjectPhase(_phase),
        'priority': normalizePriorityValue(_priority),
        'owner': _blankToNull(_ownerCtrl.text),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: $error';
      });
    }
  }
}

List<DropdownMenuItem<String>> _phaseDropdownItems(String? currentPhase) {
  final values = <String>[
    ..._projectPhases,
    if (currentPhase != null && !_projectPhases.contains(currentPhase))
      currentPhase,
  ];
  return uniqueStringDropdownItems(
    values,
    labelFor: (value) => value.isEmpty ? '(none)' : value,
  );
}

String? _normalizeProjectPhase(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Widget _field(TextEditingController ctrl, String label) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: ctrl,
      decoration: InputDecoration(labelText: label),
    ),
  );
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
