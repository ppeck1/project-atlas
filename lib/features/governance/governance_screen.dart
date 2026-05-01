import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';

class GovernanceScreen extends StatelessWidget {
  const GovernanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return StreamBuilder<List<Project>>(
      stream: state.watchProjects(),
      builder: (context, snap) {
        final projects = snap.data ?? const <Project>[];

        if (projects.isEmpty) {
          return const Center(child: Text('No projects yet. Create one in Projects.'));
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

class _ProjectGovernancePanel extends StatelessWidget {
  final Project project;
  const _ProjectGovernancePanel({required this.project});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(project.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),

        StreamBuilder<List<Stage>>(
          stream: state.watchStagesForProject(project.id),
          builder: (context, stageSnap) {
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
                  _StageWorkSection(project: project, stage: s),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StageWorkSection extends StatelessWidget {
  final Project project;
  final Stage stage;

  const _StageWorkSection({
    required this.project,
    required this.stage,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        initiallyExpanded: false,
        title: Text('${stage.position + 1}. ${stage.title}'),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        children: [
          StreamBuilder<List<WorkItem>>(
            stream: state.watchWorkItemsForStage(stage.id),
            builder: (context, workSnap) {
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
                    _WorkRow(project: project, stage: stage, item: item),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WorkRow extends StatelessWidget {
  final Project project;
  final Stage stage;
  final WorkItem item;

  const _WorkRow({
    required this.project,
    required this.stage,
    required this.item,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: item.completed,
        onChanged: (_) => state.toggleWorkDone(item.id),
      ),
      title: Text(
        item.title,
        style: item.completed
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: StreamBuilder<String?>(
        stream: state.watchWorkOwner(item.id),
        builder: (context, snap) {
          final owner = (snap.data ?? '').trim();
          return Text(owner.isEmpty ? 'Owner: —' : 'Owner: $owner');
        },
      ),
      trailing: IconButton(
        tooltip: 'Set owner',
        icon: const Icon(Icons.person_outline),
        onPressed: () async {
          final current = await state.db.getWorkOwner(item.id);
          final next = await _promptOwner(context, current);
          if (next == null) return; // cancelled
          await state.setWorkOwner(item.id, next);
        },
      ),
    );
  }

  Future<String?> _promptOwner(BuildContext context, String? current) async {
    final c = TextEditingController(text: current ?? '');
    return showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set owner'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(
              hintText: 'e.g., Paul / Kristie / Vendor / Team',
            ),
            autofocus: true,
            onSubmitted: (_) => Navigator.of(context).pop(c.text.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(c.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
}
