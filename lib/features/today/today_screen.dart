import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/contact_picker.dart';
import 'work_item_detail_sheet.dart';
import '../work/status_priority_helpers.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  String? _projectFilterId;
  String? _tagFilterId;
  String? _statusFilter;
  int _taskListRevision = 0;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          FilledButton.icon(
            onPressed: () => _showAddTaskDialog(context),
            icon: const Icon(Icons.add_task, size: 18),
            label: const Text('Task'),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              _formattedDate(),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<WorkItem>>(
        stream: state.watchAllActiveWorkItems(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _TodayLoadError(error: snap.error);
          }

          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 48,
                      color: Colors.green,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Nothing urgent today.',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Items appear here when they are in progress,\noverdue, due today, on your phone queue,\nor marked high priority.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            );
          }

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final tomorrow = today.add(const Duration(days: 1));

          final doing = items.where((i) => i.status == 'doing').toList();
          final overdue = items
              .where(
                (i) =>
                    i.dueAt != null &&
                    i.dueAt!.isBefore(today) &&
                    i.status != 'doing',
              )
              .toList();
          final dueToday = items
              .where(
                (i) =>
                    i.dueAt != null &&
                    !i.dueAt!.isBefore(today) &&
                    i.dueAt!.isBefore(tomorrow) &&
                    i.status != 'doing',
              )
              .toList();
          final phoneQueue = items
              .where(
                (i) =>
                    i.phoneQueue &&
                    i.status != 'doing' &&
                    !overdue.contains(i) &&
                    !dueToday.contains(i),
              )
              .toList();
          final highPrio = items
              .where(
                (i) =>
                    ['high', 'urgent'].contains(i.priority) &&
                    i.status != 'doing' &&
                    !overdue.contains(i) &&
                    !dueToday.contains(i) &&
                    !phoneQueue.contains(i),
              )
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SummaryRow(items: items),
              const SizedBox(height: 16),
              _TodayTaskList(
                items: items,
                projectFilterId: _projectFilterId,
                tagFilterId: _tagFilterId,
                statusFilter: _statusFilter,
                refreshRevision: _taskListRevision,
                onProjectFilterChanged: (value) =>
                    setState(() => _projectFilterId = value),
                onTagFilterChanged: (value) =>
                    setState(() => _tagFilterId = value),
                onStatusFilterChanged: (value) =>
                    setState(() => _statusFilter = value),
                onTaskTagsChanged: () => setState(() => _taskListRevision++),
              ),
              const SizedBox(height: 16),
              if (doing.isNotEmpty) ...[
                _SectionHeader(
                  label: 'Doing Now',
                  icon: Icons.sync,
                  count: doing.length,
                  color: Colors.amber,
                ),
                ...doing.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (overdue.isNotEmpty) ...[
                _SectionHeader(
                  label: 'Overdue',
                  icon: Icons.warning_amber_rounded,
                  count: overdue.length,
                  color: Colors.red,
                ),
                ...overdue.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (dueToday.isNotEmpty) ...[
                _SectionHeader(
                  label: 'Due Today',
                  icon: Icons.today,
                  count: dueToday.length,
                  color: Colors.orange,
                ),
                ...dueToday.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (phoneQueue.isNotEmpty) ...[
                _SectionHeader(
                  label: 'Phone / Follow-up',
                  icon: Icons.phone,
                  count: phoneQueue.length,
                  color: Colors.blue,
                ),
                ...phoneQueue.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (highPrio.isNotEmpty) ...[
                _SectionHeader(
                  label: 'High Priority',
                  icon: Icons.bolt,
                  count: highPrio.length,
                  color: Colors.deepOrange,
                ),
                ...highPrio.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAddTaskDialog(BuildContext context) async {
    final state = AppStateScope.of(context);
    final projects = await state.getProjectsFull();
    final tags = await state.getTags();
    if (!context.mounted) return;
    final draft = await showDialog<_TodayTaskDraft>(
      context: context,
      builder: (_) => _TodayTaskDialog(projects: projects, tags: tags),
    );
    if (draft == null) return;
    final newTagIds = <String>[];
    for (final tagName in draft.newTagNames) {
      final tagId = await state.saveTag(name: tagName);
      newTagIds.add(tagId);
    }
    final tagIds = {...draft.tagIds, ...newTagIds};
    if (draft.projectId == null) {
      await state.addGeneralWorkItem(
        draft.title,
        description: draft.description,
        owner: draft.owner,
        status: draft.status,
        priority: draft.priority,
        dueAt: draft.dueAt,
        source: 'today_quick_add',
        tagIds: tagIds,
      );
    } else {
      await state.addWorkItemToProject(
        draft.projectId!,
        draft.title,
        description: draft.description,
        owner: draft.owner,
        status: draft.status,
        priority: draft.priority,
        dueAt: draft.dueAt,
        source: 'today_quick_add',
        tagIds: tagIds,
      );
    }
    if (!mounted) return;
    setState(() => _taskListRevision++);
  }

  String _formattedDate() {
    final now = DateTime.now();
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = days[now.weekday - 1];
    return '$dow ${months[now.month]} ${now.day}';
  }
}

class _TodayTaskContext {
  final List<ProjectFull> projects;
  final List<Tag> tags;
  final Map<String, List<Tag>> tagsByItem;
  final Map<String, ProjectFull?> projectByItem;

  const _TodayTaskContext({
    required this.projects,
    required this.tags,
    required this.tagsByItem,
    required this.projectByItem,
  });
}

class _TodayTaskGroup {
  final ProjectFull? project;
  final List<WorkItem> items;

  const _TodayTaskGroup({required this.project, required this.items});

  bool get isGeneral => project == null;
  String get title => project?.title ?? 'General tasks';
}

Future<_TodayTaskContext> _loadTodayTaskContext(
  AppState state,
  List<WorkItem> items,
  int refreshRevision,
) async {
  final projects = await state.getProjectsFull();
  final tags = await state.getTags();
  final tagsByItem = await state.getTagsForWorkItems(
    items.map((item) => item.id),
  );
  final projectByItem = <String, ProjectFull?>{};
  for (final item in items) {
    projectByItem[item.id] = await state.getProjectForWorkItem(item.id);
  }
  return _TodayTaskContext(
    projects: projects,
    tags: tags,
    tagsByItem: tagsByItem,
    projectByItem: projectByItem,
  );
}

class _TodayTaskList extends StatelessWidget {
  final List<WorkItem> items;
  final String? projectFilterId;
  final String? tagFilterId;
  final String? statusFilter;
  final int refreshRevision;
  final ValueChanged<String?> onProjectFilterChanged;
  final ValueChanged<String?> onTagFilterChanged;
  final ValueChanged<String?> onStatusFilterChanged;
  final VoidCallback onTaskTagsChanged;

  const _TodayTaskList({
    required this.items,
    required this.projectFilterId,
    required this.tagFilterId,
    required this.statusFilter,
    required this.refreshRevision,
    required this.onProjectFilterChanged,
    required this.onTagFilterChanged,
    required this.onStatusFilterChanged,
    required this.onTaskTagsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<_TodayTaskContext>(
      future: _loadTodayTaskContext(state, items, refreshRevision),
      builder: (context, snap) {
        final contextData = snap.data;
        final filtered = contextData == null
            ? items
            : items
                  .where((item) {
                    if (projectFilterId != null) {
                      final itemProject = contextData.projectByItem[item.id];
                      if (projectFilterId == AppDb.kGeneralTasksProjectId) {
                        if (itemProject != null) return false;
                      } else if (itemProject?.id != projectFilterId) {
                        return false;
                      }
                    }
                    if (tagFilterId != null &&
                        !(contextData.tagsByItem[item.id] ?? const <Tag>[]).any(
                          (tag) => tag.id == tagFilterId,
                        )) {
                      return false;
                    }
                    if (statusFilter != null &&
                        normalizeStatusValue(item.status) != statusFilter) {
                      return false;
                    }
                    return true;
                  })
                  .toList(growable: false);
        final groups = contextData == null
            ? const <_TodayTaskGroup>[]
            : _groupTodayTasks(filtered, contextData.projectByItem);

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF151A22),
            border: Border.all(color: const Color(0xFF273044)),
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.checklist, size: 18, color: Colors.white70),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Task list',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${filtered.length}/${items.length}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (contextData == null)
                const LinearProgressIndicator(minHeight: 2)
              else
                _TodayTaskFilters(
                  projects: contextData.projects,
                  tags: contextData.tags,
                  projectFilterId: projectFilterId,
                  tagFilterId: tagFilterId,
                  statusFilter: statusFilter,
                  onProjectFilterChanged: onProjectFilterChanged,
                  onTagFilterChanged: onTagFilterChanged,
                  onStatusFilterChanged: onStatusFilterChanged,
                ),
              const SizedBox(height: 12),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      'No active tasks match these filters.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                ...groups.map(
                  (group) => _TodayTaskGroupPanel(
                    group: group,
                    tagsByItem: contextData!.tagsByItem,
                    allTags: contextData.tags,
                    onChanged: onTaskTagsChanged,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

List<_TodayTaskGroup> _groupTodayTasks(
  List<WorkItem> items,
  Map<String, ProjectFull?> projectByItem,
) {
  final general = <WorkItem>[];
  final byProjectId = <String, ({ProjectFull project, List<WorkItem> items})>{};
  for (final item in items) {
    final project = projectByItem[item.id];
    if (project == null) {
      general.add(item);
      continue;
    }
    final existing = byProjectId[project.id];
    if (existing == null) {
      byProjectId[project.id] = (project: project, items: [item]);
    } else {
      existing.items.add(item);
    }
  }
  final groups = <_TodayTaskGroup>[];
  if (general.isNotEmpty) {
    groups.add(_TodayTaskGroup(project: null, items: general));
  }
  final projectGroups = byProjectId.values.toList()
    ..sort(
      (a, b) => a.project.title.toLowerCase().compareTo(
        b.project.title.toLowerCase(),
      ),
    );
  for (final group in projectGroups) {
    groups.add(_TodayTaskGroup(project: group.project, items: group.items));
  }
  return groups;
}

class _TodayTaskGroupPanel extends StatelessWidget {
  final _TodayTaskGroup group;
  final Map<String, List<Tag>> tagsByItem;
  final List<Tag> allTags;
  final VoidCallback onChanged;

  const _TodayTaskGroupPanel({
    required this.group,
    required this.tagsByItem,
    required this.allTags,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: group.isGeneral
            ? const Color(0x1A79A7FF)
            : const Color(0xFF10141B),
        border: Border.all(
          color: group.isGeneral
              ? const Color(0x5579A7FF)
              : const Color(0xFF273044),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          initiallyExpanded: group.isGeneral || group.items.length <= 3,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          leading: Icon(
            group.isGeneral ? Icons.push_pin_outlined : Icons.folder_outlined,
            size: 18,
            color: group.isGeneral ? const Color(0xFF79A7FF) : Colors.white70,
          ),
          title: Text(
            group.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${group.items.length} ${group.items.length == 1 ? 'task' : 'tasks'} available',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          children: [
            for (final item in group.items)
              _TaskListTile(
                item: item,
                project: group.project,
                showProjectChip: false,
                tags: tagsByItem[item.id] ?? const <Tag>[],
                allTags: allTags,
                onChanged: onChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _TodayTaskFilters extends StatelessWidget {
  final List<ProjectFull> projects;
  final List<Tag> tags;
  final String? projectFilterId;
  final String? tagFilterId;
  final String? statusFilter;
  final ValueChanged<String?> onProjectFilterChanged;
  final ValueChanged<String?> onTagFilterChanged;
  final ValueChanged<String?> onStatusFilterChanged;

  const _TodayTaskFilters({
    required this.projects,
    required this.tags,
    required this.projectFilterId,
    required this.tagFilterId,
    required this.statusFilter,
    required this.onProjectFilterChanged,
    required this.onTagFilterChanged,
    required this.onStatusFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final children = [
          _filterDropdown(
            label: 'Project',
            allLabel: 'All projects',
            value: projectFilterId,
            values: {
              AppDb.kGeneralTasksProjectId: 'General tasks',
              for (final project in projects) project.id: project.title,
            },
            onChanged: onProjectFilterChanged,
          ),
          _filterDropdown(
            label: 'Tag',
            allLabel: 'All tags',
            value: tagFilterId,
            values: {for (final tag in tags) tag.id: tag.name},
            onChanged: onTagFilterChanged,
          ),
          _filterDropdown(
            label: 'Status',
            allLabel: 'All status',
            value: statusFilter,
            values: {
              for (final option in statusOptions.where(
                (option) => option.value != 'archived',
              ))
                option.value: option.label,
            },
            onChanged: onStatusFilterChanged,
          ),
        ];
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final child in children) ...[
                child,
                const SizedBox(height: 8),
              ],
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              Expanded(child: children[i]),
              if (i != children.length - 1) const SizedBox(width: 8),
            ],
          ],
        );
      },
    );
  }

  Widget _filterDropdown({
    required String label,
    required String allLabel,
    required String? value,
    required Map<String, String> values,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: [
        DropdownMenuItem(
          value: '',
          child: Text(allLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        for (final entry in values.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (next) =>
          onChanged(next == null || next.isEmpty ? null : next),
    );
  }
}

class _TaskListTile extends StatelessWidget {
  final WorkItem item;
  final ProjectFull? project;
  final bool showProjectChip;
  final List<Tag> tags;
  final List<Tag> allTags;
  final VoidCallback onChanged;

  const _TaskListTile({
    required this.item,
    required this.project,
    this.showProjectChip = true,
    required this.tags,
    required this.allTags,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF10141B),
        border: Border.all(color: const Color(0xFF273044)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showWorkItemDetailSheet(context, item.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: item.completed,
                onChanged: (_) async {
                  await state.toggleWorkDone(item.id);
                  onChanged();
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: item.completed
                            ? TextDecoration.lineThrough
                            : null,
                        color: item.completed ? Colors.white38 : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (showProjectChip && project != null)
                          _SmallChip(
                            icon: Icons.folder_outlined,
                            label: project!.title,
                            color: const Color(0xFF79A7FF),
                          ),
                        statusChip(normalizeStatusValue(item.status)),
                        for (final tag in tags)
                          _SmallChip(
                            icon: Icons.label_outline,
                            label: tag.name,
                            color: _tagColor(tag),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _PriorityBadge(normalizePriorityValue(item.priority)),
                  if (item.dueAt != null) ...[
                    const SizedBox(height: 6),
                    _DueBadge(item.dueAt!),
                  ],
                  IconButton(
                    tooltip: 'Edit tags',
                    icon: const Icon(Icons.sell_outlined, size: 18),
                    onPressed: () => _editTags(context, state),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editTags(BuildContext context, AppState state) async {
    final selection = await showDialog<_TaskTagSelection>(
      context: context,
      builder: (_) =>
          _TaskTagDialog(tags: allTags, selectedTagIds: tags.map((t) => t.id)),
    );
    if (selection == null) return;
    final createdIds = <String>[];
    for (final name in selection.newTagNames) {
      createdIds.add(await state.saveTag(name: name));
    }
    await state.setWorkItemTags(item.id, {...selection.tagIds, ...createdIds});
    onChanged();
  }
}

class _SmallChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SmallChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TodayTaskDraft {
  final String? projectId;
  final String title;
  final String? description;
  final String? owner;
  final String status;
  final String priority;
  final DateTime? dueAt;
  final Set<String> tagIds;
  final List<String> newTagNames;

  const _TodayTaskDraft({
    required this.projectId,
    required this.title,
    required this.description,
    required this.owner,
    required this.status,
    required this.priority,
    required this.dueAt,
    required this.tagIds,
    required this.newTagNames,
  });
}

class _TodayTaskDialog extends StatefulWidget {
  final List<ProjectFull> projects;
  final List<Tag> tags;

  const _TodayTaskDialog({required this.projects, required this.tags});

  @override
  State<_TodayTaskDialog> createState() => _TodayTaskDialogState();
}

class _TodayTaskDialogState extends State<_TodayTaskDialog> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _owner = TextEditingController();
  final _newTags = TextEditingController();
  String? _projectId;
  String _status = 'next';
  String _priority = 'normal';
  DateTime? _dueAt;
  final _tagIds = <String>{};

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _owner.dispose();
    _newTags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add task'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _projectId ?? '',
                decoration: const InputDecoration(
                  labelText: 'Project',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('General task'),
                  ),
                  for (final project in widget.projects)
                    DropdownMenuItem(
                      value: project.id,
                      child: Text(project.title),
                    ),
                ],
                onChanged: (value) => setState(
                  () => _projectId = value == null || value.isEmpty
                      ? null
                      : value,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Task *',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _description,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _status,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final option in statusOptions.where(
                          (option) =>
                              !['done', 'archived'].contains(option.value),
                        ))
                          DropdownMenuItem(
                            value: option.value,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _status = value);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _priority,
                      decoration: const InputDecoration(
                        labelText: 'Priority',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final option in priorityOptions)
                          DropdownMenuItem(
                            value: option.value,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _priority = value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: ContactOwnerField(controller: _owner)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: InkWell(
                      onTap: _pickDueDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Due',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _dueAt == null
                                    ? 'None'
                                    : '${_dueAt!.month}/${_dueAt!.day}/${_dueAt!.year}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_dueAt != null)
                              GestureDetector(
                                onTap: () => setState(() => _dueAt = null),
                                child: const Icon(Icons.clear, size: 16),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in widget.tags)
                      FilterChip(
                        label: Text(tag.name),
                        selected: _tagIds.contains(tag.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _tagIds.add(tag.id);
                          } else {
                            _tagIds.remove(tag.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _newTags,
                decoration: const InputDecoration(
                  labelText: 'New tags',
                  hintText: 'comma separated',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
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

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      _TodayTaskDraft(
        projectId: _projectId,
        title: title,
        description: _blankToNull(_description.text),
        owner: _blankToNull(_owner.text),
        status: normalizeStatusValue(_status),
        priority: normalizePriorityValue(_priority),
        dueAt: _dueAt,
        tagIds: Set.unmodifiable(_tagIds),
        newTagNames: _splitTagNames(_newTags.text),
      ),
    );
  }
}

class _TaskTagSelection {
  final Set<String> tagIds;
  final List<String> newTagNames;

  const _TaskTagSelection({required this.tagIds, required this.newTagNames});
}

class _TaskTagDialog extends StatefulWidget {
  final List<Tag> tags;
  final Iterable<String> selectedTagIds;

  const _TaskTagDialog({required this.tags, required this.selectedTagIds});

  @override
  State<_TaskTagDialog> createState() => _TaskTagDialogState();
}

class _TaskTagDialogState extends State<_TaskTagDialog> {
  late final Set<String> _selected = widget.selectedTagIds.toSet();
  final _newTags = TextEditingController();

  @override
  void dispose() {
    _newTags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Task tags'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in widget.tags)
                  FilterChip(
                    label: Text(tag.name),
                    selected: _selected.contains(tag.id),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selected.add(tag.id);
                      } else {
                        _selected.remove(tag.id);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newTags,
              decoration: const InputDecoration(
                labelText: 'New tags',
                hintText: 'comma separated',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _TaskTagSelection(
              tagIds: Set.unmodifiable(_selected),
              newTagNames: _splitTagNames(_newTags.text),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _splitTagNames(String value) {
  final seen = <String>{};
  final names = <String>[];
  for (final raw in value.split(',')) {
    final name = raw.trim();
    if (name.isEmpty) continue;
    if (seen.add(name.toLowerCase())) names.add(name);
  }
  return names;
}

Color _tagColor(Tag tag) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return const Color(0xFF79A7FF);
}

class _TodayLoadError extends StatelessWidget {
  final Object? error;
  const _TodayLoadError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 44,
              color: Colors.orangeAccent,
            ),
            const SizedBox(height: 12),
            const Text(
              'Today failed to load.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final List<WorkItem> items;
  const _SummaryRow({required this.items});

  Future<void> _showDrilldown(
    BuildContext context,
    String title,
    List<WorkItem> rows,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TodayDrilldownDialog(title: title, items: rows),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final doingCount = items.where((i) => i.status == 'doing').length;
    final overdueCount = items
        .where(
          (i) =>
              i.dueAt != null &&
              i.dueAt!.isBefore(today) &&
              i.status != 'doing',
        )
        .length;
    final blockedCount = items.where((i) => i.blockedReason != null).length;
    final totalCount = items
        .where(
          (i) =>
              i.status == 'doing' ||
              (i.dueAt != null && i.dueAt!.isBefore(tomorrow)) ||
              i.phoneQueue ||
              ['high', 'urgent'].contains(i.priority),
        )
        .length;

    return Row(
      children: [
        _MetricBox(
          label: 'Doing',
          value: doingCount,
          color: const Color(0xFFFFC107),
          onTap: () => _showDrilldown(
            context,
            'Doing',
            items
                .where((i) => normalizeStatusValue(i.status) == 'doing')
                .toList(),
          ),
        ),
        const SizedBox(width: 10),
        _MetricBox(
          label: 'Overdue',
          value: overdueCount,
          color: const Color(0xFFF44336),
          onTap: () => _showDrilldown(
            context,
            'Overdue',
            items
                .where(
                  (i) =>
                      i.dueAt != null &&
                      i.dueAt!.isBefore(today) &&
                      normalizeStatusValue(i.status) != 'doing',
                )
                .toList(),
          ),
        ),
        const SizedBox(width: 10),
        _MetricBox(
          label: 'Blocked',
          value: blockedCount,
          color: const Color(0xFF9C27B0),
          onTap: () => _showDrilldown(
            context,
            'Blocked',
            items.where((i) => i.blockedReason != null).toList(),
          ),
        ),
        const SizedBox(width: 10),
        _MetricBox(
          label: 'Total',
          value: totalCount,
          color: Colors.white54,
          onTap: () => _showDrilldown(
            context,
            'Today items',
            items
                .where(
                  (i) =>
                      normalizeStatusValue(i.status) == 'doing' ||
                      (i.dueAt != null && i.dueAt!.isBefore(tomorrow)) ||
                      i.phoneQueue ||
                      [
                        'high',
                        'urgent',
                      ].contains(normalizePriorityValue(i.priority)),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _MetricBox extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final VoidCallback onTap;
  const _MetricBox({
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF151A22),
            border: Border.all(color: const Color(0xFF273044)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: value > 0 ? color : Colors.white24,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TodayDrilldownDialog extends StatelessWidget {
  final String title;
  final List<WorkItem> items;
  const _TodayDrilldownDialog({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('$title (${items.length})'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: items.isEmpty
            ? const Center(child: Text('No matching items.'))
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _DrilldownRow(item: items[index]),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DrilldownRow extends StatelessWidget {
  final WorkItem item;
  const _DrilldownRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<Stage?>(
      future: (state.db.select(
        state.db.stages,
      )..where((t) => t.id.equals(item.stageId))).getSingleOrNull(),
      builder: (context, snap) {
        final stage = snap.data;
        return ListTile(
          title: Text(item.title),
          subtitle: Text(
            [
              if (stage != null) 'Stage: ${stage.title}',
              'Status: ${normalizeStatusValue(item.status)}',
              'Priority: ${normalizePriorityValue(item.priority)}',
              if ((item.owner ?? '').isNotEmpty) 'Owner: ${item.owner}',
              if (item.dueAt != null)
                'Due: ${item.dueAt!.month}/${item.dueAt!.day}/${item.dueAt!.year}',
              if ((item.blockedReason ?? '').isNotEmpty)
                'Blocked: ${item.blockedReason}',
              'Last activity: ${item.updatedAt}',
            ].join('  |  '),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showWorkItemDetailSheet(context, item.id),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final Color color;
  const _SectionHeader({
    required this.label,
    required this.icon,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: color,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$count', style: TextStyle(fontSize: 11, color: color)),
          ),
        ],
      ),
    );
  }
}

class _TodayTile extends StatelessWidget {
  final WorkItem item;
  const _TodayTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showWorkItemDetailSheet(context, item.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Quick done toggle
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: item.completed,
                  onChanged: (_) => state.toggleWorkDone(item.id),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: item.completed
                            ? TextDecoration.lineThrough
                            : null,
                        color: item.completed ? Colors.white38 : null,
                      ),
                    ),
                    if (item.description != null &&
                        item.description!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.description!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (item.blockedReason != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.block, size: 12, color: Colors.red),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.blockedReason!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.red,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _PriorityBadge(item.priority),
                  if (item.dueAt != null) ...[
                    const SizedBox(height: 4),
                    _DueBadge(item.dueAt!),
                  ],
                  if (item.phoneQueue) ...[
                    const SizedBox(height: 4),
                    const Icon(Icons.phone, size: 14, color: Colors.blue),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final String priority;
  const _PriorityBadge(this.priority);

  @override
  Widget build(BuildContext context) {
    if (priority == 'normal' || priority == 'low') {
      return const SizedBox.shrink();
    }
    final (label, color) = switch (priority) {
      'high' => ('HIGH', Colors.orange),
      'urgent' => ('URGENT', Colors.red),
      _ => (priority.toUpperCase(), Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _DueBadge extends StatelessWidget {
  final DateTime dueAt;
  const _DueBadge(this.dueAt);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isOverdue = dueAt.isBefore(today);
    final isToday =
        !dueAt.isBefore(today) &&
        dueAt.isBefore(today.add(const Duration(days: 1)));

    final color = isOverdue
        ? Colors.red
        : isToday
        ? Colors.orange
        : Colors.white54;

    return Text(
      '${dueAt.month}/${dueAt.day}',
      style: TextStyle(fontSize: 11, color: color),
    );
  }
}
