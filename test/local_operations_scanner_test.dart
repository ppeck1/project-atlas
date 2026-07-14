import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/local_operations_scanner.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_ops_scan_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('classifies marker-rich local project candidates', () async {
    final project = Directory(p.join(tempDir.path, 'sample_app'))
      ..createSync(recursive: true);
    File(p.join(project.path, 'README.md')).writeAsStringSync('# Sample');
    File(p.join(project.path, 'package.json')).writeAsStringSync('{}');

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 2,
    ).scan();

    final observed = result.observations.singleWhere(
      (item) => item.displayName == 'sample_app',
    );
    expect(observed.classificationGuess, 'active_project');
    expect(observed.markerFiles, contains('README.md'));
    expect(observed.markerFiles, contains('package.json'));
  });

  test('classifies project manifest folders as active projects', () async {
    final project = Directory(p.join(tempDir.path, 'manifest_project'))
      ..createSync(recursive: true);
    Directory(p.join(project.path, '.project')).createSync();
    File(
      p.join(project.path, '.project', 'runtime_manifest.json'),
    ).writeAsStringSync('{"name":"Manifest Project"}');

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 2,
    ).scan();

    final observed = result.observations.singleWhere(
      (item) => item.displayName == 'manifest_project',
    );
    expect(observed.classificationGuess, 'active_project');
    expect(observed.markerFiles, contains('.project'));
  });

  test('skips excluded folders and does not read secret-like files', () async {
    final project = Directory(p.join(tempDir.path, 'visible_project'))
      ..createSync(recursive: true);
    File(p.join(project.path, 'README.md')).writeAsStringSync('# Visible');
    File(p.join(project.path, '.env')).writeAsStringSync('SECRET_VALUE=abc');

    final excluded = Directory(p.join(tempDir.path, 'node_modules', 'hidden'))
      ..createSync(recursive: true);
    File(p.join(excluded.path, 'package.json')).writeAsStringSync('{}');

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 3,
    ).scan();

    expect(
      result.observations.map((item) => item.displayName),
      contains('visible_project'),
    );
    expect(
      result.observations.map((item) => item.displayName),
      isNot(contains('hidden')),
    );
    final serialized = result.toJson().toString();
    expect(serialized, isNot(contains('SECRET_VALUE')));
    expect(serialized, isNot(contains('.env')));
  });

  test(
    'strong project roots stop nested candidate discovery by default',
    () async {
      final project = Directory(p.join(tempDir.path, 'root_project'))
        ..createSync(recursive: true);
      File(p.join(project.path, 'README.md')).writeAsStringSync('# Root');
      File(p.join(project.path, 'package.json')).writeAsStringSync('{}');
      final nested = Directory(p.join(project.path, 'examples', 'nested_app'))
        ..createSync(recursive: true);
      File(p.join(nested.path, 'README.md')).writeAsStringSync('# Nested');
      File(p.join(nested.path, 'package.json')).writeAsStringSync('{}');

      final result = await LocalOperationsScanner(roots: [tempDir.path]).scan();
      final names = result.observations
          .map((item) => item.displayName)
          .toList();

      expect(names, contains('root_project'));
      expect(names, isNot(contains('nested_app')));
    },
  );

  test('marks broken git-only roots as needs_review', () async {
    final broken = Directory(p.join(tempDir.path, 'ambiguous_wrapper'))
      ..createSync(recursive: true);
    Directory(p.join(broken.path, '.git')).createSync();

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 2,
      gitTimeout: const Duration(milliseconds: 500),
    ).scan();

    final observed = result.observations.singleWhere(
      (item) => item.displayName == 'ambiguous_wrapper',
    );
    expect(observed.classificationGuess, 'needs_review');
  });

  test('classifies suffixed database snapshot folders as data roots', () async {
    final snapshots = Directory(p.join(tempDir.path, 'sample_db_snapshots'))
      ..createSync(recursive: true);
    File(p.join(snapshots.path, 'README.md')).writeAsStringSync('# Snapshots');

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 2,
    ).scan();

    final observed = result.observations.singleWhere(
      (item) => item.displayName == 'sample_db_snapshots',
    );
    expect(observed.classificationGuess, 'data_root');
  });

  test('skips unsafe drive roots before filesystem traversal', () async {
    final result = await const LocalOperationsScanner(roots: [r'B:\']).scan();

    expect(result.totalSeen, 0);
    expect(result.observations, isEmpty);
    expect(result.warnings.single, contains('Root is too broad'));
  });

  test('parses read-only git metadata from a temporary repo', () async {
    final repo = Directory(p.join(tempDir.path, 'git_project'))
      ..createSync(recursive: true);
    final init = await Process.run('git', [
      'init',
    ], workingDirectory: repo.path);
    if (init.exitCode != 0) {
      return;
    }
    await Process.run('git', [
      'config',
      'user.email',
      'atlas-test@example.invalid',
    ], workingDirectory: repo.path);
    await Process.run('git', [
      'config',
      'user.name',
      'Atlas Test',
    ], workingDirectory: repo.path);
    File(p.join(repo.path, 'README.md')).writeAsStringSync('# Git Project');
    await Process.run('git', ['add', 'README.md'], workingDirectory: repo.path);
    final commit = await Process.run('git', [
      'commit',
      '-m',
      'initial',
    ], workingDirectory: repo.path);
    if (commit.exitCode != 0) {
      return;
    }

    final result = await LocalOperationsScanner(
      roots: [tempDir.path],
      maxDepth: 2,
    ).scan();

    final observed = result.observations.singleWhere(
      (item) => item.displayName == 'git_project',
    );
    expect(observed.gitRoot, isNotNull);
    expect(observed.headSha, hasLength(40));
    expect(observed.dirtyCount, 0);
    expect(observed.branch, isNotNull);
  });
}
