import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/github_archive_service.dart';
import 'package:project_atlas/services/github_remote_metadata_service.dart';

void main() {
  const identity = GithubRemoteIdentity(
    owner: 'octo-org',
    repo: 'atlas-demo',
    remoteUrl: 'https://github.com/octo-org/atlas-demo.git',
  );

  group('GithubArchiveService.publicArchiveUri', () {
    test('builds a codeload zip URI for owner/repo/ref', () {
      final uri = GithubArchiveService.publicArchiveUri(identity, 'main');
      expect(uri.scheme, 'https');
      expect(uri.host, 'codeload.github.com');
      expect(uri.path, '/octo-org/atlas-demo/zip/main');
    });

    test('trims the ref before building the URI', () {
      final uri = GithubArchiveService.publicArchiveUri(identity, '  abc123  ');
      expect(uri.path, '/octo-org/atlas-demo/zip/abc123');
    });

    test('accepts a commit sha ref', () {
      final uri = GithubArchiveService.publicArchiveUri(
        identity,
        'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
      expect(
        uri.toString(),
        'https://codeload.github.com/octo-org/atlas-demo/zip/'
        'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
    });

    test('throws StateError for a blank ref', () {
      expect(
        () => GithubArchiveService.publicArchiveUri(identity, '   '),
        throwsStateError,
      );
    });
  });
}
