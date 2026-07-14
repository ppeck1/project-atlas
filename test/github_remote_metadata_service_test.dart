import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/github_remote_metadata_service.dart';

void main() {
  test('parseGithubRemoteUrl handles common GitHub remote forms', () {
    final https = GithubRemoteMetadataService.parseGithubRemoteUrl(
      'https://github.com/ppeck1/project-atlas.git',
    );
    final ssh = GithubRemoteMetadataService.parseGithubRemoteUrl(
      'git@github.com:ppeck1/project-atlas.git',
    );
    final credentialed = GithubRemoteMetadataService.parseGithubRemoteUrl(
      'https://token@github.com/ppeck1/project-atlas.git',
    );
    final nonGithub = GithubRemoteMetadataService.parseGithubRemoteUrl(
      'https://gitlab.com/ppeck1/project-atlas.git',
    );

    expect(https?.owner, 'ppeck1');
    expect(https?.repo, 'project-atlas');
    expect(ssh?.owner, 'ppeck1');
    expect(ssh?.repo, 'project-atlas');
    expect(credentialed?.remoteUrl, isNot(contains('token@')));
    expect(nonGithub, isNull);
  });

  test('fetch returns GitHub metadata from fake gh api responses', () async {
    final service = GithubRemoteMetadataService(
      runner: (args) async {
        final endpoint = args[1];
        if (endpoint.endsWith('/commits/main')) {
          return ProcessResult(1, 0, 'abc123\n', '');
        }
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'private': false,
            'fork': false,
            'archived': false,
            'visibility': 'public',
            'default_branch': 'main',
            'html_url': 'https://github.com/ppeck1/project-atlas',
            'updated_at': '2026-06-29T12:00:00Z',
            'pushed_at': '2026-06-29T13:00:00Z',
          }),
          '',
        );
      },
    );

    final result = await service.fetch(
      const GithubRemoteIdentity(
        owner: 'ppeck1',
        repo: 'project-atlas',
        remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
      ),
    );

    expect(result.error, isNull);
    expect(result.visibility, 'public');
    expect(result.defaultBranch, 'main');
    expect(result.onlineHeadSha, 'abc123');
    expect(result.isPrivate, isFalse);
    expect(result.remoteUpdatedAt, isNotNull);
    expect(result.remotePushedAt, isNotNull);
  });

  test(
    'fetch preserves inaccessible repo errors as metadata results',
    () async {
      final service = GithubRemoteMetadataService(
        runner: (_) async => ProcessResult(1, 1, '', 'not found'),
      );

      final result = await service.fetch(
        const GithubRemoteIdentity(
          owner: 'example-owner',
          repo: 'private-repository',
          remoteUrl: 'https://github.com/example-owner/private-repository.git',
        ),
      );

      expect(result.hasError, isTrue);
      expect(result.error, contains('not found'));
      expect(result.visibility, isNull);
    },
  );
}
