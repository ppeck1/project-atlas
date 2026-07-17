import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectClosureSection extends StatelessWidget {
  final Project project;
  final VoidCallback onEdit, onComplete, onArchive;

  const ProjectClosureSection({
    super.key,
    required this.project,
    required this.onEdit,
    required this.onComplete,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldRow(
          label: 'Outcome summary',
          value: project.outcomeSummary,
          placeholder: 'Not closed yet',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        FieldRow(
          label: 'Lessons learned',
          value: project.lessonsLearned,
          placeholder: 'Not recorded',
          onEdit: onEdit,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onComplete,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('Complete project'),
            ),
            OutlinedButton.icon(
              onPressed: onArchive,
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: const Text('Archive'),
            ),
          ],
        ),
      ],
    );
  }
}
