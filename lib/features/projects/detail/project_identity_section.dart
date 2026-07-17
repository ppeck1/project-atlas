import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../services/github_remote_metadata_service.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectIdentitySection extends StatelessWidget {
  final String projectId;
  final Project project;
  final VoidCallback onEdit;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;
  const ProjectIdentitySection({
    super.key,
    required this.projectId,
    required this.project,
    required this.onEdit,
    required this.onReplaceGithub,
    required this.onForgetGithub,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Column(
      children: [
        FieldRow(
          label: 'Purpose',
          value: project.description,
          placeholder: 'Not recorded — click to edit',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        FieldRow(
          label: 'Desired outcome',
          value: project.desiredOutcome,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        FieldRow(
          label: 'Success criteria',
          value: project.successCriteria,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        FieldRow(
          label: 'Scope included',
          value: project.scopeIncluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        FieldRow(
          label: 'Scope excluded',
          value: project.scopeExcluded,
          placeholder: 'Click to edit',
          onEdit: onEdit,
        ),
        Divider(height: 1, color: colors.line.withAlpha(0x44)),
        _GithubIdentityRow(
          projectId: projectId,
          onReplaceGithub: onReplaceGithub,
          onForgetGithub: onForgetGithub,
        ),
      ],
    );
  }
}

class _GithubIdentityRow extends StatelessWidget {
  final String projectId;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;

  const _GithubIdentityRow({
    required this.projectId,
    required this.onReplaceGithub,
    required this.onForgetGithub,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return FutureBuilder<ProjectGitRemoteStatus?>(
      future: state.getLatestProjectGitRemoteStatus(projectId),
      builder: (context, remoteSnap) {
        final remote = remoteSnap.data;
        if (remote != null) {
          final details = [
            'Cached: ${remote.htmlUrl ?? remote.remoteUrl}',
            if ((remote.visibility ?? '').isNotEmpty) remote.visibility!,
            if (remote.hasError) 'warning saved',
          ];
          return _GithubRepositoryControls(
            value: details.join(' - '),
            onReplaceGithub: onReplaceGithub,
            onForgetGithub: onForgetGithub,
            canForget: true,
          );
        }
        if (remoteSnap.connectionState == ConnectionState.waiting) {
          return const FieldRow(
            label: 'GitHub repository',
            value: 'Loading...',
            placeholder: '',
          );
        }
        return FutureBuilder<ProjectObservation?>(
          future: state.getLatestLocalProjectObservation(projectId),
          builder: (context, observationSnap) {
            final identity = GithubRemoteMetadataService.parseGithubRemoteUrl(
              observationSnap.data?.remoteUrl,
            );
            if (identity != null) {
              return _GithubRepositoryControls(
                value: 'Observed origin: ${identity.htmlUrl}',
                onReplaceGithub: onReplaceGithub,
                onForgetGithub: onForgetGithub,
                canForget: false,
              );
            }
            if (observationSnap.connectionState == ConnectionState.waiting) {
              return const FieldRow(
                label: 'GitHub repository',
                value: 'Loading...',
                placeholder: '',
              );
            }
            return _GithubRepositoryControls(
              value: null,
              onReplaceGithub: onReplaceGithub,
              onForgetGithub: onForgetGithub,
              canForget: false,
            );
          },
        );
      },
    );
  }
}

class _GithubRepositoryControls extends StatelessWidget {
  final String? value;
  final VoidCallback onReplaceGithub;
  final VoidCallback onForgetGithub;
  final bool canForget;

  const _GithubRepositoryControls({
    required this.value,
    required this.onReplaceGithub,
    required this.onForgetGithub,
    required this.canForget,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldRow(
          label: 'GitHub repository',
          value: value,
          placeholder: 'No GitHub repository recorded',
        ),
        Padding(
          padding: const EdgeInsets.only(left: 140, bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onReplaceGithub,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Replace GitHub'),
              ),
              OutlinedButton.icon(
                onPressed: canForget ? onForgetGithub : null,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Forget cached'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
