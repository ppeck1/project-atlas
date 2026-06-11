import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../shared/widgets/create_project_dialog.dart';

// Design token color maps
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

Color _statusColor(String? s) => _kStatusColors[s] ?? const Color(0x61FFFFFF);
Color _phaseColor(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);

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
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final projects = snap.data ?? const <Project>[];
          if (projects.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open, size: 48, color: Colors.white38),
                    SizedBox(height: 16),
                    Text('No projects yet.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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

          return StreamBuilder<Project?>(
            stream: state.watchActiveProject(),
            builder: (context, activeSnap) {
              final activeId = activeSnap.data?.id;
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: projects.length,
                itemBuilder: (context, i) {
                  final p = projects[i];
                  final isActive = p.id == activeId;
                  final statusColor = _statusColor(p.status);
                  final phaseColor = _phaseColor(p.phase);
                  final hasPhase = (p.phase ?? '').isNotEmpty;
                  final hasDesc = (p.description ?? '').isNotEmpty;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        await state.setActiveById(p.id);
                        if (context.mounted) context.go('/projects/${p.id}');
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151A22),
                          border: Border.all(
                            color: isActive ? const Color(0x4479A7FF) : const Color(0xFF273044),
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Folder icon
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: isActive ? const Color(0x2679A7FF) : const Color(0x10FFFFFF),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                isActive ? Icons.folder_open : Icons.folder_outlined,
                                size: 18,
                                color: isActive ? const Color(0xFF79A7FF) : Colors.white38,
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Content
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          p.title,
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      if (isActive)
                                        Container(
                                          margin: const EdgeInsets.only(left: 8),
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0x2679A7FF),
                                            border: Border.all(color: const Color(0x4D79A7FF)),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'ACTIVE',
                                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF79A7FF)),
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (hasDesc) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      p.description!,
                                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      _Pill(label: p.status, color: statusColor),
                                      if (hasPhase) ...[
                                        const SizedBox(width: 6),
                                        _Pill(label: p.phase!, color: phaseColor),
                                      ],
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
                },
              );
            },
          );
        },
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
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
