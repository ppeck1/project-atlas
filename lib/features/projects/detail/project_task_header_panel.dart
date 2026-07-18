import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/theme/atlas_colors.dart';
import '../../work/status_priority_helpers.dart';
import 'project_detail_atoms.dart';

class ProjectTaskHeaderActions {
  final Future<void> Function() onAddProjectTask;
  final Future<void> Function() onAddLlmTask;
  final VoidCallback onOpenWorkboard;
  final Future<void> Function() onRefresh;
  final Future<void> Function(WorkItem item) onOpenTask;
  final Future<void> Function(LlmTaskQueueItem item) onOpenLlmTask;
  final Future<void> Function() onManageLlmTasks;

  const ProjectTaskHeaderActions({
    required this.onAddProjectTask,
    required this.onAddLlmTask,
    required this.onOpenWorkboard,
    required this.onRefresh,
    required this.onOpenTask,
    required this.onOpenLlmTask,
    required this.onManageLlmTasks,
  });
}

class ProjectTaskHeaderPanel extends StatelessWidget {
  final List<WorkItem> items;
  final List<LlmTaskQueueItem> llmQueueItems;
  final bool expanded;
  final VoidCallback onToggle;
  final ProjectTaskHeaderActions actions;

  const ProjectTaskHeaderPanel({
    super.key,
    required this.items,
    required this.llmQueueItems,
    required this.expanded,
    required this.onToggle,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final active = items
        .where((item) => !['done', 'archived'].contains(item.status))
        .toList(growable: false);
    final pendingQueue = llmQueueItems
        .where((item) => item.status == 'pending' || item.status == 'leased')
        .toList(growable: false);
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Tasks',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  MiniPill('Project', '${active.length}'),
                  const SizedBox(width: 6),
                  MiniPill('LLM', '${pendingQueue.length}'),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: actions.onRefresh,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: colors.line),
            Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final sections = [
                    _ProjectTaskHeaderSubsection(
                      title: 'Project tasks',
                      icon: Icons.task_alt,
                      actionIcon: Icons.add,
                      actionLabel: 'Add task',
                      onAction: actions.onAddProjectTask,
                      child: _TaskHeaderProjectList(
                        items: active,
                        onOpenTask: actions.onOpenTask,
                        onOpenWorkboard: actions.onOpenWorkboard,
                      ),
                    ),
                    _ProjectTaskHeaderSubsection(
                      title: 'LLM queue',
                      icon: Icons.memory,
                      actionIcon: Icons.add_task,
                      actionLabel: 'Queue task',
                      onAction: actions.onAddLlmTask,
                      child: _TaskHeaderLlmQueueList(
                        items: llmQueueItems,
                        onOpenTask: actions.onOpenLlmTask,
                        onShowAll: actions.onManageLlmTasks,
                      ),
                    ),
                  ];
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: sections[0]),
                        const SizedBox(width: 12),
                        Expanded(child: sections[1]),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      sections[0],
                      const SizedBox(height: 12),
                      sections[1],
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProjectTaskHeaderSubsection extends StatelessWidget {
  final String title;
  final IconData icon;
  final IconData actionIcon;
  final String actionLabel;
  final Future<void> Function() onAction;
  final Widget child;

  const _ProjectTaskHeaderSubsection({
    required this.title,
    required this.icon,
    required this.actionIcon,
    required this.actionLabel,
    required this.onAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 16),
                label: Text(actionLabel),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _TaskHeaderProjectList extends StatelessWidget {
  final List<WorkItem> items;
  final Future<void> Function(WorkItem item) onOpenTask;
  final VoidCallback onOpenWorkboard;

  const _TaskHeaderProjectList({
    required this.items,
    required this.onOpenTask,
    required this.onOpenWorkboard,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text(
        'No open project tasks.',
        style: TextStyle(color: Colors.white38),
      );
    }
    final visible = items.take(5).toList(growable: false);
    return Column(
      children: [
        for (final item in visible)
          _TaskHeaderRow(
            icon: statusFor(item.status).icon,
            iconColor: statusFor(item.status).color,
            title: item.title,
            subtitle: [
              normalizeStatusValue(item.status),
              normalizePriorityValue(item.priority),
              if ((item.owner ?? '').trim().isNotEmpty) item.owner!.trim(),
            ].join(' - '),
            onTap: () => onOpenTask(item),
          ),
        if (items.length > visible.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpenWorkboard,
              icon: const Icon(Icons.view_kanban_outlined, size: 16),
              label: Text('${items.length - visible.length} more'),
            ),
          ),
      ],
    );
  }
}

class _TaskHeaderLlmQueueList extends StatelessWidget {
  final List<LlmTaskQueueItem> items;
  final Future<void> Function(LlmTaskQueueItem item) onOpenTask;
  final Future<void> Function() onShowAll;

  const _TaskHeaderLlmQueueList({
    required this.items,
    required this.onOpenTask,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text(
        'No queued LLM tasks.',
        style: TextStyle(color: Colors.white38),
      );
    }
    final visible = items.take(5).toList(growable: false);
    return Column(
      children: [
        for (final item in visible)
          _TaskHeaderRow(
            icon: llmQueueIcon(item.status),
            iconColor: llmQueueColor(context, item.status),
            title: item.title,
            subtitle: '${item.status} - ${item.priority}',
            onTap: () => onOpenTask(item),
          ),
        if (items.length > visible.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onShowAll,
              icon: const Icon(Icons.list_alt, size: 16),
              label: Text('${items.length - visible.length} more'),
            ),
          ),
      ],
    );
  }
}

class _TaskHeaderRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Future<void> Function()? onTap;

  const _TaskHeaderRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData llmQueueIcon(String status) => switch (status) {
  'leased' => Icons.play_circle_outline,
  'completed' => Icons.check_circle_outline,
  'failed' => Icons.error_outline,
  'cancelled' => Icons.cancel_outlined,
  _ => Icons.schedule,
};

Color llmQueueColor(BuildContext context, String status) => switch (status) {
  'leased' => Theme.of(context).extension<AtlasColors>()!.primary,
  'completed' => const Color(0xFF4CAF50),
  'failed' => const Color(0xFFF44336),
  'cancelled' => const Color(0xFF90A4AE),
  _ => const Color(0xFFFFC107),
};
