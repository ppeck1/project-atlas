import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/project_bundle_recovery_service.dart';

void main() {
  test('stages a matching project bundle without changing its source', () async {
    final root = await Directory.systemTemp.createTemp(
      'atlas_project_recovery',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}alpha.zip');
    await _writeBundle(source, projectId: 'alpha', includeDocument: true);

    final report = await ProjectBundleRecoveryService().validateAndStage(
      source,
      Directory('${root.path}${Platform.pathSeparator}staging'),
      expectedProjectId: 'alpha',
    );

    expect(report.projectId, 'alpha');
    expect(report.stagedFiles, 4);
    expect(
      await File(
        '${report.stagingPath}${Platform.pathSeparator}project_bundle.json',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${report.stagingPath}${Platform.pathSeparator}documents${Platform.pathSeparator}note.txt',
      ).readAsString(),
      'hello',
    );
    expect(await source.exists(), isTrue);
  });

  test('rejects a bundle for a different selected project', () async {
    final root = await Directory.systemTemp.createTemp(
      'atlas_project_recovery',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}alpha.zip');
    await _writeBundle(source, projectId: 'alpha');

    expect(
      () => ProjectBundleRecoveryService().validateAndStage(
        source,
        Directory('${root.path}${Platform.pathSeparator}staging'),
        expectedProjectId: 'bravo',
      ),
      throwsA(isA<ProjectBundleRecoveryException>()),
    );
  });
}

Future<void> _writeBundle(
  File output, {
  required String projectId,
  bool includeDocument = false,
}) async {
  final archive = Archive();
  void addText(String name, String value) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText(
    'project_bundle.json',
    jsonEncode({
      'schema': 'project_atlas_project_bundle_v1',
      'project': {'id': projectId, 'title': 'Alpha'},
    }),
  );
  addText(
    'manifest/export_manifest.json',
    jsonEncode({
      'schema': 'project_atlas_project_bundle_manifest_v1',
      'project': {'id': projectId, 'title': 'Alpha'},
      'contents': {
        'projectBundle': 'project_bundle.json',
        'manifest': 'manifest/export_manifest.json',
        'readme': 'README.md',
        'documentFiles': includeDocument ? 1 : 0,
        'mediaFiles': 0,
      },
    }),
  );
  addText('README.md', '# Alpha');
  if (includeDocument) addText('documents/note.txt', 'hello');
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
}
