import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/models/project_metadata.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

const _kPhaseColors = <String, Color>{
  'idea': Color(0xFF9C27B0),
  'design': Color(0xFF2196F3),
  'build': Color(0xFFFFC107),
  'test': Color(0xFFFF9800),
  'ship': Color(0xFF4CAF50),
  'stabilize': Color(0xFF607D8B),
};
const _kPriorityColors = <String, Color>{
  'high': Color(0xFFFF9800),
  'urgent': Color(0xFFF44336),
  'low': Color(0xFF607D8B),
};

Color _pc(String? p) => _kPhaseColors[p] ?? const Color(0x61FFFFFF);
Color _prc(String? p) => _kPriorityColors[p] ?? const Color(0x61FFFFFF);

class ProjectQuickBar extends StatelessWidget {
  final Project project;
  final int activeCount, blockedCount, overdueCount, urgentCount;
  final VoidCallback onEditMeta;

  const ProjectQuickBar({
    super.key,
    required this.project,
    required this.activeCount,
    required this.blockedCount,
    required this.overdueCount,
    required this.urgentCount,
    required this.onEditMeta,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Pill(
                label: projectStatusLabel(project.status),
                color: projectStatusColor(project.status),
                tooltip:
                    '${projectStatusDescriptor(project.status)}: '
                    '${projectStatusDescription(project.status)}',
              ),
              if (normalizeProjectCategory(project.category) != null) ...[
                const SizedBox(width: 6),
                Pill(
                  label: projectCategoryLabel(project.category),
                  color: const Color(0xFF00BCD4),
                ),
              ],
              if ((project.phase ?? '').isNotEmpty) ...[
                const SizedBox(width: 6),
                Pill(label: project.phase!, color: _pc(project.phase)),
              ],
              if ((project.priority ?? '').isNotEmpty &&
                  project.priority != 'normal') ...[
                const SizedBox(width: 6),
                Pill(label: project.priority!, color: _prc(project.priority)),
              ],
              if ((project.owner ?? '').isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  'Owner: ${project.owner}',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: onEditMeta,
                style: TextButton.styleFrom(
                  backgroundColor: colors.primary.withAlpha(26),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: colors.primary.withAlpha(0x33)),
                  ),
                ),
                child: Text(
                  'Edit metadata',
                  style: TextStyle(fontSize: 11, color: colors.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MetricCard(
                label: 'Open',
                value: activeCount,
                color: const Color(0xFF448AFF),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Blocked',
                value: blockedCount,
                color: const Color(0xFF9C27B0),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Overdue',
                value: overdueCount,
                color: const Color(0xFFF44336),
              ),
              const SizedBox(width: 8),
              _MetricCard(
                label: 'Urgent',
                value: urgentCount,
                color: const Color(0xFFFF6D00),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _MetricCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: colors.bg,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: value > 0 ? color : Colors.white24,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
