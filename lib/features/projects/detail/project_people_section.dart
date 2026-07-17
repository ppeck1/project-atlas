import 'package:flutter/material.dart';

import '../../../db/app_db.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectPeopleSection extends StatelessWidget {
  final List<ProjectPerson> people;
  final VoidCallback onAdd;
  final ValueChanged<ProjectPerson> onEdit;
  final ValueChanged<ProjectPerson> onDelete;

  const ProjectPeopleSection({
    super.key,
    required this.people,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No people records yet.',
              style: TextStyle(fontSize: 13, color: Colors.white24),
            ),
          ),
        ...people.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 16,
                  color: Colors.white38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        [
                          if ((p.role ?? '').isNotEmpty) p.role!,
                          if ((p.authority ?? '').isNotEmpty) p.authority!,
                        ].join(' · '),
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
                    Icons.edit_outlined,
                    size: 14,
                    color: Colors.white24,
                  ),
                  onPressed: () => onEdit(p),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0x80F44336),
                  ),
                  onPressed: () => onDelete(p),
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
          icon: const Icon(Icons.person_add_outlined, size: 16),
          label: const Text('Add person'),
        ),
      ],
    );
  }
}
