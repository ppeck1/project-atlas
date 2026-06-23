import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/contact_picker.dart';
import '../../shared/widgets/create_work_item_dialog.dart';
import '../today/work_item_detail_sheet.dart';
import '../work/status_priority_helpers.dart';

// ─── Design tokens ─────────────────────────────────────────────────────────
const _kPrimary = Color(0xFF79A7FF);
const _kPanel = Color(0xFF151A22);
const _kLine = Color(0xFF273044);

const _kStatusColors = <String, Color>{
  'active': Color(0xFF4CAF50),
  'paused': Color(0xFFFF9800),
  'blocked': Color(0xFFF44336),
  'completed': Color(0xFF2196F3),
  'archived': Color(0xFF607D8B),
};
const _kPhaseColors = <String, Color>{
  'idea': Color(0xFF9C27B0),
  'design': Color(0xFF2196F3),
  'build': Color(0xFFFFC107),
  'test': Color(0xFFFF9800),
  'ship': Color(0xFF4CAF50),
  'stabilize': Color(0xFF607D8B),
};
const _kPriorityColors = <String, Color>{
  'high': Color(0xFFFF9800),
  'urgent': Color(0xFFF44336),
  'low': Color(0xFF607D8B),
};

Color _sc(String? s) => _kStatusColors[s] ?? const Color(0x61FFFFFF);
Color _pc(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);
Color _prc(String? p) => _kPriorityColors[p] ?? const Color(0x61FFFFFF);
Color _tagColor(Tag tag) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return _kPrimary;
}

const _kStatuses = ['active', 'paused', 'blocked', 'completed', 'archived'];
const _kPhases = ['', 'idea', 'design', 'build', 'test', 'ship', 'stabilize'];
const _kPriorities = ['low', 'normal', 'high', 'urgent'];

// ─── Main widget ──────────────────────────────────────────────────────────
class ProjectDetailScreen extends StatefulWidget {
  final String projectId;
  const ProjectDetailScreen({super.key, required this.projectId});

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  String? _expandedSection = 'identity';
  bool _aiExpanded = false;
  bool _includeLibrary = false;
  bool _summaryLoading = false;
  String? _summaryText;

  List<WorkItem> _workItems = const [];
  List<ProjectPerson> _people = const [];
  List<ProjectRisk> _risks = const [];
  List<ProjectDecision> _decisions = const [];
  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoad) {
      _didLoad = true;
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    final state = AppStateScope.of(context);
    try {
      final results = await Future.wait([
        state.getWorkItemsForProject(widget.projectId),
        state.getProjectPeople(widget.projectId),
        state.getProjectRisks(widget.projectId),
        state.getProjectDecisions(widget.projectId),
      ]);
      if (!mounted) return;
      setState(() {
        _workItems = results[0] as List<WorkItem>;
        _people = results[1] as List<ProjectPerson>;
        _risks = results[2] as List<ProjectRisk>;
        _decisions = results[3] as List<ProjectDecision>;
      });
    } catch (_) {}
  }

  void _toggleSection(String key) =>
      setState(() => _expandedSection = _expandedSection == key ? null : key);

  Future<void> _generateSummary() async {
    final state = AppStateScope.of(context);
    setState(() {
      _summaryLoading = true;
      _summaryText = null;
    });
    try {
      final r = await state.summarizeProjectFull(
        widget.projectId,
        includeLibrary: _includeLibrary,
      );
      if (!mounted) return;
      setState(() => _summaryText = r.output ?? 'No output from model.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _summaryText = 'Error: $e');
    } finally {
      if (mounted) setState(() => _summaryLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<Project?>(
      stream: state.watchProject(widget.projectId),
      builder: (context, snap) {
        if (snap.data == null &&
            snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final project = snap.data;
        if (project == null) {
          return Scaffold(
            appBar: AppBar(
              leading: _BackBtn(onTap: () => context.go('/projects')),
              leadingWidth: 110,
              title: const Text('Project not found'),
            ),
            body: Center(
              child: TextButton.icon(
                onPressed: () => context.go('/projects'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to projects'),
              ),
            ),
          );
        }

        // Compute metrics from loaded work items
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final active = _workItems
            .where((i) => !['done', 'archived'].contains(i.status))
            .toList();
        final blockedCount = active
            .where((i) => i.blockedReason != null)
            .length;
        final overdueCount = active
            .where((i) => i.dueAt != null && i.dueAt!.isBefore(today))
            .length;
        final urgentCount = active.where((i) => i.priority == 'urgent').length;

        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: _BackBtn(onTap: () => context.go('/projects')),
            leadingWidth: 110,
            title: Text(
              project.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: 'Open work board',
                icon: const Icon(Icons.view_kanban_outlined, size: 20),
                onPressed: () async {
                  await state.setActiveById(project.id);
                  if (context.mounted) context.go('/work');
                },
              ),
              IconButton(
                tooltip: 'Delete project',
                icon: const Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Color(0x99F44336),
                ),
                onPressed: () => _showDeleteDialog(context, project),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // AI assistant panel
              _AiPanel(
                expanded: _aiExpanded,
                includeLibrary: _includeLibrary,
                summaryLoading: _summaryLoading,
                summaryText: _summaryText,
                onToggle: () => setState(() => _aiExpanded = !_aiExpanded),
                onToggleLibrary: (v) => setState(() => _includeLibrary = v),
                onGenerate: _generateSummary,
              ),
              const SizedBox(height: 8),

              // Status quick bar + metric cards
              _QuickBar(
                project: project,
                activeCount: active.length,
                blockedCount: blockedCount,
                overdueCount: overdueCount,
                urgentCount: urgentCount,
                onEditMeta: () => _showMetaDialog(context, project),
              ),
              const SizedBox(height: 8),

              // Expandable sections
              _Section(
                id: 'tags',
                title: 'Tags',
                subtitle: 'Separate home, work, personal, and other contexts',
                expanded: _expandedSection == 'tags',
                onTap: () => _toggleSection('tags'),
                child: _TagsSection(
                  projectId: widget.projectId,
                  onEdit: () => _showTagsDialog(context),
                ),
              ),
              _Section(
                id: 'identity',
                title: 'Project Identity',
                subtitle: 'Purpose, outcome, success criteria, scope',
                expanded: _expandedSection == 'identity',
                onTap: () => _toggleSection('identity'),
                child: _IdentitySection(
                  project: project,
                  onEdit: () => _showIdentityDialog(context, project),
                ),
              ),
              _Section(
                id: 'people',
                title: 'People & Roles',
                subtitle: 'Who is involved and what do they own?',
                expanded: _expandedSection == 'people',
                onTap: () => _toggleSection('people'),
                child: _PeopleSection(
                  people: _people,
                  onAdd: () => _showAddPersonDialog(context),
                  onEdit: (p) => _showEditPersonDialog(context, p),
                  onDelete: (p) async {
                    await state.deleteProjectPerson(p.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'work',
                title: 'Project Workboard',
                subtitle: 'Project-scoped tasks, grouped by status',
                expanded: _expandedSection == 'work',
                onTap: () => _toggleSection('work'),
                child: _ProjectWorkSection(
                  projectId: widget.projectId,
                  items: _workItems,
                  onChanged: _loadAll,
                ),
              ),
              _Section(
                id: 'risks',
                title: 'Risks & Issues',
                subtitle: 'What might break, what is already broken?',
                expanded: _expandedSection == 'risks',
                onTap: () => _toggleSection('risks'),
                child: _RisksSection(
                  risks: _risks,
                  onAdd: () => _showAddRiskDialog(context),
                  onDelete: (r) async {
                    await state.deleteProjectRisk(r.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'decisions',
                title: 'Decision Log',
                subtitle: 'What was decided, why, and by whom?',
                expanded: _expandedSection == 'decisions',
                onTap: () => _toggleSection('decisions'),
                child: _DecisionsSection(
                  decisions: _decisions,
                  onAdd: () => _showAddDecisionDialog(context),
                  onDelete: (d) async {
                    await state.deleteProjectDecision(d.id);
                    await _loadAll();
                  },
                ),
              ),
              _Section(
                id: 'media',
                title: 'Media & Documents',
                subtitle: 'Images, reference files, and project evidence',
                expanded: _expandedSection == 'media',
                onTap: () => _toggleSection('media'),
                child: _MediaSection(
                  projectId: widget.projectId,
                  onImportMedia: () => _showImportMediaDialog(context),
                ),
              ),
              _Section(
                id: 'closure',
                title: 'Closure',
                subtitle: project.status == 'completed'
                    ? 'Completed'
                    : 'Open project',
                expanded: _expandedSection == 'closure',
                onTap: () => _toggleSection('closure'),
                child: _ClosureSection(
                  project: project,
                  onEdit: () => _showClosureDialog(context, project),
                  onComplete: () => state.updateProjectMeta(widget.projectId, {
                    'status': 'completed',
                  }),
                  onArchive: () => state.updateProjectMeta(widget.projectId, {
                    'status': 'archived',
                  }),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  Future<void> _showMetaDialog(BuildContext context, Project project) async {
    final state = AppStateScope.of(context);
    String status = _normalizeProjectStatus(project.status);
    String? phase = project.phase;
    String? priority = normalizePriorityValue(project.priority);
    final titleCtrl = TextEditingController(text: project.title);
    final ownerCtrl = TextEditingController(text: project.owner ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Edit project metadata'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _mf(titleCtrl, 'Project name'),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    value: _normalizeProjectStatus(status),
                    items: _kStatuses
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setLocal(() => status = v ?? status),
                    decoration: const InputDecoration(labelText: 'Status'),
                  ),
                  DropdownButtonFormField<String>(
                    value: phase ?? '',
                    items: _kPhases
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(s.isEmpty ? '(none)' : s),
                          ),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setLocal(() => phase = (v?.isEmpty ?? true) ? null : v),
                    decoration: const InputDecoration(labelText: 'Phase'),
                  ),
                  DropdownButtonFormField<String>(
                    value: normalizePriorityValue(priority),
                    items: uniqueStringDropdownItems(_kPriorities),
                    onChanged: (v) => setLocal(() => priority = v),
                    decoration: const InputDecoration(labelText: 'Priority'),
                  ),
                  ContactOwnerField(controller: ownerCtrl),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await state.updateProjectMeta(widget.projectId, {
                  'title': _nt(titleCtrl.text) ?? project.title,
                  'status': status,
                  'phase': phase,
                  'priority': normalizePriorityValue(priority),
                  'owner': _nt(ownerCtrl.text),
                });
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    titleCtrl.dispose();
    ownerCtrl.dispose();
  }

  Future<void> _showIdentityDialog(
    BuildContext context,
    Project project,
  ) async {
    final state = AppStateScope.of(context);
    final desc = TextEditingController(text: project.description ?? '');
    final outcome = TextEditingController(text: project.desiredOutcome ?? '');
    final criteria = TextEditingController(text: project.successCriteria ?? '');
    final included = TextEditingController(text: project.scopeIncluded ?? '');
    final excluded = TextEditingController(text: project.scopeExcluded ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit project identity'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mf(desc, 'Purpose / problem statement', multiline: true),
                _mf(outcome, 'Desired outcome', multiline: true),
                _mf(criteria, 'Success criteria', multiline: true),
                _mf(included, 'Scope included', multiline: true),
                _mf(excluded, 'Scope excluded', multiline: true),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await state.updateProjectMeta(widget.projectId, {
                'description': _nt(desc.text),
                'desiredOutcome': _nt(outcome.text),
                'successCriteria': _nt(criteria.text),
                'scopeIncluded': _nt(included.text),
                'scopeExcluded': _nt(excluded.text),
              });
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final c in [desc, outcome, criteria, included, excluded]) c.dispose();
  }

  Future<void> _showTagsDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final allTags = await state.getTags();
    final selectedTags = await state.getTagsForProject(widget.projectId);
    final selectedIds = selectedTags.map((tag) => tag.id).toSet();
    final newTagCtrl = TextEditingController();

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Edit project tags'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (allTags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'No tags yet. Add home, work, personal, or anything useful.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in allTags)
                          FilterChip(
                            label: Text(tag.name),
                            selected: selectedIds.contains(tag.id),
                            onSelected: (selected) => setLocal(() {
                              if (selected) {
                                selectedIds.add(tag.id);
                              } else {
                                selectedIds.remove(tag.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _mf(newTagCtrl, 'New tag name')),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FilledButton.icon(
                          onPressed: () async {
                            final name = _nt(newTagCtrl.text);
                            if (name == null) return;
                            final id = await state.saveTag(name: name);
                            selectedIds.add(id);
                            newTagCtrl.clear();
                            if (ctx.mounted) {
                              Navigator.of(ctx).pop();
                              await _showTagsDialog(context);
                            }
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await state.setProjectTags(widget.projectId, selectedIds);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    newTagCtrl.dispose();
  }

  Future<void> _showImportMediaDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final pathCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final captionCtrl = TextEditingController();
    var makeCover = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Add project media'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _mf(pathCtrl, r'Local image or file path'),
                  _mf(titleCtrl, 'Title (optional)'),
                  _mf(captionCtrl, 'Caption / note', multiline: true),
                  CheckboxListTile(
                    value: makeCover,
                    onChanged: (v) => setLocal(() => makeCover = v ?? false),
                    title: const Text('Use as cover image'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final path = _nt(pathCtrl.text);
                if (path == null) return;
                final mediaId = await state.importProjectMediaFromPath(
                  widget.projectId,
                  path,
                  title: _nt(titleCtrl.text),
                  caption: _nt(captionCtrl.text),
                  isCover: makeCover,
                );
                if (makeCover) {
                  await state.setProjectCoverMedia(widget.projectId, mediaId);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Import'),
            ),
          ],
        ),
      ),
    );
    pathCtrl.dispose();
    titleCtrl.dispose();
    captionCtrl.dispose();
  }

  Future<void> _showAddPersonDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final name = TextEditingController();
    final role = TextEditingController();
    final auth = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Add person'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ContactOwnerField(
                  controller: name,
                  label: 'Name / contact',
                ),
              ),
              _mf(role, 'Role / responsibility'),
              _mf(auth, 'Decision authority'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name is required to update a person.'),
                    ),
                  );
                }
                return;
              }
              await state.saveContact(
                name: name.text.trim(),
                title: _nt(role.text),
                notes: _nt(auth.text),
              );
              await state.addProjectPerson(
                widget.projectId,
                name.text.trim(),
                _nt(role.text),
                _nt(auth.text),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              await _loadAll();
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    for (final c in [name, role, auth]) c.dispose();
  }

  Future<void> _showEditPersonDialog(
    BuildContext context,
    ProjectPerson person,
  ) async {
    final state = AppStateScope.of(context);
    final name = TextEditingController(text: person.name);
    final role = TextEditingController(text: person.role ?? '');
    final auth = TextEditingController(text: person.authority ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit person'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ContactOwnerField(
                  controller: name,
                  label: 'Name / contact',
                ),
              ),
              _mf(role, 'Role / responsibility'),
              _mf(auth, 'Decision authority'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name is required to update a person.'),
                    ),
                  );
                }
                return;
              }
              await state.saveContact(
                name: name.text.trim(),
                title: _nt(role.text),
                notes: _nt(auth.text),
              );
              await state.updateProjectPerson(
                person.id,
                name.text.trim(),
                _nt(role.text),
                _nt(auth.text),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              await _loadAll();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final c in [name, role, auth]) c.dispose();
  }

  Future<void> _showAddRiskDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final title = TextEditingController();
    final desc = TextEditingController();
    String severity = 'medium';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: _kPanel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: _kLine),
          ),
          title: const Text('Add risk'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mf(title, 'Risk title'),
                _mf(desc, 'Description / mitigation', multiline: true),
                DropdownButtonFormField<String>(
                  value: severity,
                  items: const ['low', 'medium', 'high', 'critical']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) => setLocal(() => severity = v ?? 'medium'),
                  decoration: const InputDecoration(labelText: 'Severity'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (title.text.trim().isEmpty) return;
                await state.addProjectRisk(
                  widget.projectId,
                  title.text.trim(),
                  _nt(desc.text),
                  severity,
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
                await _loadAll();
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    desc.dispose();
  }

  Future<void> _showAddDecisionDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final title = TextEditingController();
    final ctx2 = TextEditingController();
    final decider = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Log decision'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _mf(title, 'What was decided?'),
              _mf(ctx2, 'Context & rationale', multiline: true),
              _mf(decider, 'Decided by'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (title.text.trim().isEmpty) return;
              await state.addProjectDecision(
                widget.projectId,
                title.text.trim(),
                _nt(ctx2.text),
                _nt(decider.text),
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              await _loadAll();
            },
            child: const Text('Log'),
          ),
        ],
      ),
    );
    for (final c in [title, ctx2, decider]) c.dispose();
  }

  Future<void> _showClosureDialog(BuildContext context, Project project) async {
    final state = AppStateScope.of(context);
    final outcome = TextEditingController(text: project.outcomeSummary ?? '');
    final lessons = TextEditingController(text: project.lessonsLearned ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _kLine),
        ),
        title: const Text('Edit closure'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _mf(outcome, 'Outcome summary', multiline: true),
              _mf(lessons, 'Lessons learned', multiline: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await state.updateProjectMeta(widget.projectId, {
                'outcomeSummary': _nt(outcome.text),
                'lessonsLearned': _nt(lessons.text),
              });
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    outcome.dispose();
    lessons.dispose();
  }

  Future<void> _showDeleteDialog(BuildContext context, Project project) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final state = AppStateScope.of(context);
        return _DeleteDialog(
          projectTitle: project.title,
          onConfirm: (reason) async {
            await state.softDeleteProject(project.id, reason);
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (context.mounted) context.go('/projects');
          },
          onClose: () => Navigator.of(ctx).pop(),
        );
      },
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
String? _nt(String s) {
  final t = s.trim();
  return t.isEmpty ? null : t;
}

String _normalizeProjectStatus(String? value) {
  final raw = (value ?? '').trim().toLowerCase();
  return _kStatuses.contains(raw) ? raw : 'active';
}

Widget _mf(TextEditingController ctrl, String label, {bool multiline = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: ctrl,
      minLines: multiline ? 2 : 1,
      maxLines: multiline ? 5 : 1,
      decoration: InputDecoration(labelText: label),
    ),
  );
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _BackBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _BackBtn({required this.onTap});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.arrow_back, size: 16, color: _kPrimary),
    label: const Text(
      'Projects',
      style: TextStyle(color: _kPrimary, fontSize: 13),
    ),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
  );
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(34),
      border: Border.all(color: color.withAlpha(68)),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class _MetricCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _MetricCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1115),
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: value > 0 ? color : Colors.white24,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    ),
  );
}

class _AiPanel extends StatelessWidget {
  final bool expanded;
  final bool includeLibrary;
  final bool summaryLoading;
  final String? summaryText;
  final VoidCallback onToggle;
  final ValueChanged<bool> onToggleLibrary;
  final VoidCallback onGenerate;

  const _AiPanel({
    required this.expanded,
    required this.includeLibrary,
    required this.summaryLoading,
    required this.summaryText,
    required this.onToggle,
    required this.onToggleLibrary,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF79A7FF).withAlpha(15),
        border: Border.all(color: const Color(0xFF79A7FF).withAlpha(51)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology, size: 18, color: _kPrimary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'AI Project Assistant',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _kPrimary,
                    fontSize: 14,
                  ),
                ),
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => onToggleLibrary(!includeLibrary),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: includeLibrary,
                            onChanged: (v) => onToggleLibrary(v ?? false),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Include Library',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onToggle,
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white38,
                    ),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 12),
            if (!summaryLoading && summaryText == null)
              FilledButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.psychology, size: 16),
                label: const Text('Generate Summary'),
              )
            else if (summaryLoading)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Generating…',
                    style: TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ],
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  summaryText!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    height: 1.6,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _QuickBar extends StatelessWidget {
  final Project project;
  final int activeCount, blockedCount, overdueCount, urgentCount;
  final VoidCallback onEditMeta;

  const _QuickBar({
    required this.project,
    required this.activeCount,
    required this.blockedCount,
    required this.overdueCount,
    required this.urgentCount,
    required this.onEditMeta,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kPanel,
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Pill(label: project.status, color: _sc(project.status)),
              if ((project.phase ?? '').isNotEmpty) ...[
                const SizedBox(width: 6),
                _Pill(label: project.phase!, color: _pc(project.phase)),
              ],
              if ((project.priority ?? '').isNotEmpty &&
                  project.priority != 'normal') ...[
                const SizedBox(width: 6),
                _Pill(label: project.priority!, color: _prc(project.priority)),
              ],
              if ((project.owner ?? '').isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  'Owner: ${project.owner}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: onEditMeta,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF79A7FF).withAlpha(26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0x3379A7FF)),
                  ),
                ),
                child: const Text(
                  'Edit metadata',
                  style: TextStyle(fontSize: 11, color: _kPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MetricCard(
                label: 'Active',
                value: activeCount,
                color: const Color(0xFF448AFF),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Blocked',
                value: blockedCount,
                color: const Color(0xFF9C27B0),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Overdue',
                value: overdueCount,
                color: const Color(0xFFF44336),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Urgent',
                value: urgentCount,
                color: const Color(0xFFFF6D00),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String id, title, subtitle;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;

  const _Section({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: _kPanel,
          border: Border.all(color: _kLine),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: Colors.white38,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1, color: _kLine),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: child,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback onEdit;

  const _FieldRow({
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value?.trim().isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onEdit,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      hasValue ? value! : placeholder,
                      style: TextStyle(
                        fontSize: 13,
                        color: hasValue
                            ? const Color(0xDEFFFFFF)
                            : Colors.white24,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.edit_outlined,
                    size: 13,
                    color: Colors.white24,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentitySection extends StatelessWidget {
  final Project project;
  final VoidCallback onEdit;
  const _IdentitySection({required this.project, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _FieldRow(
          label: 'Purpose',
          value: project.description,
          placeholder: 'Not recorded — click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Desired outcome',
          value: project.desiredOutcome,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Success criteria',
          value: project.successCriteria,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Scope included',
          value: project.scopeIncluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Scope excluded',
          value: project.scopeExcluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
      ],
    );
  }
}

class _PeopleSection extends StatelessWidget {
  final List<ProjectPerson> people;
  final VoidCallback onAdd;
  final ValueChanged<ProjectPerson> onEdit;
  final ValueChanged<ProjectPerson> onDelete;

  const _PeopleSection({
    required this.people,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No people records yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...people.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 16,
                  color: Colors.white38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        [
                          if ((p.role ?? '').isNotEmpty) p.role!,
                          if ((p.authority ?? '').isNotEmpty) p.authority!,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: Colors.white24,
                  ),
                  onPressed: () => onEdit(p),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(p),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.person_add_outlined, size: 16),
          label: const Text('Add person'),
        ),
      ],
    );
  }
}

class _RisksSection extends StatelessWidget {
  final List<ProjectRisk> risks;
  final VoidCallback onAdd;
  final ValueChanged<ProjectRisk> onDelete;

  const _RisksSection({
    required this.risks,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (risks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No risks recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...risks.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((r.desc ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            r.desc!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      Text(
                        'Severity: ${r.severity}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(r),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add risk'),
        ),
      ],
    );
  }
}

class _DecisionsSection extends StatelessWidget {
  final List<ProjectDecision> decisions;
  final VoidCallback onAdd;
  final ValueChanged<ProjectDecision> onDelete;

  const _DecisionsSection({
    required this.decisions,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (decisions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No decisions recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...decisions.map(
          (d) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((d.ctx ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            d.ctx!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      if ((d.decider ?? '').isNotEmpty)
                        Text(
                          'By: ${d.decider}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(d),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Log decision'),
        ),
      ],
    );
  }
}

class _ProjectWorkSection extends StatelessWidget {
  final String projectId;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;

  const _ProjectWorkSection({
    required this.projectId,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final grouped = <String, List<WorkItem>>{
      for (final status in ['inbox', 'next', 'doing', 'waiting', 'done'])
        status: [],
    };
    for (final item in items) {
      final key = normalizeStatusValue(item.status);
      grouped.putIfAbsent(key, () => <WorkItem>[]).add(item);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tasks here are scoped to this project. Click any task to open the full detail sheet.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
            FilledButton.icon(
              onPressed: () async {
                final stages = await state.db.getStagesForProject(projectId);
                if (stages.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'This project has no stage to attach a task to.',
                        ),
                      ),
                    );
                  }
                  return;
                }
                if (!context.mounted) return;
                final draft = await showCreateWorkItemDialog(context);
                if (draft == null) return;
                DateTime? dueAt;
                final rawDate = draft['dueAt'];
                if (rawDate != null && rawDate.isNotEmpty) {
                  dueAt = DateTime.tryParse(rawDate);
                }
                await state.addWorkItem(
                  stages.first.id,
                  draft['title']!,
                  description: draft['description'],
                  owner: draft['owner'],
                  status: normalizeStatusValue(draft['status']),
                  priority: normalizePriorityValue(draft['priority']),
                  dueAt: dueAt,
                );
                await onChanged();
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add project task'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Text(
            'No tasks in this project yet.',
            style: TextStyle(color: Colors.white24),
          )
        else
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 12,
            runSpacing: 12,
            children: grouped.entries
                .where((entry) => entry.value.isNotEmpty)
                .map(
                  (entry) => _ProjectStatusColumn(
                    status: entry.key,
                    items: entry.value,
                    onChanged: onChanged,
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _ProjectStatusColumn extends StatelessWidget {
  final String status;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;

  const _ProjectStatusColumn({
    required this.status,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final opt = statusFor(status);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(opt.icon, size: 14, color: opt.color),
                const SizedBox(width: 6),
                Text(
                  opt.label,
                  style: TextStyle(
                    color: opt.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length}',
                  style: const TextStyle(color: Colors.white38),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      normalizePriorityValue(item.priority),
                      if ((item.owner ?? '').isNotEmpty) item.owner!,
                      if (item.dueAt != null)
                        '${item.dueAt!.month}/${item.dueAt!.day}',
                    ].join(' - '),
                  ),
                  onTap: () async {
                    await showWorkItemDetailSheet(context, item.id);
                    await onChanged();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TagsSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onEdit;

  const _TagsSection({required this.projectId, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Tag>>(
      stream: state.watchTagsForProject(projectId),
      builder: (context, snap) {
        final tags = snap.data ?? const <Tag>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'No tags assigned yet.',
                  style: TextStyle(fontSize: 13, color: Colors.white38),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in tags)
                      _Pill(label: '#${tag.name}', color: _tagColor(tag)),
                  ],
                ),
              ),
            OutlinedButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.sell_outlined, size: 16),
              label: const Text('Edit tags'),
            ),
          ],
        );
      },
    );
  }
}

class _MediaSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onImportMedia;

  const _MediaSection({required this.projectId, required this.onImportMedia});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<ProjectMediaItem>>(
      stream: state.watchProjectMedia(projectId),
      builder: (context, mediaSnap) {
        final media = mediaSnap.data ?? const <ProjectMediaItem>[];
        final cover = media.where((item) => item.isCover).firstOrNull;
        return StreamBuilder<List<Document>>(
          stream: state.watchDocumentsForProject(projectId),
          builder: (context, docSnap) {
            final docs = docSnap.data ?? const <Document>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cover != null && cover.mediaType == 'image') ...[
                  _CoverImage(item: cover),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onImportMedia,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 16,
                      ),
                      label: const Text('Add image/file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => context.go('/library'),
                      icon: const Icon(Icons.library_books_outlined, size: 16),
                      label: const Text('Open Library'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (media.isEmpty && docs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'No media or documents linked to this project yet.',
                      style: TextStyle(fontSize: 13, color: Colors.white38),
                    ),
                  ),
                if (media.isNotEmpty) ...[
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          mainAxisExtent: 190,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: media.length,
                    itemBuilder: (context, i) => _MediaTile(
                      item: media[i],
                      onSetCover: () =>
                          state.setProjectCoverMedia(projectId, media[i].id),
                      onDelete: () => state.deleteProjectMedia(media[i].id),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (docs.isNotEmpty)
                  ...docs.map(
                    (d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.description_outlined,
                            size: 16,
                            color: _kPrimary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.title,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  d.originalFilename,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white38,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: Colors.white24,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _CoverImage extends StatelessWidget {
  final ProjectMediaItem item;

  const _CoverImage({required this.item});

  @override
  Widget build(BuildContext context) {
    final file = File(item.storedPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 16 / 7,
        child: file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : Container(
                color: const Color(0xFF0F1115),
                alignment: Alignment.center,
                child: const Text(
                  'Cover file is missing',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  final ProjectMediaItem item;
  final VoidCallback onSetCover;
  final VoidCallback onDelete;

  const _MediaTile({
    required this.item,
    required this.onSetCover,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(item.storedPath);
    final isImage = item.mediaType == 'image';
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1115),
        border: Border.all(color: item.isCover ? _kPrimary : _kLine),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: const Color(0xFF10151E),
              child: isImage && file.existsSync()
                  ? Image.file(file, fit: BoxFit.cover)
                  : Icon(
                      isImage
                          ? Icons.broken_image_outlined
                          : Icons.insert_drive_file_outlined,
                      color: Colors.white38,
                      size: 32,
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if ((item.caption ?? '').isNotEmpty)
                  Text(
                    item.caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                Row(
                  children: [
                    if (!item.isCover)
                      IconButton(
                        tooltip: 'Use as cover',
                        onPressed: isImage ? onSetCover : null,
                        icon: const Icon(Icons.wallpaper, size: 16),
                      ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Remove media',
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 16),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClosureSection extends StatelessWidget {
  final Project project;
  final VoidCallback onEdit, onComplete, onArchive;

  const _ClosureSection({
    required this.project,
    required this.onEdit,
    required this.onComplete,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldRow(
          label: 'Outcome summary',
          value: project.outcomeSummary,
          placeholder: 'Not closed yet',
          onEdit: onEdit,
        ),
        const Divider(height: 1, color: Color(0x44273044)),
        _FieldRow(
          label: 'Lessons learned',
          value: project.lessonsLearned,
          placeholder: 'Not recorded',
          onEdit: onEdit,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onComplete,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Complete project'),
            ),
            OutlinedButton.icon(
              onPressed: onArchive,
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Archive'),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Delete dialog ────────────────────────────────────────────────────────────

class _DeleteDialog extends StatefulWidget {
  final String projectTitle;
  final ValueChanged<String> onConfirm;
  final VoidCallback onClose;

  const _DeleteDialog({
    required this.projectTitle,
    required this.onConfirm,
    required this.onClose,
  });

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _ctrl = TextEditingController();
  bool _attempted = false;
  int _charCount = 0;

  bool get _valid => _charCount >= 20;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(
      () => setState(() => _charCount = _ctrl.text.trim().length),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _kLine),
      ),
      title: const Text(
        'Delete project permanently?',
        style: TextStyle(color: Color(0xFFF44336), fontSize: 16),
      ),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently remove "${widget.projectTitle}" from Project Atlas. '
              'Your deletion reason will be saved locally. Project documents are detached, not deleted.',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white70,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText:
                    'Deletion reason (min 20 characters — $_charCount/20)',
                hintText: 'Describe why this project is being deleted…',
              ),
            ),
            if (_attempted && !_valid) ...[
              const SizedBox(height: 6),
              const Text(
                'Please enter at least 20 characters before deleting.',
                style: TextStyle(fontSize: 12, color: Color(0xFFF44336)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onClose, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            setState(() => _attempted = true);
            if (_valid) widget.onConfirm(_ctrl.text.trim());
          },
          style: FilledButton.styleFrom(
            backgroundColor: _valid
                ? const Color(0xFFF44336)
                : const Color(0x4DF44336),
            foregroundColor: _valid ? Colors.white : const Color(0x80FFFFFF),
          ),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
