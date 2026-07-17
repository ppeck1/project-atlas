import 'package:flutter/material.dart';

import '../../../db/app_db.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectDecisionsSection extends StatelessWidget {
  final List<ProjectDecision> decisions;
  final VoidCallback onAdd;
  final ValueChanged<ProjectDecision> onDelete;

  const ProjectDecisionsSection({
    super.key,
    required this.decisions,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (decisions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No decisions recorded yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...decisions.map(
          (d) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((d.ctx ?? '').isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            d.ctx!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                              height: 1.4,
                            ),
                          ),
                        ),
                      if ((d.decider ?? '').isNotEmpty)
                        Text(
                          'By: ${d.decider}',
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
                  onPressed: () => onDelete(d),
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
          label: const Text('Log decision'),
        ),
      ],
    );
  }
}
