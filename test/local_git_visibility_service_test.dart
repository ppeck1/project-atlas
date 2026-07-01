import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/local_git_visibility_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_git_visibility_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('compares local tracked tree with local remote-tracking ref', () async {
    final remote = Directory(p.join(tempDir.path, 'origin.git'));
    final repo = Directory(p.join(tempDir.path, 'repo'));
    final other = Directory(p.join(tempDir.path, 'other'));
    remote.createSync();
    repo.createSync();

    if (!await _git(remote.path, ['init', '--bare'])) return;
    if (!await _git(repo.path, ['init'])) return;
    await _git(repo.path, ['config', 'user.email', 'atlas@example.invalid']);
    await _git(repo.path, ['config', 'user.name', 'Atlas Test']);
    File(p.join(repo.path, 'README.md')).writeAsStringSync('# Repo\n');
    File(p.join(repo.path, 'shared.txt')).writeAsStringSync('base\n');
    File(p.join(repo.path, '.gitignore')).writeAsStringSync('ignored_dir/\n');
    await _git(repo.path, ['add', 'README.md', 'shared.txt', '.gitignore']);
    if (!await _git(repo.path, ['commit', '-m', 'initial'])) return;
    await _git(repo.path, ['branch', '-M', 'main']);
    await _git(repo.path, ['remote', 'add', 'origin', remote.path]);
    if (!await _git(repo.path, ['push', '-u', 'origin', 'main'])) return;
    await _git(remote.path, ['symbolic-ref', 'HEAD', 'refs/heads/main']);

    File(p.join(repo.path, 'local_only.txt')).writeAsStringSync('local\n');
    await _git(repo.path, ['add', 'local_only.txt']);
    if (!await _git(repo.path, ['commit', '-m', 'local only'])) return;
    File(p.join(repo.path, 'shared.txt')).writeAsStringSync('changed\n');
    File(p.join(repo.path, 'app.log')).writeAsStringSync('runtime\n');
    Directory(p.join(repo.path, 'ignored_dir')).createSync();
    File(
      p.join(repo.path, 'ignored_dir', 'cache.bin'),
    ).writeAsStringSync('ignored\n');

    if (!await _git(tempDir.path, ['clone', remote.path, other.path])) return;
    await _git(other.path, ['config', 'user.email', 'atlas@example.invalid']);
    await _git(other.path, ['config', 'user.name', 'Atlas Test']);
    await _git(other.path, ['switch', 'main']);
    File(p.join(other.path, 'remote_only.txt')).writeAsStringSync('remote\n');
    await _git(other.path, ['add', 'remote_only.txt']);
    if (!await _git(other.path, ['commit', '-m', 'remote only'])) return;
    if (!await _git(other.path, ['push', 'origin', 'main'])) return;
    if (!await _git(repo.path, ['fetch', 'origin'])) return;

    final report = await const LocalGitVisibilityService().inspect(repo.path);

    expect(report.gitRoot, isNotNull);
    expect(report.branch, 'main');
    expect(report.comparisonRef, 'origin/main');
    expect(report.localOnlyTrackedPaths, contains('local_only.txt'));
    expect(report.remoteOnlyTrackedPaths, contains('remote_only.txt'));
    expect(report.changedTrackedPaths, contains('shared.txt'));
    expect(report.untrackedPaths, contains('app.log'));
    expect(report.ignoredPaths, contains('ignored_dir/'));
    expect(report.gitignorePatterns, contains('ignored_dir/'));
    expect(report.suggestedIgnoreEntries, contains('*.log'));
  });

  test('reports non-git folders without throwing', () async {
    final folder = Directory(p.join(tempDir.path, 'plain'))..createSync();

    final report = await const LocalGitVisibilityService().inspect(folder.path);

    expect(report.isGitRepository, isFalse);
    expect(report.warnings, isNotEmpty);
  });
}

Future<bool> _git(String workingDirectory, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory,
  );
  return result.exitCode == 0;
}
