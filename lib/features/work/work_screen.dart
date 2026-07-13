import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../services/workload_planning_service.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/create_work_item_dialog.dart';
import '../today/work_item_detail_sheet.dart';
import 'status_priority_helpers.dart';

class WorkScreen extends StatefulWidget {
  final String? initialProjectId;
  final bool projectScoped;

  const WorkScreen({
    super.key,
    this.initialProjectId,
    this.projectScoped = false,
  });

  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> {
  late WorkloadFilters _filters;
  Future<List<Project>>? _projectsFuture;
  Future<WorkloadSnapshot>? _snapshotFuture;
  final Set<String> _selected = {};
  bool _didLoad = false;

  static const _groupLabels = {
    'ready': 'Ready',
    'needs_decision': 'Needs Decision',
    'blocked': 'Blocked',
    'in_progress': 'In Progress',
    'review_needed': 'Review Needed',
    'done_closed': 'Done / Closed',
  };

  @override
  void initState() {
    super.initState();
    _filters = WorkloadFilters(projectId: widget.initialProjectId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoad) return;
    _didLoad = true;
    _reload();
  }

  void _reload({bool clearSelection = false}) {
    final state = AppStateScope.read(context);
    setState(() {
      _projectsFuture = state.getVisibleProjects();
      _snapshotFuture = state.getWorkloadSnapshot(filters: _filters);
      if (clearSelection) _selected.clear();
    });
  }

  void _setFilters(WorkloadFilters filters) {
    final state = AppStateScope.read(context);
    final nextFilters = widget.projectScoped
        ? filters.copyWith(projectId: widget.initialProjectId)
        : filters;
    setState(() {
      _filters = nextFilters;
      _snapshotFuture = state.getWorkloadSnapshot(filters: _filters);
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _reload(clearSelection: true),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Add task',
            onPressed: _addTask,
            icon: const Icon(Icons.add_task_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<Project>>(
        future: _projectsFuture,
        builder: (context, projectSnap) {
          final projects = projectSnap.data ?? const <Project>[];
          return FutureBuilder<WorkloadSnapshot>(
            future: _snapshotFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  snap.data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('Workboard failed: ${snap.error}'));
              }
              final snapshot = snap.data;
              if (snapshot == null) {
                return const Center(child: Text('No workload data loaded.'));
              }
              return Column(
                children: [
                  _FiltersBar(
                    projects: projects,
                    filters: _filters,
                    projectScoped: widget.projectScoped,
                    onChanged: _setFilters,
                  ),
                  _SnapshotPanel(snapshot: snapshot),
                  _BulkPlanningBar(
                    selectedCount: _selected.length,
                    onClear: () => setState(_selected.clear),
                    onMarkReady: () => _markReady(snapshot),
                    onMarkBlocked: () => _markBlocked(snapshot),
                    onAssignActor: () => _assignActor(snapshot),
                    onSetPlanningFields: () => _setPlanningFields(snapshot),
                    onReviewed: () => _markReviewed(snapshot),
                    onCreateQueueItems: () => _createQueueItems(snapshot),
                    onLinkQueueItem: () => _linkQueueItem(snapshot),
                  ),
                  const Divider(height: 1),
                  Expanded(child: _buildBoard(snapshot: snapshot)),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildBoard({required WorkloadSnapshot snapshot}) {
    final grouped = <String, List<WorkloadCard>>{
      for (final group in workloadBoardGroups) group: [],
    };
    for (final card in snapshot.cards) {
      grouped.putIfAbsent(card.boardGroup, () => []).add(card);
    }
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final group in workloadBoardGroups)
              if (group != 'done_closed' || grouped[group]!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _BoardColumn(
                    title: _groupLabels[group] ?? group,
                    group: group,
                    cards: grouped[group]!,
                    selectedKeys: _selected,
                    onSelectChanged: (card, selected) {
                      setState(() {
                        final key = _cardKey(card);
                        if (selected) {
                          _selected.add(key);
                        } else {
                          _selected.remove(key);
                        }
                      });
                    },
                    onOpen: _openCard,
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _addTask() async {
    final state = AppStateScope.read(context);
    final projectId =
        _filters.projectId ?? (await state.watchActiveProject().first)?.id;
    if (!mounted) return;
    if (projectId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a project before adding a task.')),
      );
      return;
    }
    final draft = await showCreateWorkItemDialog(context);
    if (!mounted) return;
    if (draft == null) return;
    DateTime? dueAt;
    final rawDate = draft['dueAt'];
    if (rawDate != null && rawDate.isNotEmpty) {
      dueAt = DateTime.tryParse(rawDate);
    }
    await state.addWorkItemToProject(
      projectId,
      draft['title']!,
      description: draft['description'],
      owner: draft['owner'],
      status: normalizeStatusValue(draft['status']),
      priority: normalizePriorityValue(draft['priority']),
      dueAt: dueAt,
      blockedReason: draft['blockedReason'],
      readiness: draft['readiness'] ?? 'ready',
      size: draft['size'] ?? 'medium',
      risk: draft['risk'] ?? 'low_code',
      suggestedActor: draft['suggestedActor'] ?? 'user',
      verificationNeeded: draft['verificationNeeded'] ?? 'none',
      nextAction: draft['nextAction'],
      planningNotes: draft['planningNotes'],
    );
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _openCard(WorkloadCard card) async {
    if (card.isWorkItem) {
      await showWorkItemDetailSheet(context, card.id);
      if (mounted) _reload(clearSelection: false);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(card.title),
        content: SizedBox(
          width: 480,
          child: SelectableText(
            [
              'Project: ${card.projectTitle}',
              'Status: ${card.status}',
              'Priority: ${card.priority}',
              'Readiness: ${card.readiness}',
              'Size: ${card.size}',
              'Risk: ${card.risk}',
              'Actor: ${card.suggestedActor}',
              'Verification: ${card.verificationNeeded}',
              if (card.workItemId != null) 'Work item: ${card.workItemId}',
              if (card.nextAction != null) 'Next action: ${card.nextAction}',
              if (card.blockerReason != null) 'Blocker: ${card.blockerReason}',
              if (card.planningNotes != null) 'Notes: ${card.planningNotes}',
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  List<WorkloadCard> _selectedCards(WorkloadSnapshot snapshot) => snapshot.cards
      .where((card) => _selected.contains(_cardKey(card)))
      .toList(growable: false);

  List<WorkloadItemRef> _selectedRefs(WorkloadSnapshot snapshot) =>
      _selectedCards(
        snapshot,
      ).map(WorkloadItemRef.fromCard).toList(growable: false);

  Future<void> _markReady(WorkloadSnapshot snapshot) async {
    final refs = _selectedRefs(snapshot);
    if (refs.isEmpty) return;
    await AppStateScope.read(context).updateWorkloadPlanning(
      items: refs,
      readiness: 'ready',
      clearBlockerReason: true,
    );
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _markBlocked(WorkloadSnapshot snapshot) async {
    final state = AppStateScope.read(context);
    final refs = _selectedRefs(snapshot);
    if (refs.isEmpty) return;
    final reason = await _promptText(
      title: 'Mark blocked',
      label: 'Blocker reason',
    );
    if (!mounted) return;
    if (reason == null) return;
    await state.updateWorkloadPlanning(
      items: refs,
      readiness: 'blocked',
      blockerReason: reason,
      clearBlockerReason: reason.trim().isEmpty,
    );
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _assignActor(WorkloadSnapshot snapshot) async {
    final state = AppStateScope.read(context);
    final refs = _selectedRefs(snapshot);
    if (refs.isEmpty) return;
    final actor = await _chooseOption(
      title: 'Assign actor',
      values: workloadActorValues,
      initialValue: 'codex',
    );
    if (!mounted) return;
    if (actor == null) return;
    await state.updateWorkloadPlanning(items: refs, suggestedActor: actor);
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _setPlanningFields(WorkloadSnapshot snapshot) async {
    final state = AppStateScope.read(context);
    final refs = _selectedRefs(snapshot);
    if (refs.isEmpty) return;
    final result = await _showPlanningFieldsDialog();
    if (!mounted) return;
    if (result == null) return;
    await state.updateWorkloadPlanning(
      items: refs,
      size: result.size,
      risk: result.risk,
      verificationNeeded: result.verification,
    );
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _markReviewed(WorkloadSnapshot snapshot) async {
    final refs = _selectedRefs(snapshot);
    if (refs.isEmpty) return;
    await AppStateScope.read(context).markWorkloadReviewedToday(refs);
    if (mounted) _reload(clearSelection: true);
  }

  Future<void> _createQueueItems(WorkloadSnapshot snapshot) async {
    final state = AppStateScope.read(context);
    final workItems = _selectedCards(
      snapshot,
    ).where((card) => card.isWorkItem).toList(growable: false);
    if (workItems.isEmpty) return;
    for (final card in workItems) {
      await state.createLlmTaskFromWorkItem(card.id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created ${workItems.length} LLM queue item(s).')),
    );
    _reload(clearSelection: true);
  }

  Future<void> _linkQueueItem(WorkloadSnapshot snapshot) async {
    final selectedWorkItems = _selectedCards(
      snapshot,
    ).where((card) => card.isWorkItem).toList(growable: false);
    if (selectedWorkItems.length != 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select one work item to link.')),
      );
      return;
    }
    final state = AppStateScope.read(context);
    final workItem = selectedWorkItems.single;
    final tasks = await state.getLlmTasksForProject(
      workItem.projectId,
      limit: 100,
    );
    if (!mounted) return;
    final taskId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Link LLM queue item'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: tasks.isEmpty
              ? const Center(
                  child: Text('No LLM queue items for this project.'),
                )
              : ListView.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return ListTile(
                      title: Text(task.title),
                      subtitle: Text('${task.status} - ${task.priority}'),
                      trailing: task.workItemId == workItem.id
                          ? const Text('Linked')
                          : null,
                      onTap: () => Navigator.of(context).pop(task.id),
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
    if (taskId == null) return;
    await state.linkExistingLlmTaskToWorkItem(
      taskId: taskId,
      workItemId: workItem.id,
    );
    if (mounted) _reload(clearSelection: true);
  }

  Future<String?> _promptText({
    required String title,
    required String label,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _chooseOption({
    required String title,
    required List<String> values,
    required String initialValue,
  }) async {
    var selected = initialValue;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: DropdownButtonFormField<String>(
            value: selected,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: values
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(workloadLabel(value)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selected = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selected),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_PlanningFieldResult?> _showPlanningFieldsDialog() async {
    var size = 'small';
    var risk = 'low_code';
    var verification = 'tests';
    return showDialog<_PlanningFieldResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Set planning fields'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DialogDropdown(
                  label: 'Size',
                  value: size,
                  values: workloadSizeValues,
                  onChanged: (value) => setDialogState(() => size = value),
                ),
                const SizedBox(height: 12),
                _DialogDropdown(
                  label: 'Risk',
                  value: risk,
                  values: workloadRiskValues,
                  onChanged: (value) => setDialogState(() => risk = value),
                ),
                const SizedBox(height: 12),
                _DialogDropdown(
                  label: 'Verification',
                  value: verification,
                  values: workloadVerificationValues,
                  onChanged: (value) =>
                      setDialogState(() => verification = value),
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
                _PlanningFieldResult(
                  size: size,
                  risk: risk,
                  verification: verification,
                ),
              ),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FiltersBar extends StatelessWidget {
  final List<Project> projects;
  final WorkloadFilters filters;
  final bool projectScoped;
  final ValueChanged<WorkloadFilters> onChanged;

  const _FiltersBar({
    required this.projects,
    required this.filters,
    required this.projectScoped,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String?>(
                isExpanded: true,
                value: filters.projectId,
                decoration: const InputDecoration(
                  labelText: 'Project',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All projects'),
                  ),
                  ...projects.map(
                    (project) => DropdownMenuItem<String?>(
                      value: project.id,
                      child: Text(
                        project.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: projectScoped
                    ? null
                    : (value) => onChanged(
                        filters.copyWith(
                          projectId: value,
                          clearProjectId: value == null,
                        ),
                      ),
              ),
            ),
            if (projectScoped)
              const Chip(
                avatar: Icon(Icons.lock_outline, size: 16),
                label: Text('Project scoped'),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            _FilterDropdown(
              label: 'Readiness',
              value: filters.readiness,
              values: workloadReadinessValues,
              onChanged: (value) => onChanged(
                filters.copyWith(
                  readiness: value,
                  clearReadiness: value == null,
                ),
              ),
            ),
            _FilterDropdown(
              label: 'Actor',
              value: filters.actor,
              values: workloadActorValues,
              onChanged: (value) => onChanged(
                filters.copyWith(actor: value, clearActor: value == null),
              ),
            ),
            _FilterDropdown(
              label: 'Risk',
              value: filters.risk,
              values: workloadRiskValues,
              onChanged: (value) => onChanged(
                filters.copyWith(risk: value, clearRisk: value == null),
              ),
            ),
            _FilterDropdown(
              label: 'Size',
              value: filters.size,
              values: workloadSizeValues,
              onChanged: (value) => onChanged(
                filters.copyWith(size: value, clearSize: value == null),
              ),
            ),
            FilterChip(
              label: const Text('Blocks progress'),
              selected: filters.blocksProgressOnly,
              onSelected: (value) =>
                  onChanged(filters.copyWith(blocksProgressOnly: value)),
            ),
            FilterChip(
              label: const Text('Review'),
              selected: filters.reviewNeededOnly,
              onSelected: (value) =>
                  onChanged(filters.copyWith(reviewNeededOnly: value)),
            ),
            FilterChip(
              label: const Text('Stale'),
              selected: filters.staleOnly,
              onSelected: (value) =>
                  onChanged(filters.copyWith(staleOnly: value)),
            ),
            FilterChip(
              label: const Text('High priority'),
              selected: filters.highPriorityOnly,
              onSelected: (value) =>
                  onChanged(filters.copyWith(highPriorityOnly: value)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapshotPanel extends StatelessWidget {
  final WorkloadSnapshot snapshot;

  const _SnapshotPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          _SnapshotMetric(label: 'Ready', value: snapshot.readyTasks),
          _SnapshotMetric(
            label: 'Blocked group',
            value: snapshot.blockedBoardGroupTasks,
          ),
          _SnapshotMetric(
            label: 'Blocks progress',
            value: snapshot.blocksProgressTasks,
          ),
          _SnapshotMetric(label: 'Review', value: snapshot.reviewNeededTasks),
          _SnapshotMetric(label: 'Stale', value: snapshot.staleTasks),
          _Breakdown(label: 'Actor', values: snapshot.tasksByActor),
          _Breakdown(label: 'Risk', values: snapshot.tasksByRisk),
          SizedBox(
            width: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Execution candidates',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
                const SizedBox(height: 4),
                if (snapshot.suggestedNextItems.isEmpty)
                  const Text(
                    'No execution candidates match the filters.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  )
                else
                  ...snapshot.suggestedNextItems
                      .take(5)
                      .map(
                        (card) => Text(
                          '${card.projectTitle}: ${card.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
              ],
            ),
          ),
          SizedBox(
            width: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Planning candidates',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                ),
                const SizedBox(height: 4),
                if (snapshot.planningCandidateItems.isEmpty)
                  const Text(
                    'No decision/context candidates match the filters.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  )
                else
                  ...snapshot.planningCandidateItems
                      .take(5)
                      .map(
                        (card) => Text(
                          '${card.projectTitle}: ${card.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BulkPlanningBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback onClear;
  final VoidCallback onMarkReady;
  final VoidCallback onMarkBlocked;
  final VoidCallback onAssignActor;
  final VoidCallback onSetPlanningFields;
  final VoidCallback onReviewed;
  final VoidCallback onCreateQueueItems;
  final VoidCallback onLinkQueueItem;

  const _BulkPlanningBar({
    required this.selectedCount,
    required this.onClear,
    required this.onMarkReady,
    required this.onMarkBlocked,
    required this.onAssignActor,
    required this.onSetPlanningFields,
    required this.onReviewed,
    required this.onCreateQueueItems,
    required this.onLinkQueueItem,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Text(
            selectedCount == 0
                ? 'No cards selected'
                : '$selectedCount selected',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onMarkReady,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Ready'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onMarkBlocked,
                  icon: const Icon(Icons.block, size: 16),
                  label: const Text('Blocked'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onAssignActor,
                  icon: const Icon(Icons.person_search_outlined, size: 16),
                  label: const Text('Actor'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onSetPlanningFields,
                  icon: const Icon(Icons.tune_outlined, size: 16),
                  label: const Text('Plan fields'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onReviewed,
                  icon: const Icon(Icons.event_available_outlined, size: 16),
                  label: const Text('Reviewed'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onCreateQueueItems,
                  icon: const Icon(Icons.playlist_add_outlined, size: 16),
                  label: const Text('Create queue'),
                ),
                OutlinedButton.icon(
                  onPressed: selectedCount == 0 ? null : onLinkQueueItem,
                  icon: const Icon(Icons.link_outlined, size: 16),
                  label: const Text('Link queue'),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Clear selection',
            onPressed: selectedCount == 0 ? null : onClear,
            icon: const Icon(Icons.clear),
          ),
        ],
      ),
    );
  }
}

class _BoardColumn extends StatelessWidget {
  final String title;
  final String group;
  final List<WorkloadCard> cards;
  final Set<String> selectedKeys;
  final void Function(WorkloadCard card, bool selected) onSelectChanged;
  final ValueChanged<WorkloadCard> onOpen;

  const _BoardColumn({
    required this.title,
    required this.group,
    required this.cards,
    required this.selectedKeys,
    required this.onSelectChanged,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final color = _groupColor(group);
    return SizedBox(
      width: 336,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: color.withAlpha(22),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withAlpha(90)),
            ),
            child: Row(
              children: [
                Icon(_groupIcon(group), color: color, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(color: color, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('${cards.length}', style: TextStyle(color: color)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: cards.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'No cards',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    itemCount: cards.length,
                    itemBuilder: (context, index) {
                      final card = cards[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _WorkloadCardTile(
                          card: card,
                          selected: selectedKeys.contains(_cardKey(card)),
                          onSelected: (value) =>
                              onSelectChanged(card, value ?? false),
                          onOpen: () => onOpen(card),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _WorkloadCardTile extends StatelessWidget {
  final WorkloadCard card;
  final bool selected;
  final ValueChanged<bool?> onSelected;
  final VoidCallback onOpen;

  const _WorkloadCardTile({
    required this.card,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: onSelected,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Expanded(
                    child: Text(
                      card.projectTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                  Icon(
                    card.isWorkItem
                        ? Icons.task_alt_outlined
                        : Icons.smart_toy_outlined,
                    size: 15,
                    color: Colors.white38,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                card.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  _ChipText(card.readiness),
                  _ChipText(card.size),
                  _ChipText(card.risk),
                  _ChipText(card.suggestedActor),
                  _ChipText(card.verificationNeeded),
                  _ChipText(card.priority),
                  _ChipText(card.status),
                  if (card.blocksProgress) const _ChipText('blocks progress'),
                  if (card.owner != null) _ChipText(card.owner!),
                  if (card.dueAt != null)
                    _ChipText('${card.dueAt!.month}/${card.dueAt!.day}'),
                  if (card.llmTaskId != null) const _ChipText('LLM queue'),
                  if (card.linkedLlmTaskIds.isNotEmpty)
                    _ChipText('LLM ${card.linkedLlmTaskIds.length}'),
                ],
              ),
              if (card.nextAction != null) ...[
                const SizedBox(height: 8),
                Text(
                  card.nextAction!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
              if (card.blockerReason != null) ...[
                const SizedBox(height: 6),
                Text(
                  card.blockerReason!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> values;
  final ValueChanged<String?> onChanged;

  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        value: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text('All $label', overflow: TextOverflow.ellipsis),
          ),
          ...values.map(
            (value) => DropdownMenuItem<String?>(
              value: value,
              child: Text(
                workloadLabel(value),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _DialogDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  const _DialogDropdown({
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

class _SnapshotMetric extends StatelessWidget {
  final String label;
  final int value;

  const _SnapshotMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 74,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  final String label;
  final Map<String, int> values;

  const _Breakdown({required this.label, required this.values});

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          if (entries.isEmpty)
            const Text(
              'None',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            )
          else
            ...entries
                .take(4)
                .map(
                  (entry) => Text(
                    '${workloadLabel(entry.key)}: ${entry.value}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
        ],
      ),
    );
  }
}

class _ChipText extends StatelessWidget {
  final String label;

  const _ChipText(this.label);

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white12),
        ),
        child: Text(
          workloadLabel(label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.white70),
        ),
      ),
    );
  }
}

class _PlanningFieldResult {
  final String size;
  final String risk;
  final String verification;

  const _PlanningFieldResult({
    required this.size,
    required this.risk,
    required this.verification,
  });
}

String _cardKey(WorkloadCard card) => '${card.kind}:${card.id}';

Color _groupColor(String group) => switch (group) {
  'ready' => Colors.green,
  'needs_decision' => Colors.orange,
  'blocked' => Colors.redAccent,
  'in_progress' => Colors.blue,
  'review_needed' => Colors.purpleAccent,
  'done_closed' => Colors.blueGrey,
  _ => Colors.white54,
};

IconData _groupIcon(String group) => switch (group) {
  'ready' => Icons.check_circle_outline,
  'needs_decision' => Icons.help_outline,
  'blocked' => Icons.block,
  'in_progress' => Icons.play_circle_outline,
  'review_needed' => Icons.rate_review_outlined,
  'done_closed' => Icons.archive_outlined,
  _ => Icons.view_kanban_outlined,
};
