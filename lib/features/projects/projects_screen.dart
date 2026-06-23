import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/create_project_dialog.dart';
import '../work/status_priority_helpers.dart';

const _kPanel = Color(0xFF151A22);
const _kLine = Color(0xFF273044);
const _kPrimary = Color(0xFF79A7FF);

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
  'low': Color(0xFF607D8B),
  'normal': Color(0x8AFFFFFF),
  'high': Color(0xFFFF9800),
  'urgent': Color(0xFFF44336),
};

Color _statusColor(String? s) => _kStatusColors[s] ?? const Color(0x61FFFFFF);
Color _phaseColor(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);
Color _priorityColor(String? p) =>
    _kPriorityColors[normalizePriorityValue(p)] ?? const Color(0x61FFFFFF);

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  String? _tagFilterId;
  String? _statusFilter;
  String? _phaseFilter;
  String? _priorityFilter;

  bool get _hasFilters =>
      _tagFilterId != null ||
      _statusFilter != null ||
      _phaseFilter != null ||
      _priorityFilter != null;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          FilledButton.icon(
            onPressed: () async {
              final title = await showCreateProjectDialog(context);
              if (title == null || title.trim().isEmpty) return;
              await state.createProject(title.trim());
              final active = state.activeProject;
              if (context.mounted && active != null) {
                context.go('/projects/${active.id}');
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('New project'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: StreamBuilder<List<Project>>(
        stream: state.watchProjects(),
        builder: (context, projectSnap) {
          if (projectSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = projectSnap.data ?? const <Project>[];
          return StreamBuilder<List<Tag>>(
            stream: state.watchTags(),
            builder: (context, tagSnap) {
              final tags = tagSnap.data ?? const <Tag>[];
              return FutureBuilder<Map<String, List<Tag>>>(
                future: _loadTagsForProjects(state, projects),
                builder: (context, projectTagSnap) {
                  final projectTags =
                      projectTagSnap.data ?? const <String, List<Tag>>{};
                  final filtered = _filterProjects(projects, projectTags);
                  return Column(
                    children: [
                      _FilterBar(
                        tags: tags,
                        tagFilterId: _tagFilterId,
                        statusFilter: _statusFilter,
                        phaseFilter: _phaseFilter,
                        priorityFilter: _priorityFilter,
                        hasFilters: _hasFilters,
                        onTagChanged: (v) => setState(() => _tagFilterId = v),
                        onStatusChanged: (v) =>
                            setState(() => _statusFilter = v),
                        onPhaseChanged: (v) => setState(() => _phaseFilter = v),
                        onPriorityChanged: (v) =>
                            setState(() => _priorityFilter = v),
                        onClear: () => setState(() {
                          _tagFilterId = null;
                          _statusFilter = null;
                          _phaseFilter = null;
                          _priorityFilter = null;
                        }),
                        totalCount: projects.length,
                        filteredCount: filtered.length,
                      ),
                      const Divider(height: 1, color: _kLine),
                      Expanded(
                        child: projects.isEmpty
                            ? const _EmptyProjects()
                            : filtered.isEmpty
                            ? const Center(
                                child: Text(
                                  'No projects match the current filters.',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              )
                            : StreamBuilder<Project?>(
                                stream: state.watchActiveProject(),
                                builder: (context, activeSnap) {
                                  final activeId = activeSnap.data?.id;
                                  return ListView.builder(
                                    padding: const EdgeInsets.all(16),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, i) {
                                      final p = filtered[i];
                                      return _ProjectTile(
                                        project: p,
                                        tags:
                                            projectTags[p.id] ?? const <Tag>[],
                                        isActive: p.id == activeId,
                                        onTap: () async {
                                          await state.setActiveById(p.id);
                                          if (context.mounted) {
                                            context.go('/projects/${p.id}');
                                          }
                                        },
                                      );
                                    },
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
    );
  }

  Future<Map<String, List<Tag>>> _loadTagsForProjects(
    AppState state,
    List<Project> projects,
  ) async {
    final entries = await Future.wait(
      projects.map(
        (p) async => MapEntry(p.id, await state.getTagsForProject(p.id)),
      ),
    );
    return Map.fromEntries(entries);
  }

  List<Project> _filterProjects(
    List<Project> projects,
    Map<String, List<Tag>> projectTags,
  ) {
    return projects
        .where((p) {
          if (_tagFilterId != null &&
              !(projectTags[p.id] ?? const <Tag>[]).any(
                (tag) => tag.id == _tagFilterId,
              )) {
            return false;
          }
          if (_statusFilter != null && p.status != _statusFilter) return false;
          if (_phaseFilter != null && p.phase != _phaseFilter) return false;
          if (_priorityFilter != null &&
              normalizePriorityValue(p.priority) != _priorityFilter) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }
}

class _FilterBar extends StatelessWidget {
  final List<Tag> tags;
  final String? tagFilterId;
  final String? statusFilter;
  final String? phaseFilter;
  final String? priorityFilter;
  final bool hasFilters;
  final ValueChanged<String?> onTagChanged;
  final ValueChanged<String?> onStatusChanged;
  final ValueChanged<String?> onPhaseChanged;
  final ValueChanged<String?> onPriorityChanged;
  final VoidCallback onClear;
  final int totalCount;
  final int filteredCount;

  const _FilterBar({
    required this.tags,
    required this.tagFilterId,
    required this.statusFilter,
    required this.phaseFilter,
    required this.priorityFilter,
    required this.hasFilters,
    required this.onTagChanged,
    required this.onStatusChanged,
    required this.onPhaseChanged,
    required this.onPriorityChanged,
    required this.onClear,
    required this.totalCount,
    required this.filteredCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kPanel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Dropdown<String?>(
            value: tagFilterId,
            width: 150,
            items: [
              const DropdownMenuItem(value: null, child: Text('All tags')),
              ...tags.map(
                (tag) => DropdownMenuItem(
                  value: tag.id,
                  child: Text(tag.name, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
            onChanged: onTagChanged,
          ),
          _Dropdown<String?>(
            value: statusFilter,
            width: 140,
            items: const [
              DropdownMenuItem(value: null, child: Text('All statuses')),
              DropdownMenuItem(value: 'active', child: Text('active')),
              DropdownMenuItem(value: 'paused', child: Text('paused')),
              DropdownMenuItem(value: 'blocked', child: Text('blocked')),
              DropdownMenuItem(value: 'completed', child: Text('completed')),
              DropdownMenuItem(value: 'archived', child: Text('archived')),
            ],
            onChanged: onStatusChanged,
          ),
          _Dropdown<String?>(
            value: phaseFilter,
            width: 130,
            items: const [
              DropdownMenuItem(value: null, child: Text('All phases')),
              DropdownMenuItem(value: 'idea', child: Text('idea')),
              DropdownMenuItem(value: 'design', child: Text('design')),
              DropdownMenuItem(value: 'build', child: Text('build')),
              DropdownMenuItem(value: 'test', child: Text('test')),
              DropdownMenuItem(value: 'ship', child: Text('ship')),
              DropdownMenuItem(value: 'stabilize', child: Text('stabilize')),
            ],
            onChanged: onPhaseChanged,
          ),
          _Dropdown<String?>(
            value: priorityFilter,
            width: 140,
            items: const [
              DropdownMenuItem(value: null, child: Text('All priority')),
              DropdownMenuItem(value: 'low', child: Text('low')),
              DropdownMenuItem(value: 'normal', child: Text('normal')),
              DropdownMenuItem(value: 'high', child: Text('high')),
              DropdownMenuItem(value: 'urgent', child: Text('urgent')),
            ],
            onChanged: onPriorityChanged,
          ),
          Text(
            hasFilters
                ? '$filteredCount / $totalCount'
                : '$totalCount projects',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          if (hasFilters)
            TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.filter_alt_off, size: 16),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  final List<Tag> tags;
  final bool isActive;
  final VoidCallback onTap;

  const _ProjectTile({
    required this.project,
    required this.tags,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhase = (project.phase ?? '').isNotEmpty;
    final priority = normalizePriorityValue(project.priority);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _kPanel,
            border: Border.all(
              color: isActive ? const Color(0x4479A7FF) : _kLine,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0x2679A7FF)
                      : const Color(0x10FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isActive ? Icons.folder_open : Icons.folder_outlined,
                  size: 18,
                  color: isActive ? _kPrimary : Colors.white38,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            project.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (isActive) const _ActivePill(),
                      ],
                    ),
                    if ((project.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        project.description!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        _Pill(
                          label: project.status,
                          color: _statusColor(project.status),
                        ),
                        if (hasPhase)
                          _Pill(
                            label: project.phase!,
                            color: _phaseColor(project.phase),
                          ),
                        if (priority != 'normal')
                          _Pill(
                            label: priority,
                            color: _priorityColor(priority),
                          ),
                        ...tags
                            .take(4)
                            .map(
                              (tag) => _Pill(
                                label: '#${tag.name}',
                                color: _tagColor(tag),
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivePill extends StatelessWidget {
  const _ActivePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x2679A7FF),
        border: Border.all(color: const Color(0x4D79A7FF)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'ACTIVE',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: _kPrimary,
        ),
      ),
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 48, color: Colors.white38),
            SizedBox(height: 16),
            Text(
              'No projects yet.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'Create a project to unlock its detail view, task stage,\nownership map, risks, decisions, and documents.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double width;

  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 38,
      child: DropdownButtonFormField<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isExpanded: true,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(34),
        border: Border.all(color: color.withAlpha(68)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

Color _tagColor(Tag tag) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return _kPrimary;
}
