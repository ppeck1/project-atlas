import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

Color _tagColor(Tag tag, AtlasColors colors) {
  final raw = tag.color;
  if (raw != null && raw.startsWith('#') && raw.length == 7) {
    final parsed = int.tryParse(raw.substring(1), radix: 16);
    if (parsed != null) return Color(0xFF000000 | parsed);
  }
  return colors.primary;
}

class ProjectTagsSection extends StatefulWidget {
  final String projectId;
  final VoidCallback onEdit;

  const ProjectTagsSection({
    super.key,
    required this.projectId,
    required this.onEdit,
  });

  @override
  State<ProjectTagsSection> createState() => _ProjectTagsSectionState();
}

class _ProjectTagsSectionState extends State<ProjectTagsSection> {
  Stream<List<Tag>>? _watchTags;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchTags ??=
        AppStateScope.of(context).watchTagsForProject(widget.projectId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return StreamBuilder<List<Tag>>(
      stream: _watchTags,
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Error loading tags: ${snap.error}',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          );
        }
        final tags = snap.data ?? const <Tag>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tags.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'No tags assigned yet.',
                  style: TextStyle(fontSize: 13, color: Colors.white38),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in tags)
                      Pill(
                        label: '#${tag.name}',
                        color: _tagColor(tag, colors),
                      ),
                  ],
                ),
              ),
            OutlinedButton.icon(
              onPressed: widget.onEdit,
              icon: const Icon(Icons.sell_outlined, size: 16),
              label: const Text('Edit tags'),
            ),
          ],
        );
      },
    );
  }
}
