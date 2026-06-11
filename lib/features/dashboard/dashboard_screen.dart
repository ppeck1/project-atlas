import 'package:flutter/material.dart';
import '../../shared/models/app_state_scope.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart'; // Project model

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/projects'),
            icon: const Icon(Icons.folder_open),
            label: const Text('Projects'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<Project>>(
        stream: state.watchProjects(),
        builder: (context, projSnap) {
          final projects = projSnap.data ?? const <Project>[];

          return StreamBuilder<Project?>(
            stream: state.watchActiveProject(),
            builder: (context, activeSnap) {
              final active = activeSnap.data;

              if (projects.isEmpty) {
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'No projects yet',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Create a project to start tracking work.',
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                FilledButton.icon(
                                  onPressed: () => context.go('/projects'),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Create / Select Project'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _ActiveHeader(active: active),
                  const SizedBox(height: 16),
                  const Text(
                    'All Projects',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  ...projects.map((p) {
                    final isActive = active?.id == p.id;
                    return _ProjectCard(
                      project: p,
                      isActive: isActive,
                      onSetActive: () async {
                        await state.setActiveById(p.id);
                        // Optional: keep user in dashboard, or jump them to Work
                        // context.go('/work');
                      },
                    );
                  }),
                  const SizedBox(height: 12),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _ActiveHeader extends StatelessWidget {
  final Project? active;
  const _ActiveHeader({required this.active});

  @override
  Widget build(BuildContext context) {
    if (active == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.info_outline),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'No active project selected. Go to Projects to pick one.',
                ),
              ),
              TextButton(
                onPressed: () => context.go('/projects'),
                child: const Text('Select'),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Active Project',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active!.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: () => context.go('/work'),
              icon: const Icon(Icons.view_kanban_outlined),
              label: const Text('Open Work'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  final bool isActive;
  final VoidCallback onSetActive;

  const _ProjectCard({
    required this.project,
    required this.isActive,
    required this.onSetActive,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(isActive ? Icons.star : Icons.folder_outlined),
        title: Text(
          project.title,
          style: TextStyle(
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        subtitle: Text('ID: ${project.id}'),
        trailing: isActive
            ? const Chip(label: Text('Active'))
            : TextButton(
                onPressed: onSetActive,
                child: const Text('Set Active'),
              ),
        onTap: isActive ? () => context.go('/work') : onSetActive,
      ),
    );
  }
}
