import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/create_work_item_dialog.dart';
import '../today/work_item_detail_sheet.dart';
import 'status_priority_helpers.dart';

class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key});

  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> {
  String? _filterStatus;
  static const _activeStatuses = ['inbox', 'next', 'doing', 'waiting'];

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Work')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<Project?>(
          stream: state.watchActiveProject(),
          builder: (context, projSnap) {
            final project = projSnap.data;
            if (project == null) {
              return const Center(
                child: Text('No active project - create or select one.'),
              );
            }
            return StreamBuilder<List<Stage>>(
              stream: state.watchStagesForProject(project.id),
              builder: (context, stagesSnap) {
                final stages = stagesSnap.data ?? const <Stage>[];
                return StreamBuilder<Stage?>(
                  stream: state.watchActiveStageForProject(project.id),
                  builder: (context, activeStageSnap) {
                    final activeStage =
                        activeStageSnap.data ??
                        (stages.isNotEmpty ? stages.first : null);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ProjectSelector(activeProject: project),
                        const SizedBox(height: 12),
                        if (stages.isEmpty)
                          const Text(
                            'This project has no stages yet.',
                            style: TextStyle(color: Colors.white54),
                          )
                        else
                          SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final s in stages)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(s.title),
                                      selected: s.id == activeStage?.id,
                                      onSelected: (_) =>
                                          state.setActiveStageForProject(
                                            project.id,
                                            s.id,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 32,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              _FilterChip(
                                label: 'All Active',
                                selected: _filterStatus == null,
                                onTap: () =>
                                    setState(() => _filterStatus = null),
                              ),
                              for (final s in statusOptions.where(
                                (s) => _activeStatuses.contains(s.value),
                              ))
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: _FilterChip(
                                    label: s.label,
                                    selected: _filterStatus == s.value,
                                    color: s.color,
                                    onTap: () =>
                                        setState(() => _filterStatus = s.value),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              activeStage == null
                                  ? 'Work items'
                                  : 'Work items - ${activeStage.title}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: activeStage == null
                                  ? null
                                  : () => _addTask(context, activeStage.id),
                              icon: const Icon(Icons.add),
                              label: const Text('Add task'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: activeStage == null
                              ? const Center(
                                  child: Text(
                                    'Create or select a project stage to add tasks.',
                                  ),
                                )
                              : StreamBuilder<List<WorkItem>>(
                                  stream: state.watchWorkItemsForStage(
                                    activeStage.id,
                                  ),
                                  builder: (context, workSnap) {
                                    var items =
                                        workSnap.data ?? const <WorkItem>[];
                                    if (_filterStatus != null) {
                                      items = items
                                          .where(
                                            (i) =>
                                                normalizeStatusValue(
                                                  i.status,
                                                ) ==
                                                _filterStatus,
                                          )
                                          .toList();
                                    } else {
                                      items = items
                                          .where(
                                            (i) =>
                                                !['done', 'archived'].contains(
                                                  normalizeStatusValue(
                                                    i.status,
                                                  ),
                                                ),
                                          )
                                          .toList();
                                    }
                                    if (items.isEmpty) {
                                      return Center(
                                        child: Text(
                                          _filterStatus != null
                                              ? 'No "${statusFor(_filterStatus!).label}" items in this stage.'
                                              : 'No active tasks. Use Add task to create one for this project/stage.',
                                          style: const TextStyle(
                                            color: Colors.white54,
                                          ),
                                        ),
                                      );
                                    }
                                    return ListView.separated(
                                      itemCount: items.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(height: 1),
                                      itemBuilder: (context, i) =>
                                          _WorkTile(item: items[i]),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _addTask(BuildContext context, String stageId) async {
    final state = AppStateScope.of(context);
    final draft = await showCreateWorkItemDialog(context);
    if (draft == null) return;
    DateTime? dueAt;
    final rawDate = draft['dueAt'];
    if (rawDate != null && rawDate.isNotEmpty)
      dueAt = DateTime.tryParse(rawDate);
    await state.addWorkItem(
      stageId,
      draft['title']!,
      description: draft['description'],
      owner: draft['owner'],
      status: normalizeStatusValue(draft['status']),
      priority: normalizePriorityValue(draft['priority']),
      dueAt: dueAt,
    );
  }
}

class _ProjectSelector extends StatelessWidget {
  final Project activeProject;
  const _ProjectSelector({required this.activeProject});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Project>>(
      stream: state.watchProjects(),
      builder: (context, snap) {
        final projects = snap.data ?? const <Project>[];
        final value = projects.any((p) => p.id == activeProject.id)
            ? activeProject.id
            : null;
        return DropdownButtonFormField<String>(
          value: value,
          decoration: const InputDecoration(
            labelText: 'Project',
            border: OutlineInputBorder(),
          ),
          items: projects
              .map((p) => DropdownMenuItem(value: p.id, child: Text(p.title)))
              .toList(),
          onChanged: (id) {
            if (id != null) state.setActiveById(id);
          },
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? c.withAlpha(40) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? c.withAlpha(150) : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? c : Colors.white54,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _WorkTile extends StatelessWidget {
  final WorkItem item;
  const _WorkTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return InkWell(
      onTap: () => showWorkItemDetailSheet(context, item.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Checkbox(
                value: item.completed,
                onChanged: (_) => state.toggleWorkDone(item.id),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      priorityDot(normalizePriorityValue(item.priority)),
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            decoration: item.completed
                                ? TextDecoration.lineThrough
                                : null,
                            color: item.completed ? Colors.white38 : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      statusChip(normalizeStatusValue(item.status)),
                      if (item.owner != null)
                        _MetaChip(
                          Icons.person_outline,
                          item.owner!,
                          Colors.white38,
                        ),
                      if (item.dueAt != null) _DueDateChip(item.dueAt!),
                      if (item.phoneQueue)
                        _MetaChip(Icons.phone, 'Phone', Colors.blue),
                      if (item.blockedReason != null)
                        _MetaChip(Icons.block, 'Blocked', Colors.red),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MetaChip(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

class _DueDateChip extends StatelessWidget {
  final DateTime dueAt;
  const _DueDateChip(this.dueAt);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isOverdue = dueAt.isBefore(today);
    final isToday =
        !isOverdue && dueAt.isBefore(today.add(const Duration(days: 1)));
    final color = isOverdue
        ? Colors.red
        : isToday
        ? Colors.orange
        : Colors.white38;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.calendar_today, size: 11, color: color),
        const SizedBox(width: 3),
        Text(
          '${dueAt.month}/${dueAt.day}',
          style: TextStyle(fontSize: 10, color: color),
        ),
      ],
    );
  }
}
