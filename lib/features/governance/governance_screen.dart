import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/contact_picker.dart';
import '../today/work_item_detail_sheet.dart';

class GovernanceScreen extends StatefulWidget {
  const GovernanceScreen({super.key});

  @override
  State<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends State<GovernanceScreen> {
  Stream<List<Project>>? _projects;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _projects ??= AppStateScope.of(context).watchProjects();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Project>>(
      stream: _projects,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final projects = snap.data ?? const <Project>[];

        if (projects.isEmpty) {
          return const Center(
            child: Text('No projects yet. Create one in Projects.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: projects.length,
          itemBuilder: (context, i) {
            final p = projects[i];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _ProjectGovernancePanel(project: p),
              ),
            );
          },
        );
      },
    );
  }
}

class _ProjectGovernancePanel extends StatefulWidget {
  final Project project;
  const _ProjectGovernancePanel({required this.project});

  @override
  State<_ProjectGovernancePanel> createState() =>
      _ProjectGovernancePanelState();
}

class _ProjectGovernancePanelState extends State<_ProjectGovernancePanel> {
  Stream<List<Stage>>? _stages;
  String? _stagesProjectId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_stagesProjectId != widget.project.id) {
      _stagesProjectId = widget.project.id;
      _stages = AppStateScope.of(context).watchStagesForProject(
        widget.project.id,
      );
    }
  }

  @override
  void didUpdateWidget(_ProjectGovernancePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id) {
      _stagesProjectId = widget.project.id;
      _stages = AppStateScope.of(context).watchStagesForProject(
        widget.project.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.project.title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),

        StreamBuilder<List<Stage>>(
          stream: _stages,
          builder: (context, stageSnap) {
            if (stageSnap.connectionState == ConnectionState.waiting &&
                stageSnap.data == null) {
              return const SizedBox.shrink();
            }
            final stages = stageSnap.data ?? const <Stage>[];
            if (stages.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No stages yet.'),
              );
            }

            return Column(
              children: [
                for (final s in stages)
                  _StageWorkSection(project: widget.project, stage: s),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StageWorkSection extends StatefulWidget {
  final Project project;
  final Stage stage;

  const _StageWorkSection({required this.project, required this.stage});

  @override
  State<_StageWorkSection> createState() => _StageWorkSectionState();
}

class _StageWorkSectionState extends State<_StageWorkSection> {
  Stream<List<WorkItem>>? _workItems;
  String? _workItemsStageId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_workItemsStageId != widget.stage.id) {
      _workItemsStageId = widget.stage.id;
      _workItems = AppStateScope.of(context).watchWorkItemsForStage(
        widget.stage.id,
      );
    }
  }

  @override
  void didUpdateWidget(_StageWorkSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stage.id != widget.stage.id) {
      _workItemsStageId = widget.stage.id;
      _workItems = AppStateScope.of(context).watchWorkItemsForStage(
        widget.stage.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text('${widget.stage.position + 1}. ${widget.stage.title}'),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        children: [
          StreamBuilder<List<WorkItem>>(
            stream: _workItems,
            builder: (context, workSnap) {
              if (workSnap.connectionState == ConnectionState.waiting &&
                  workSnap.data == null) {
                return const SizedBox.shrink();
              }
              final items = workSnap.data ?? const <WorkItem>[];
              if (items.isEmpty) {
                return const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No work items in this stage.'),
                  ),
                );
              }

              return Column(
                children: [
                  for (final item in items)
                    _WorkRow(
                      project: widget.project,
                      stage: widget.stage,
                      item: item,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WorkRow extends StatefulWidget {
  final Project project;
  final Stage stage;
  final WorkItem item;

  const _WorkRow({
    required this.project,
    required this.stage,
    required this.item,
  });

  @override
  State<_WorkRow> createState() => _WorkRowState();
}

class _WorkRowState extends State<_WorkRow> {
  Stream<String?>? _workOwner;
  String? _workOwnerItemId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_workOwnerItemId != widget.item.id) {
      _workOwnerItemId = widget.item.id;
      _workOwner = AppStateScope.of(context).watchWorkOwner(widget.item.id);
    }
  }

  @override
  void didUpdateWidget(_WorkRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _workOwnerItemId = widget.item.id;
      _workOwner = AppStateScope.of(context).watchWorkOwner(widget.item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: () => showWorkItemDetailSheet(context, widget.item.id),
      leading: Checkbox(
        value: widget.item.completed,
        onChanged: (_) => state.toggleWorkDone(widget.item.id),
      ),
      title: Text(
        widget.item.title,
        style: widget.item.completed
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: StreamBuilder<String?>(
        stream: _workOwner,
        builder: (context, snap) {
          final owner = (snap.data ?? '').trim();
          return Text(owner.isEmpty ? 'Owner: —' : 'Owner: $owner');
        },
      ),
      trailing: IconButton(
        tooltip: 'Set owner',
        icon: const Icon(Icons.person_outline),
        onPressed: () async {
          final current = await state.db.getWorkOwner(widget.item.id);
          if (!context.mounted) return;
          final next = await _promptOwner(context, current);
          if (next == null) return; // cancelled
          await state.setWorkOwner(widget.item.id, next);
        },
      ),
    );
  }

  Future<String?> _promptOwner(BuildContext context, String? current) async {
    final c = TextEditingController(text: current ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, _) => AlertDialog(
          title: const Text('Set owner'),
          content: SizedBox(
            width: 360,
            child: ContactOwnerField(controller: c, label: 'Owner'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    c.dispose();
    return result;
  }
}
