import 'package:flutter/material.dart';

import '../../../db/app_db.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectRisksSection extends StatelessWidget {
  final List<ProjectRisk> risks;
  final VoidCallback onAdd;
  final ValueChanged<ProjectRisk> onDelete;

  const ProjectRisksSection({
    super.key,
    required this.risks,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (risks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No risks recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...risks.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((r.desc ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            r.desc!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      Text(
                        'Severity: ${r.severity}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(r),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add risk'),
        ),
      ],
    );
  }
}
