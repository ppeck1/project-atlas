import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/project_identity_resolver.dart';

void main() {
  group('ProjectIdentityResolver', () {
    const resolver = ProjectIdentityResolver();

    test(
      'reads capsule metadata and evidence counts without raw content',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'project_identity_resolver_test_',
        );
        try {
          final projectDir = Directory(p.join(root.path, '.project'));
          Directory(
            p.join(projectDir.path, 'runs'),
          ).createSync(recursive: true);
          Directory(
            p.join(projectDir.path, 'atlas_outbox', 'imported'),
          ).createSync(recursive: true);
          Directory(
            p.join(projectDir.path, 'boh_outbox', 'rejected'),
          ).createSync(recursive: true);
          File(
            p.join(projectDir.path, 'project_manifest.json'),
          ).writeAsStringSync(
            jsonEncode({
              'schema_version': '0.2',
              'project_id': 'project-atlas',
              'display_name': 'Project Atlas',
              'root': '.',
              'repo_kind': 'software',
              'visibility': 'public',
              'profiles': ['public_repo', 'software_project'],
              'canonical_docs': {
                'readme': 'README.md',
                'handoff': 'docs/HANDOFF.md',
                'variable_matrix': 'docs/VARIABLE_MATRIX.md',
              },
              'validation': {
                'required': ['flutter analyze'],
                'focused': <String>[],
                'smoke': <String>[],
                'manual': <String>[],
              },
              'protected_paths': <String>[],
              'generated_paths': <String>[],
              'secrets_policy': 'names-only',
              'atlas_sync': {
                'enabled': true,
                'mode': 'outbox',
                'project_key': 'project-atlas',
              },
              'boh_sync': {
                'enabled': true,
                'mode': 'outbox',
                'authority': 'evidence-only',
                'project_key': 'project-atlas',
              },
              'git_policy': {
                'require_git': true,
                'commit_after_signable_run': true,
                'push_policy': 'manual',
                'allow_dirty_unrelated': false,
              },
            }),
          );
          File(p.join(projectDir.path, 'ops_capsule.json')).writeAsStringSync(
            jsonEncode({
              'schema_version': '0.2',
              'capsule_version': '0.2',
              'installed_from': 'test',
              'installed_at': '2026-01-01T00:00:00Z',
              'run_ledger_required': true,
              'repair_iteration_limit': 2,
              'readme_update_mode': 'audit-every-run',
              'variable_matrix_update_mode': 'audit-every-run',
              'handoff_update_mode': 'non-read-only',
              'subagent_policy': 'token-saving-default',
              'profiles': ['public_repo', 'software_project'],
            }),
          );
          File(
            p.join(projectDir.path, 'runs', 'latest.md'),
          ).writeAsStringSync('raw ledger content should not be embedded');
          File(
            p.join(projectDir.path, 'atlas_outbox', 'imported', 'run.json'),
          ).writeAsStringSync('{"summary":"do not embed"}');

          final capsule = await resolver.resolveCapsuleStatus(
            projectId: 'atlas',
            localPath: root.path,
          );
          final identity = await resolver.resolveIdentity(
            projectId: 'atlas',
            title: 'Atlas',
            status: 'active',
            localRegistry: {'id': 'registry-atlas'},
            localPath: root.path,
            repoRoot: root.path,
            githubRemote: {'fullName': 'ppeck1/project-atlas'},
          );

          expect(capsule.evidenceAvailability, 'local_evidence_present');
          expect(capsule.counts['runLedgers'], 1);
          expect(capsule.counts['atlasOutboxImported'], 1);
          expect(capsule.toJson().toString(), isNot(contains('do not embed')));
          expect(identity.capsuleProjectId, 'project-atlas');
          expect(identity.githubRemote!['fullName'], 'ppeck1/project-atlas');
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

    test('reports invalid metadata without throwing', () async {
      final root = await Directory.systemTemp.createTemp(
        'project_identity_resolver_invalid_test_',
      );
      try {
        final projectDir = Directory(p.join(root.path, '.project'));
        projectDir.createSync(recursive: true);
        File(
          p.join(projectDir.path, 'project_manifest.json'),
        ).writeAsStringSync('{not json');

        final capsule = await resolver.resolveCapsuleStatus(
          projectId: 'atlas',
          localPath: root.path,
        );

        expect(capsule.evidenceAvailability, 'metadata_missing');
        expect(capsule.errors.join('\n'), contains('invalid JSON'));
        expect(
          capsule.warnings.join('\n'),
          contains('ops_capsule file is missing'),
        );
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
