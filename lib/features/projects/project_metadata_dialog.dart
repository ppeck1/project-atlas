import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../services/project_runtime_service.dart';
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
  late final TextEditingController _runtimeWorkingDirCtrl;
  late final TextEditingController _runtimeLaunchCtrl;
  late final TextEditingController _runtimeStopCtrl;
  late final TextEditingController _runtimeTestsCtrl;
  late final TextEditingController _runtimePortsCtrl;
  late final TextEditingController _runtimeUrlsCtrl;
  late final TextEditingController _runtimeHealthCtrl;
  late final TextEditingController _runtimeNotesCtrl;
  late final TextEditingController _capsuleSourceCtrl;
  late final TextEditingController _capsuleProfileCtrl;
  late bool _customCategory;
  bool _runtimeEnabled = false;
  bool _runtimeLoaded = false;
  bool _runtimeImporting = false;
  bool _runtimeAutostart = false;
  bool _capsuleEnabled = true;
  String _capsuleMode = 'check';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final category = normalizeProjectCategory(widget.project.category);
    _titleCtrl = TextEditingController(text: widget.project.title);
    _ownerCtrl = TextEditingController(text: widget.project.owner ?? '');
    _categoryCtrl = TextEditingController(text: category ?? '');
    _runtimeWorkingDirCtrl = TextEditingController();
    _runtimeLaunchCtrl = TextEditingController();
    _runtimeStopCtrl = TextEditingController();
    _runtimeTestsCtrl = TextEditingController();
    _runtimePortsCtrl = TextEditingController();
    _runtimeUrlsCtrl = TextEditingController();
    _runtimeHealthCtrl = TextEditingController();
    _runtimeNotesCtrl = TextEditingController();
    _capsuleSourceCtrl = TextEditingController(
      text: defaultProjectOpsCapsulePath,
    );
    _capsuleProfileCtrl = TextEditingController(text: 'software_project');
    _customCategory = category != null && !widget.categories.contains(category);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_runtimeLoaded) {
      _runtimeLoaded = true;
      _loadRuntimeProfile();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _ownerCtrl.dispose();
    _categoryCtrl.dispose();
    _runtimeWorkingDirCtrl.dispose();
    _runtimeLaunchCtrl.dispose();
    _runtimeStopCtrl.dispose();
    _runtimeTestsCtrl.dispose();
    _runtimePortsCtrl.dispose();
    _runtimeUrlsCtrl.dispose();
    _runtimeHealthCtrl.dispose();
    _runtimeNotesCtrl.dispose();
    _capsuleSourceCtrl.dispose();
    _capsuleProfileCtrl.dispose();
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
                        child: _ProjectStatusMenuItem(option: s),
                      ),
                    )
                    .toList(),
                selectedItemBuilder: (context) => projectStatusOptions
                    .map(
                      (s) => Text(
                        '${s.label} (${s.descriptor})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                    .toList(),
                isExpanded: true,
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
              const SizedBox(height: 8),
              _runtimeSection(state),
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

  Future<void> _loadRuntimeProfile() async {
    final state = AppStateScope.of(context);
    final profile = await state.getProjectRuntimeProfile(widget.project.id);
    final draft = profile == null
        ? await state.defaultProjectRuntimeProfileDraft()
        : ProjectRuntimeProfileDraft.fromProfile(profile);
    if (!mounted) return;
    _applyRuntimeDraft(draft);
  }

  Widget _runtimeSection(AppState state) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _dialogLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          initiallyExpanded: _runtimeEnabled,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: const Icon(Icons.rocket_launch_outlined, size: 18),
          title: const Text('Software runtime'),
          trailing: Switch(
            value: _runtimeEnabled,
            onChanged: _saving
                ? null
                : (value) => setState(() => _runtimeEnabled = value),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _runtimeImporting || _saving
                    ? null
                    : () => _importRuntimeFromDevLaunchpad(state),
                icon: _runtimeImporting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: const Text('Import Dev Launchpad'),
              ),
            ),
            const SizedBox(height: 10),
            _field(_runtimeWorkingDirCtrl, 'Working directory'),
            _field(_runtimeLaunchCtrl, 'Launch command'),
            _field(_runtimeStopCtrl, 'Stop command'),
            _multiField(_runtimeTestsCtrl, 'Test commands'),
            Row(
              children: [
                Expanded(child: _field(_runtimePortsCtrl, 'Ports')),
                const SizedBox(width: 10),
                Expanded(child: _field(_runtimeHealthCtrl, 'Health URLs')),
              ],
            ),
            _multiField(_runtimeUrlsCtrl, 'URLs'),
            _multiField(_runtimeNotesCtrl, 'Runtime notes'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _runtimeAutostart,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _runtimeAutostart = value),
              title: const Text('Autostart'),
            ),
            const Divider(height: 18, color: _dialogLine),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _capsuleEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _capsuleEnabled = value),
              title: const Text('Project Ops Capsule'),
            ),
            DropdownButtonFormField<String>(
              value: normalizeCapsuleMode(_capsuleMode),
              decoration: const InputDecoration(labelText: 'Capsule mode'),
              items: const [
                DropdownMenuItem(value: 'off', child: Text('off')),
                DropdownMenuItem(value: 'check', child: Text('check')),
                DropdownMenuItem(
                  value: 'strict_check',
                  child: Text('strict check'),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _capsuleMode = value ?? 'check'),
            ),
            _field(_capsuleSourceCtrl, 'Capsule source path'),
            _field(_capsuleProfileCtrl, 'Capsule profile'),
          ],
        ),
      ),
    );
  }

  Future<void> _importRuntimeFromDevLaunchpad(AppState state) async {
    setState(() {
      _runtimeImporting = true;
      _error = null;
    });
    try {
      final profile = await state.importRuntimeProfileFromDevLaunchpad(
        widget.project.id,
      );
      if (!mounted) return;
      if (profile == null) {
        setState(() => _error = 'No matching Dev Launchpad app was found.');
        return;
      }
      _applyRuntimeDraft(ProjectRuntimeProfileDraft.fromProfile(profile));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Import failed: $error');
    } finally {
      if (mounted) setState(() => _runtimeImporting = false);
    }
  }

  void _applyRuntimeDraft(ProjectRuntimeProfileDraft draft) {
    setState(() {
      _runtimeEnabled = draft.enabled;
      _runtimeWorkingDirCtrl.text = draft.workingDirectory ?? '';
      _runtimeLaunchCtrl.text = draft.launchCommand ?? '';
      _runtimeStopCtrl.text = draft.stopCommand ?? '';
      _runtimeTestsCtrl.text = draft.testCommands.join('\n');
      _runtimePortsCtrl.text = draft.ports.join(', ');
      _runtimeUrlsCtrl.text = draft.urls
          .map(
            (url) =>
                url.label == url.url ? url.url : '${url.label} | ${url.url}',
          )
          .join('\n');
      _runtimeHealthCtrl.text = draft.healthUrls.join('\n');
      _runtimeNotesCtrl.text = draft.notes ?? '';
      _runtimeAutostart = draft.autostart;
      _capsuleEnabled = draft.capsuleEnabled;
      _capsuleMode = normalizeCapsuleMode(draft.capsuleMode);
      _capsuleSourceCtrl.text =
          draft.capsuleSourcePath ?? defaultProjectOpsCapsulePath;
      _capsuleProfileCtrl.text = draft.capsuleProfile ?? 'software_project';
    });
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
      await state.saveProjectRuntimeProfileDraft(
        widget.project.id,
        ProjectRuntimeProfileDraft(
          enabled: _runtimeEnabled,
          workingDirectory: _blankToNull(_runtimeWorkingDirCtrl.text),
          launchCommand: _blankToNull(_runtimeLaunchCtrl.text),
          stopCommand: _blankToNull(_runtimeStopCtrl.text),
          testCommands: _lines(_runtimeTestsCtrl.text),
          ports: _ports(_runtimePortsCtrl.text),
          urls: _runtimeUrls(_runtimeUrlsCtrl.text),
          healthUrls: _lines(_runtimeHealthCtrl.text),
          notes: _blankToNull(_runtimeNotesCtrl.text),
          autostart: _runtimeAutostart,
          capsuleEnabled: _capsuleEnabled,
          capsuleMode: normalizeCapsuleMode(_capsuleMode),
          capsuleSourcePath:
              _blankToNull(_capsuleSourceCtrl.text) ??
              defaultProjectOpsCapsulePath,
          capsuleProfile: _blankToNull(_capsuleProfileCtrl.text),
        ),
      );
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

class _ProjectStatusMenuItem extends StatelessWidget {
  final ProjectStatusOption option;

  const _ProjectStatusMenuItem({required this.option});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: option.description,
      child: Row(
        children: [
          Expanded(child: Text(option.label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(
            option.descriptor,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
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

Widget _multiField(TextEditingController ctrl, String label) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: ctrl,
      minLines: 2,
      maxLines: 5,
      decoration: InputDecoration(labelText: label),
    ),
  );
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _lines(String value) => value
    .split(RegExp(r'[\r\n]+'))
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList(growable: false);

List<int> _ports(String value) => value
    .split(RegExp(r'[\s,;]+'))
    .map((item) => int.tryParse(item.trim()))
    .whereType<int>()
    .toList(growable: false);

List<RuntimeUrl> _runtimeUrls(String value) {
  return _lines(value)
      .map((line) {
        final parts = line.split('|');
        if (parts.length >= 2) {
          final label = parts.first.trim();
          final url = parts.sublist(1).join('|').trim();
          return RuntimeUrl(label: label.isEmpty ? url : label, url: url);
        }
        return RuntimeUrl(label: line, url: line);
      })
      .where((item) => item.url.trim().isNotEmpty)
      .toList(growable: false);
}
