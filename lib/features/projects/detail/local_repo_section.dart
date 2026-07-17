import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../shared/models/app_state.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class LocalRepoSection extends StatelessWidget {
  final String projectId;
  final VoidCallback onChooseLocalRepo;
  final VoidCallback onAssociateFile;
  final VoidCallback onAssociateFolder;
  final VoidCallback onPreviewRefresh;
  final VoidCallback onExportBundle;
  final VoidCallback onInspectGit;
  final VoidCallback onRefreshGithub;

  const LocalRepoSection({
    super.key,
    required this.projectId,
    required this.onChooseLocalRepo,
    required this.onAssociateFile,
    required this.onAssociateFolder,
    required this.onPreviewRefresh,
    required this.onExportBundle,
    required this.onInspectGit,
    required this.onRefreshGithub,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return FutureBuilder<ProjectLocalRepoSummary?>(
      future: state.getProjectLocalRepoSummary(projectId),
      builder: (context, registrySnap) {
        final summary = registrySnap.data;
        if (registrySnap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (summary == null) {
          return const SizedBox.shrink();
        }
        final registry = summary.registry;
        if (registry == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This Atlas project is not linked to a local repo folder.',
                style: TextStyle(fontSize: 13, color: Colors.white38),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: onChooseLocalRepo,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add folder'),
              ),
              const SizedBox(height: 12),
              _LocalRepoAssociatedFiles(summary: summary),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onAssociateFile,
                    icon: const Icon(Icons.attach_file, size: 16),
                    label: const Text('Associate file'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onAssociateFolder,
                    icon: const Icon(Icons.folder_copy_outlined, size: 16),
                    label: const Text('Associate folder'),
                  ),
                ],
              ),
            ],
          );
        }
        final observation = summary.observation;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FieldRow(
              label: 'Repo root',
              value: summary.repoRoot,
              placeholder: '',
            ),
            if (summary.repoRoot != registry.localPath) ...[
              Divider(height: 1, color: colors.line.withAlpha(0x44)),
              FieldRow(
                label: 'Selected folder',
                value: registry.localPath,
                placeholder: '',
              ),
            ],
            Divider(height: 1, color: colors.line.withAlpha(0x44)),
            FieldRow(
              label: 'Registry state',
              value: '${registry.classification} - ${registry.reviewState}',
              placeholder: '',
            ),
            if (observation != null) ...[
              Divider(height: 1, color: colors.line.withAlpha(0x44)),
              FieldRow(
                label: 'Last observation',
                value: [
                  if ((observation.branch ?? '').isNotEmpty)
                    'branch ${observation.branch}',
                  if ((observation.headSha ?? '').isNotEmpty)
                    'sha ${shortSha(observation.headSha!)}',
                  if (observation.dirtyCount != null)
                    '${observation.dirtyCount} dirty',
                ].join(' - '),
                placeholder: 'No git facts recorded',
              ),
            ],
            Divider(height: 1, color: colors.line.withAlpha(0x44)),
            FutureBuilder<ProjectGitRemoteStatus?>(
              future: state.getLatestProjectGitRemoteStatus(projectId),
              builder: (context, remoteSnap) {
                final remote = remoteSnap.data;
                if (remoteSnap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  );
                }
                if (remote == null) {
                  return const FieldRow(
                    label: 'GitHub',
                    value: 'No cached GitHub metadata',
                    placeholder: '',
                  );
                }
                final visibility = remote.visibility ?? 'unknown';
                final warning = remote.hasError ? ' - warning saved' : '';
                return Column(
                  children: [
                    FieldRow(
                      label: 'GitHub',
                      value: '${remote.fullName} - $visibility$warning',
                      placeholder: '',
                    ),
                    Divider(height: 1, color: colors.line.withAlpha(0x44)),
                    FieldRow(
                      label: 'Remote check',
                      value: [
                        if ((remote.defaultBranch ?? '').isNotEmpty)
                          'default ${remote.defaultBranch}',
                        if ((remote.onlineHeadSha ?? '').isNotEmpty)
                          'head ${shortSha(remote.onlineHeadSha!)}',
                        'checked ${compactDate(remote.checkedAt)}',
                      ].join(' - '),
                      placeholder: '',
                    ),
                    if (remote.hasError) ...[
                      Divider(height: 1, color: colors.line.withAlpha(0x44)),
                      FieldRow(
                        label: 'GitHub warning',
                        value: remote.error,
                        placeholder: '',
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            _LocalRepoAssociatedFiles(summary: summary),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onPreviewRefresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Reconcile'),
                ),
                OutlinedButton.icon(
                  onPressed: onChooseLocalRepo,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('Replace folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onAssociateFile,
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text('Associate file'),
                ),
                OutlinedButton.icon(
                  onPressed: onAssociateFolder,
                  icon: const Icon(Icons.folder_copy_outlined, size: 16),
                  label: const Text('Associate folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onInspectGit,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Inspect git'),
                ),
                OutlinedButton.icon(
                  onPressed: onRefreshGithub,
                  icon: const Icon(Icons.cloud_sync_outlined, size: 16),
                  label: const Text('Refresh GitHub'),
                ),
                OutlinedButton.icon(
                  onPressed: onExportBundle,
                  icon: const Icon(Icons.archive_outlined, size: 16),
                  label: const Text('Export bundle'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LocalRepoAssociatedFiles extends StatelessWidget {
  final ProjectLocalRepoSummary summary;

  const _LocalRepoAssociatedFiles({required this.summary});

  @override
  Widget build(BuildContext context) {
    final rows = <_AssociatedFileRow>[
      for (final item in summary.refreshItems)
        _AssociatedFileRow(
          icon: _sourceKindIcon(item.sourceKind),
          title: item.sourceKey,
          detail: '${_sourceKindLabel(item.sourceKind)} - ${item.targetType}',
        ),
      for (final doc in summary.documents)
        _AssociatedFileRow(
          icon: Icons.description_outlined,
          title: doc.originalFilename,
          detail: doc.source ?? 'Project document',
        ),
      for (final media in summary.media)
        _AssociatedFileRow(
          icon: _mediaIcon(media.mediaType),
          title: media.originalFilename,
          detail: media.source ?? media.mediaType,
        ),
    ];
    final distinct = <String, _AssociatedFileRow>{};
    for (final row in rows) {
      distinct.putIfAbsent('${row.detail}::${row.title}', () => row);
    }
    final visibleRows = distinct.values.take(8).toList(growable: false);
    final hiddenCount = distinct.length - visibleRows.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MiniPill('Documents', '${summary.documents.length}'),
            MiniPill('Media', '${summary.media.length}'),
            MiniPill('Source files', '${summary.sourceFileCount}'),
            MiniPill('Cards', '${summary.cardCount}'),
          ],
        ),
        const SizedBox(height: 8),
        if (visibleRows.isEmpty)
          const Text(
            'No imported or refresh-tracked files yet.',
            style: TextStyle(fontSize: 13, color: Colors.white38),
          )
        else
          ...visibleRows.map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(row.icon, size: 15, color: Colors.white38),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          row.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (hiddenCount > 0)
          Text(
            '+$hiddenCount more associated file(s)',
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
      ],
    );
  }

  IconData _sourceKindIcon(String sourceKind) {
    return switch (sourceKind) {
      'source_file' => Icons.code,
      'media' => Icons.image_outlined,
      'atlas_card' => Icons.style_outlined,
      'document' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  IconData _mediaIcon(String mediaType) {
    return switch (mediaType) {
      'image' => Icons.image_outlined,
      'video' => Icons.movie_outlined,
      'audio' => Icons.audiotrack_outlined,
      'folder' => Icons.folder_outlined,
      _ => Icons.attach_file,
    };
  }

  String _sourceKindLabel(String sourceKind) {
    return switch (sourceKind) {
      'source_file' => 'Source file',
      'atlas_card' => 'Atlas card',
      'project_meta' => 'Project metadata',
      'work_item' => 'Work item',
      _ => sourceKind.replaceAll('_', ' '),
    };
  }
}

class _AssociatedFileRow {
  final IconData icon;
  final String title;
  final String detail;

  const _AssociatedFileRow({
    required this.icon,
    required this.title,
    required this.detail,
  });
}
