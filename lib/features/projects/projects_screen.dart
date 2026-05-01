import 'package:flutter/material.dart';
import '../../shared/models/app_state_scope.dart';
import 'package:go_router/go_router.dart';
import '../../app/app.dart';
import '../../db/app_db.dart';
import '../../shared/widgets/create_project_dialog.dart';

class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

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
              if (title != null) await state.createProject(title);
            },
            icon: const Icon(Icons.add),
            label: const Text('New project'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<List<Project>>(
          stream: state.watchProjects(),
          builder: (context, snap) {
            final projects = snap.data ?? const [];
            if (projects.isEmpty) {
              return const Center(child: Text('No projects yet.'));
            }

            return StreamBuilder<Project?>(
              stream: state.watchActiveProject(),
              builder: (context, activeSnap) {
                final activeId = activeSnap.data?.id;

                return ListView.separated(
                  itemCount: projects.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = projects[i];
                    final isActive = p.id == activeId;

                    return ListTile(
                      title: Text(p.title),
                      subtitle: Text('Created ${p.createdAt.toLocal()}'),
                      trailing: isActive ? const Icon(Icons.check_circle) : null,
                      selected: isActive,
                      onTap: () async {
                        await state.setActiveById(p.id);
                        if (context.mounted) context.go('/work');
                      },
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
}


