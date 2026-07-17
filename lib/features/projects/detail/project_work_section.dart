import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/theme/atlas_colors.dart';
import '../../today/work_item_detail_sheet.dart';
import '../../work/status_priority_helpers.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectWorkSection extends StatelessWidget {
  final String projectId;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;
  final Future<void> Function() onAddProjectTask;
  final Future<void> Function() onOpenWorkboard;

  const ProjectWorkSection({
    super.key,
    required this.projectId,
    required this.items,
    required this.onChanged,
    required this.onAddProjectTask,
    required this.onOpenWorkboard,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<WorkItem>>{
      for (final status in ['inbox', 'next', 'doing', 'waiting', 'done'])
        status: [],
    };
    for (final item in items) {
      final key = normalizeStatusValue(item.status);
      grouped.putIfAbsent(key, () => <WorkItem>[]).add(item);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tasks here are scoped to this project. Click any task to open the full detail sheet.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
            FilledButton.icon(
              onPressed: onAddProjectTask,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add project task'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onOpenWorkboard,
              icon: const Icon(Icons.view_kanban_outlined, size: 16),
              label: const Text('Open full board'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Text(
            'No tasks in this project yet.',
            style: TextStyle(color: Colors.white24),
          )
        else
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 12,
            runSpacing: 12,
            children: grouped.entries
                .where((entry) => entry.value.isNotEmpty)
                .map(
                  (entry) => _ProjectStatusColumn(
                    status: entry.key,
                    items: entry.value,
                    onChanged: onChanged,
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _ProjectStatusColumn extends StatelessWidget {
  final String status;
  final List<WorkItem> items;
  final Future<void> Function() onChanged;

  const _ProjectStatusColumn({
    required this.status,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final opt = statusFor(status);
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(opt.icon, size: 14, color: opt.color),
                const SizedBox(width: 6),
                Text(
                  opt.label,
                  style: TextStyle(
                    color: opt.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length}',
                  style: const TextStyle(color: Colors.white38),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      normalizePriorityValue(item.priority),
                      if ((item.owner ?? '').isNotEmpty) item.owner!,
                      if (item.dueAt != null)
                        '${item.dueAt!.month}/${item.dueAt!.day}',
                    ].join(' - '),
                  ),
                  onTap: () async {
                    await showWorkItemDetailSheet(context, item.id);
                    await onChanged();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
