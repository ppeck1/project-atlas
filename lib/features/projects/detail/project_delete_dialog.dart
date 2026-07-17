import 'package:flutter/material.dart';

import '../../../shared/theme/atlas_colors.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectDeleteDialog extends StatefulWidget {
  final String projectTitle;
  final ValueChanged<String> onConfirm;
  final VoidCallback onClose;

  const ProjectDeleteDialog({
    super.key,
    required this.projectTitle,
    required this.onConfirm,
    required this.onClose,
  });

  @override
  State<ProjectDeleteDialog> createState() => _ProjectDeleteDialogState();
}

class _ProjectDeleteDialogState extends State<ProjectDeleteDialog> {
  final _ctrl = TextEditingController();
  bool _attempted = false;
  int _charCount = 0;

  bool get _valid => _charCount >= 20;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(
      () => setState(() => _charCount = _ctrl.text.trim().length),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return AlertDialog(
      backgroundColor: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.line),
      ),
      title: const Text(
        'Delete project permanently?',
        style: TextStyle(color: Color(0xFFF44336), fontSize: 16),
      ),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently remove "${widget.projectTitle}" from Project Atlas. '
              'Your deletion reason will be saved locally. Project documents are detached, not deleted.',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.white70,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText:
                    'Deletion reason (min 20 characters — $_charCount/20)',
                hintText: 'Describe why this project is being deleted…',
              ),
            ),
            if (_attempted && !_valid) ...[
              const SizedBox(height: 6),
              const Text(
                'Please enter at least 20 characters before deleting.',
                style: TextStyle(fontSize: 12, color: Color(0xFFF44336)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onClose, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            setState(() => _attempted = true);
            if (_valid) widget.onConfirm(_ctrl.text.trim());
          },
          style: FilledButton.styleFrom(
            backgroundColor: _valid
                ? const Color(0xFFF44336)
                : const Color(0x4DF44336),
            foregroundColor: _valid ? Colors.white : const Color(0x80FFFFFF),
          ),
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
