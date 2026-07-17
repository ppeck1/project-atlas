import 'package:flutter/material.dart';

import '../../../services/local_git_visibility_service.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class GitVisibilityDialog extends StatelessWidget {
  final LocalGitVisibilityReport report;

  const GitVisibilityDialog({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final sha = report.headSha;
    final shortSha = sha == null
        ? null
        : sha.length <= 8
        ? sha
        : sha.substring(0, 8);
    return AlertDialog(
      backgroundColor: colors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.line),
      ),
      title: const Text('Git visibility'),
      content: SizedBox(
        width: 780,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              report.gitRoot ?? report.requestedPath,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MiniPill('Branch', report.branch ?? 'unknown'),
                MiniPill('HEAD', shortSha ?? 'unknown'),
                MiniPill('Compare', report.comparisonRef ?? 'none'),
                MiniPill(
                  'Remote',
                  report.remoteUrl == null ? 'none' : 'origin',
                ),
                MiniPill('Tracked', '${report.localTrackedCount}'),
                MiniPill('Remote files', '${report.remoteTrackedCount}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _GitMetric(
                  label: 'Local only',
                  value: report.localOnlyTrackedCount,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Remote only',
                  value: report.remoteOnlyTrackedCount,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Changed',
                  value: report.changedTrackedCount,
                  color: Colors.amber,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Untracked',
                  value: report.untrackedCount,
                  color: Colors.purpleAccent,
                ),
                const SizedBox(width: 8),
                _GitMetric(
                  label: 'Ignored',
                  value: report.ignoredCount,
                  color: Colors.greenAccent,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  _GitPathGroup(
                    title: 'Local tracked not in compare ref',
                    paths: report.localOnlyTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Compare ref not in local tracked tree',
                    paths: report.remoteOnlyTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Changed tracked files',
                    paths: report.changedTrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Untracked files',
                    paths: report.untrackedPaths,
                  ),
                  _GitPathGroup(
                    title: 'Ignored files',
                    paths: report.ignoredPaths,
                  ),
                  _GitPathGroup(
                    title: 'Suggested .gitignore entries',
                    paths: report.suggestedIgnoreEntries,
                  ),
                  if (report.warnings.isNotEmpty)
                    _GitPathGroup(title: 'Warnings', paths: report.warnings),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _GitMetric extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _GitMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          border: Border.all(color: color.withAlpha(58)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const Spacer(),
            Text(
              '$value',
              style: TextStyle(
                color: color,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GitPathGroup extends StatelessWidget {
  final String title;
  final List<String> paths;

  const _GitPathGroup({required this.title, required this.paths});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(title, style: const TextStyle(fontSize: 13)),
          trailing: MiniPill('Count', '${paths.length}'),
          initiallyExpanded: paths.isNotEmpty && paths.length <= 8,
          children: [
            if (paths.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'None',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              )
            else
              for (final path in paths.take(80))
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    path,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
            if (paths.length > 80)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${paths.length - 80} more',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
