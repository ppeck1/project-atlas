import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/portable_export_service.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('atlas-portable-export-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'worker streams a compatible ZIP and reports bounded progress',
    () async {
      final source = File(p.join(tempDir.path, 'source.txt'))
        ..writeAsStringSync('portable source');
      final output = p.join(tempDir.path, 'portable.zip');
      File(output).writeAsStringSync('previous export');
      final task = await PortableExportService().start(
        outputPath: output,
        payload: {
          'schema': 'project_atlas_portable_export_v1',
          'projects': [
            {'id': 'atlas', 'title': 'Project Atlas'},
          ],
        },
        sources: [
          PortableExportSource(
            sourcePath: source.path,
            archivePath: 'documents/source.txt',
          ),
        ],
      );
      final phases = <PortableExportPhase>[];
      final subscription = task.progress.listen(
        (progress) => phases.add(progress.phase),
      );

      final report = await task.result;
      await subscription.cancel();

      expect(report.exportedFiles, 1);
      expect(report.sourceBytes, source.lengthSync());
      expect(report.outputBytes, greaterThan(source.lengthSync()));
      expect(phases, contains(PortableExportPhase.writingManifest));
      expect(phases, contains(PortableExportPhase.addingFiles));
      expect(phases, contains(PortableExportPhase.complete));
      expect(
        tempDir.listSync().where((entity) => entity.path.contains('.atlas-')),
        isEmpty,
      );

      final archive = ZipDecoder().decodeBytes(
        await File(output).readAsBytes(),
        verify: true,
      );
      expect(
        archive.findFile('documents/source.txt')!.compressionType,
        ArchiveFile.STORE,
      );
      expect(
        utf8.decode(
          archive.findFile('documents/source.txt')!.content as List<int>,
        ),
        'portable source',
      );
      final manifest =
          jsonDecode(
                utf8.decode(
                  archive.findFile('portable_export.json')!.content
                      as List<int>,
                ),
              )
              as Map<String, dynamic>;
      expect(manifest['schema'], 'project_atlas_portable_export_v1');
      expect((manifest['projects'] as List).single['id'], 'atlas');
    },
  );

  test(
    'preflight enforces entry, file, aggregate, path, and record bounds',
    () async {
      final source = File(p.join(tempDir.path, 'source.bin'))
        ..writeAsBytesSync([1, 2, 3, 4]);
      const validSource = PortableExportSource(
        sourcePath: '',
        archivePath: 'documents/source.bin',
      );
      final service = PortableExportService();

      Future<PortableExportException> capture(
        Future<PortableExportTask> Function() run,
      ) async {
        try {
          await run();
          fail('Expected PortableExportException.');
        } on PortableExportException catch (error) {
          return error;
        }
      }

      final fileError = await capture(
        () => service.start(
          outputPath: p.join(tempDir.path, 'file.zip'),
          payload: const {'schema': 'v1'},
          sources: [
            PortableExportSource(
              sourcePath: source.path,
              archivePath: validSource.archivePath,
            ),
          ],
          limits: const PortableExportLimits(maxFileBytes: 3),
        ),
      );
      expect(fileError.code, 'file_size_limit');

      final aggregateError = await capture(
        () => service.start(
          outputPath: p.join(tempDir.path, 'aggregate.zip'),
          payload: const {'schema': 'v1'},
          sources: [
            PortableExportSource(
              sourcePath: source.path,
              archivePath: validSource.archivePath,
            ),
          ],
          limits: const PortableExportLimits(maxTotalSourceBytes: 3),
        ),
      );
      expect(aggregateError.code, 'aggregate_size_limit');

      final entryError = await capture(
        () => service.start(
          outputPath: p.join(tempDir.path, 'entries.zip'),
          payload: const {'schema': 'v1'},
          sources: [
            PortableExportSource(
              sourcePath: source.path,
              archivePath: validSource.archivePath,
            ),
          ],
          limits: const PortableExportLimits(maxEntries: 1),
        ),
      );
      expect(entryError.code, 'entry_limit');

      final pathError = await capture(
        () => service.start(
          outputPath: p.join(tempDir.path, 'path.zip'),
          payload: const {'schema': 'v1'},
          sources: [
            PortableExportSource(
              sourcePath: source.path,
              archivePath: '../source.bin',
            ),
          ],
        ),
      );
      expect(pathError.code, 'invalid_archive_path');

      final recordError = await capture(
        () => service.start(
          outputPath: p.join(tempDir.path, 'records.zip'),
          payload: const {
            'projects': [
              {'id': 'one'},
              {'id': 'two'},
            ],
          },
          sources: const [],
          limits: const PortableExportLimits(maxMetadataRecords: 1),
        ),
      );
      expect(recordError.code, 'metadata_record_limit');
    },
  );

  test(
    'manifest bound fails without replacing output or retaining partials',
    () async {
      final output = File(p.join(tempDir.path, 'portable.zip'))
        ..writeAsStringSync('previous export');
      final task = await PortableExportService().start(
        outputPath: output.path,
        payload: {
          'schema': 'project_atlas_portable_export_v1',
          'projects': [
            {'title': List.filled(200, 'x').join()},
          ],
        },
        sources: const [],
        limits: const PortableExportLimits(maxManifestBytes: 64),
      );

      await expectLater(
        task.result,
        throwsA(
          isA<PortableExportException>().having(
            (error) => error.code,
            'code',
            'manifest_size_limit',
          ),
        ),
      );
      expect(await output.readAsString(), 'previous export');
      expect(
        tempDir.listSync().where((entity) => entity.path.contains('.atlas-')),
        isEmpty,
      );
    },
  );

  test('runtime limits cannot exceed hard policy maxima', () {
    expect(
      () => const PortableExportLimits(
        maxEntries: PortableExportLimits.hardMaxEntries + 1,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const PortableExportLimits(maxManifestBytes: 0).validate(),
      throwsArgumentError,
    );
  });

  test('non-file sources and output targets fail with typed errors', () async {
    final directorySource = Directory(p.join(tempDir.path, 'source'))
      ..createSync();
    final service = PortableExportService();

    await expectLater(
      service.start(
        outputPath: p.join(tempDir.path, 'portable.zip'),
        payload: const {'schema': 'v1'},
        sources: [
          PortableExportSource(
            sourcePath: directorySource.path,
            archivePath: 'documents/source.bin',
          ),
        ],
      ),
      throwsA(
        isA<PortableExportException>().having(
          (error) => error.code,
          'code',
          'unsafe_source',
        ),
      ),
    );
    await expectLater(
      service.start(
        outputPath: directorySource.path,
        payload: const {'schema': 'v1'},
        sources: const [],
      ),
      throwsA(
        isA<PortableExportException>().having(
          (error) => error.code,
          'code',
          'unsafe_output',
        ),
      ),
    );
  });

  test(
    'cancellation terminates the worker and preserves existing output',
    () async {
      final source = File(p.join(tempDir.path, 'large.bin'));
      final handle = source.openSync(mode: FileMode.write);
      handle.setPositionSync(64 * 1024 * 1024 - 1);
      handle.writeByteSync(0);
      handle.closeSync();
      final output = File(p.join(tempDir.path, 'portable.zip'))
        ..writeAsStringSync('previous export');
      final task = await PortableExportService().start(
        outputPath: output.path,
        payload: const {'schema': 'project_atlas_portable_export_v1'},
        sources: [
          PortableExportSource(
            sourcePath: source.path,
            archivePath: 'documents/large.bin',
          ),
        ],
      );

      final cancelled = expectLater(
        task.result,
        throwsA(isA<PortableExportCancelledException>()),
      );
      await task.cancel();
      await cancelled;
      expect(await output.readAsString(), 'previous export');
      expect(
        tempDir.listSync().where((entity) => entity.path.contains('.atlas-')),
        isEmpty,
      );
    },
  );

  test('duplicate case-folded archive paths fail before spawning', () async {
    final one = File(p.join(tempDir.path, 'one.txt'))..writeAsStringSync('1');
    final two = File(p.join(tempDir.path, 'two.txt'))..writeAsStringSync('2');

    await expectLater(
      PortableExportService().start(
        outputPath: p.join(tempDir.path, 'portable.zip'),
        payload: const {'schema': 'v1'},
        sources: [
          PortableExportSource(
            sourcePath: one.path,
            archivePath: 'documents/Readme.txt',
          ),
          PortableExportSource(
            sourcePath: two.path,
            archivePath: 'documents/README.TXT',
          ),
        ],
      ),
      throwsA(
        isA<PortableExportException>().having(
          (error) => error.code,
          'code',
          'duplicate_archive_path',
        ),
      ),
    );
  });
}
