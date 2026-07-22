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

  test('rejects legacy manifests before creating staging output', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_legacy');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}legacy.zip');
    await _writeBundle(source, projectId: 'alpha');
    await _rewriteManifest(source, (manifest) {
      manifest['schema'] = 'project_atlas_project_bundle_manifest_v1';
    });
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');

    await expectLater(
      ProjectBundleRecoveryService().validateAndStage(source, staging),
      throwsA(
        isA<ProjectBundleRecoveryException>().having(
          (error) => error.message,
          'message',
          contains('legacy'),
        ),
      ),
    );
    expect(await staging.exists(), isFalse);
  });

  test('rejects missing, extra, mutated, and malformed inventory', () async {
    final mutations = <String, Future<void> Function(File)>{
      'missing descriptor': (source) => _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        files.removeWhere(
          (value) => (value as Map<dynamic, dynamic>)['path'] == 'README.md',
        );
      }),
      'wrong kind': (source) => _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        final readme = files.cast<Map<dynamic, dynamic>>().singleWhere(
          (value) => value['path'] == 'README.md',
        );
        readme['kind'] = 'document';
      }),
      'duplicate descriptor': (source) => _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        files.add(Map<String, dynamic>.from(files.first as Map));
      }),
      'missing core pointer': (source) => _rewriteManifest(source, (manifest) {
        final contents = manifest['contents']! as Map<String, dynamic>;
        contents.remove('projectBundle');
      }),
      'wrong size': (source) => _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        final readme = files.cast<Map<dynamic, dynamic>>().singleWhere(
          (value) => value['path'] == 'README.md',
        );
        readme['bytes'] = (readme['bytes']! as int) + 1;
      }),
      'malformed digest': (source) => _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        final readme = files.cast<Map<dynamic, dynamic>>().singleWhere(
          (value) => value['path'] == 'README.md',
        );
        readme['sha256'] = 'ABC';
      }),
      'modified payload': (source) =>
          _rewriteEntry(source, 'README.md', utf8.encode('# Bravo')),
      'undeclared payload': (source) =>
          _addEntry(source, 'documents/extra.txt', utf8.encode('undeclared')),
    };

    for (final mutation in mutations.entries) {
      final root = await Directory.systemTemp.createTemp('atlas_bundle_bad');
      try {
        final source = File('${root.path}${Platform.pathSeparator}bad.zip');
        await _writeBundle(source, projectId: 'alpha');
        await mutation.value(source);
        final staging = Directory(
          '${root.path}${Platform.pathSeparator}staging',
        );

        await expectLater(
          ProjectBundleRecoveryService().validateAndStage(source, staging),
          throwsA(isA<ProjectBundleRecoveryException>()),
          reason: mutation.key,
        );
        expect(await staging.exists(), isFalse, reason: mutation.key);
      } finally {
        await root.delete(recursive: true);
      }
    }
  });

  test('enforces source, entry, metadata, and expanded limits', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_limits');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}limits.zip');
    await _writeBundle(
      source,
      projectId: 'alpha',
      additionalEntries: {'documents/large.txt': 'x' * 4096},
    );

    final cases = <String, ProjectBundleRecoveryLimits>{
      'source': ProjectBundleRecoveryLimits(
        maxSourceBytes: await source.length() - 1,
      ),
      'entries': const ProjectBundleRecoveryLimits(maxEntries: 3),
      'central directory': const ProjectBundleRecoveryLimits(
        maxCentralDirectoryBytes: 32,
      ),
      'compressed entry': const ProjectBundleRecoveryLimits(
        maxCompressedEntryBytes: 16,
      ),
      'metadata': const ProjectBundleRecoveryLimits(maxMetadataJsonBytes: 32),
      'entry expanded': const ProjectBundleRecoveryLimits(
        maxExpandedEntryBytes: 1024,
      ),
      'total expanded': const ProjectBundleRecoveryLimits(
        maxTotalExpandedBytes: 1024,
      ),
    };
    for (final entry in cases.entries) {
      final staging = Directory(
        '${root.path}${Platform.pathSeparator}staging-${entry.key}',
      );
      await expectLater(
        ProjectBundleRecoveryService(
          limits: entry.value,
        ).validateAndStage(source, staging),
        throwsA(isA<ProjectBundleRecoveryException>()),
        reason: entry.key,
      );
      expect(await staging.exists(), isFalse, reason: entry.key);
    }
  });

  test(
    'actual-byte cap rejects forged-small ZIP size before staging',
    () async {
      final root = await Directory.systemTemp.createTemp('atlas_bundle_forged');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}forged.zip');
      await _writeBundle(
        source,
        projectId: 'alpha',
        additionalEntries: {'documents/bomb.txt': 'z' * 4096},
      );
      await _rewriteManifest(source, (manifest) {
        final files = manifest['files']! as List<dynamic>;
        final bomb = files.cast<Map<dynamic, dynamic>>().singleWhere(
          (value) => value['path'] == 'documents/bomb.txt',
        );
        bomb['bytes'] = 32;
      });
      await _patchEntryUncompressedSize(source, 'documents/bomb.txt', 32);
      final staging = Directory('${root.path}${Platform.pathSeparator}staging');

      await expectLater(
        ProjectBundleRecoveryService(
          limits: const ProjectBundleRecoveryLimits(
            maxExpandedEntryBytes: 1024,
          ),
        ).validateAndStage(source, staging),
        throwsA(
          isA<ProjectBundleRecoveryException>().having(
            (error) => error.message,
            'message',
            contains('actual expanded-size'),
          ),
        ),
      );
      expect(await staging.exists(), isFalse);
    },
  );

  test('preflight rejects a forged-small compressed extent', () async {
    final root = await Directory.systemTemp.createTemp(
      'atlas_bundle_compressed',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}compressed.zip');
    await _writeBundle(source, projectId: 'alpha', includeDocument: true);
    await _patchEntryCompressedSize(source, 'documents/note.txt', 1);
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');

    await expectLater(
      ProjectBundleRecoveryService().validateAndStage(source, staging),
      throwsA(
        isA<ProjectBundleRecoveryException>().having(
          (error) => error.message,
          'message',
          contains('compressed extent'),
        ),
      ),
    );
    expect(await staging.exists(), isFalse);
  });

  test('rejects Windows-hostile archive paths and canonical aliases', () async {
    final hostilePaths = <String>[
      '../escape.txt',
      '/rooted.txt',
      'C:/outside.txt',
      'C:relative.txt',
      'documents/note.txt:stream',
      'documents/CON.txt',
      'documents/lpt1.log',
      'documents/name.',
      'documents/name ',
      'documents/bad\u0001.txt',
      'documents/bad?.txt',
      'documents/./note.txt',
      'documents//note.txt',
      '//server/share.txt',
      'documents/${'a' * 520}.txt',
    ];
    for (final hostilePath in hostilePaths) {
      final root = await Directory.systemTemp.createTemp('atlas_bundle_path');
      try {
        final source = File('${root.path}${Platform.pathSeparator}path.zip');
        await _writeBundle(
          source,
          projectId: 'alpha',
          additionalEntries: {hostilePath: 'hostile'},
          declareAdditionalEntries: false,
        );
        await expectLater(
          ProjectBundleRecoveryService().validateAndStage(
            source,
            Directory('${root.path}${Platform.pathSeparator}staging'),
          ),
          throwsA(isA<ProjectBundleRecoveryException>()),
          reason: hostilePath,
        );
      } finally {
        await root.delete(recursive: true);
      }
    }

    final ancestorRoot = await Directory.systemTemp.createTemp(
      'atlas_bundle_ancestor',
    );
    try {
      final source = File(
        '${ancestorRoot.path}${Platform.pathSeparator}ancestor.zip',
      );
      await _writeBundle(
        source,
        projectId: 'alpha',
        additionalEntries: {
          'documents/node': 'file',
          'documents/node/child.txt': 'child',
        },
        declareAdditionalEntries: false,
      );
      await expectLater(
        ProjectBundleRecoveryService().validateAndStage(
          source,
          Directory('${ancestorRoot.path}${Platform.pathSeparator}staging'),
        ),
        throwsA(isA<ProjectBundleRecoveryException>()),
      );
    } finally {
      await ancestorRoot.delete(recursive: true);
    }

    final backslashRoot = await Directory.systemTemp.createTemp(
      'atlas_bundle_backslash',
    );
    try {
      final source = File(
        '${backslashRoot.path}${Platform.pathSeparator}backslash.zip',
      );
      await _writeBundle(source, projectId: 'alpha', includeDocument: true);
      await _patchEntryName(
        source,
        'documents/note.txt',
        'documents\\note.txt',
      );
      await expectLater(
        ProjectBundleRecoveryService().validateAndStage(
          source,
          Directory('${backslashRoot.path}${Platform.pathSeparator}staging'),
        ),
        throwsA(isA<ProjectBundleRecoveryException>()),
      );
    } finally {
      await backslashRoot.delete(recursive: true);
    }

    final root = await Directory.systemTemp.createTemp('atlas_bundle_alias');
    try {
      final source = File('${root.path}${Platform.pathSeparator}alias.zip');
      await _writeBundle(
        source,
        projectId: 'alpha',
        additionalEntries: {
          'documents/Note.txt': 'one',
          'documents/note.txt': 'two',
        },
        declareAdditionalEntries: false,
      );
      await expectLater(
        ProjectBundleRecoveryService().validateAndStage(
          source,
          Directory('${root.path}${Platform.pathSeparator}staging'),
        ),
        throwsA(isA<ProjectBundleRecoveryException>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('accepts bounded Unicode and spaces in a nested document path', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_unicode');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}unicode.zip');
    await _writeBundle(
      source,
      projectId: 'alpha',
      additionalEntries: {'documents/Résumé notes.txt': 'safe'},
    );

    final report = await ProjectBundleRecoveryService().validateAndStage(
      source,
      Directory('${root.path}${Platform.pathSeparator}staging'),
    );

    expect(
      await File(
        '${report.stagingPath}${Platform.pathSeparator}documents${Platform.pathSeparator}Résumé notes.txt',
      ).readAsString(),
      'safe',
    );
  });

  test('rejects a corrupted ZIP CRC before staging', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_crc');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}crc.zip');
    await _writeBundle(source, projectId: 'alpha');
    await _patchEntryCrc(source, 'README.md', 0);
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');

    await expectLater(
      ProjectBundleRecoveryService().validateAndStage(source, staging),
      throwsA(
        isA<ProjectBundleRecoveryException>().having(
          (error) => error.message,
          'message',
          contains('CRC'),
        ),
      ),
    );
    expect(await staging.exists(), isFalse);
  });

  test(
    'preflight rejects a forged-low central-directory entry count',
    () async {
      final root = await Directory.systemTemp.createTemp('atlas_bundle_count');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}count.zip');
      await _writeBundle(source, projectId: 'alpha', includeDocument: true);
      await _patchEocdEntryCount(source, 1);
      final staging = Directory('${root.path}${Platform.pathSeparator}staging');

      await expectLater(
        ProjectBundleRecoveryService().validateAndStage(source, staging),
        throwsA(
          isA<ProjectBundleRecoveryException>().having(
            (error) => error.message,
            'message',
            contains('count does not match'),
          ),
        ),
      );
      expect(await staging.exists(), isFalse);
    },
  );

  test('second-pass preflight reapplies the source-size limit', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_swap');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}source.zip');
    final replacement = File(
      '${root.path}${Platform.pathSeparator}replacement.zip',
    );
    await _writeBundle(source, projectId: 'alpha');
    await _writeBundle(
      replacement,
      projectId: 'alpha',
      additionalEntries: {
        'documents/larger.txt': List<String>.generate(
          4096,
          (index) => String.fromCharCode(33 + (index % 90)),
        ).join(),
      },
    );
    final sourceLimit = await source.length();
    expect(await replacement.length(), greaterThan(sourceLimit));
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');

    await expectLater(
      ProjectBundleRecoveryService(
        limits: ProjectBundleRecoveryLimits(maxSourceBytes: sourceLimit),
        recoveryStepHook: (step) async {
          if (step == 'validated') await replacement.copy(source.path);
        },
      ).validateAndStage(source, staging),
      throwsA(
        isA<ProjectBundleRecoveryException>().having(
          (error) => error.message,
          'message',
          contains('source-size limit'),
        ),
      ),
    );
    expect(await staging.exists(), isFalse);
  });

  test('accepts exact configured ZIP resource boundaries', () async {
    final root = await Directory.systemTemp.createTemp('atlas_bundle_exact');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}exact.zip');
    await _writeBundle(source, projectId: 'alpha', includeDocument: true);
    final sourceBytes = await source.readAsBytes();
    final archive = ZipDecoder().decodeBytes(sourceBytes);
    final expanded = archive.fold<int>(0, (sum, entry) => sum + entry.size);
    final largestExpanded = archive.fold<int>(
      0,
      (largest, entry) => entry.size > largest ? entry.size : largest,
    );
    final largestCompressed = archive.fold<int>(
      0,
      (largest, entry) => entry.rawContent!.length > largest
          ? entry.rawContent!.length
          : largest,
    );
    final manifestBytes = archive
        .findFile(atlasProjectBundleManifestPath)!
        .size;
    final directoryBytes = _eocdDirectorySize(sourceBytes);

    final report =
        await ProjectBundleRecoveryService(
          limits: ProjectBundleRecoveryLimits(
            maxSourceBytes: sourceBytes.length,
            maxEntries: archive.length,
            maxCentralDirectoryBytes: directoryBytes,
            maxCompressedEntryBytes: largestCompressed,
            maxExpandedEntryBytes: largestExpanded,
            maxTotalExpandedBytes: expanded,
            maxMetadataJsonBytes: manifestBytes,
          ),
        ).validateAndStage(
          source,
          Directory('${root.path}${Platform.pathSeparator}staging'),
        );

    expect(report.stagedFiles, archive.length);
  });
}

Future<void> _writeBundle(
  File output, {
  required String projectId,
  bool includeDocument = false,
  Map<String, String> additionalEntries = const {},
  bool declareAdditionalEntries = true,
}) async {
  final archive = Archive();
  final payloads = <String, List<int>>{};
  void addText(String name, String value) {
    final bytes = utf8.encode(value);
    payloads[name] = bytes;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText(
    'project_bundle.json',
    jsonEncode({
      'schema': 'project_atlas_project_bundle_v1',
      'project': {'id': projectId, 'title': 'Alpha'},
    }),
  );
  addText('README.md', '# Alpha');
  if (includeDocument) addText('documents/note.txt', 'hello');
  for (final entry in additionalEntries.entries) {
    final bytes = utf8.encode(entry.value);
    if (declareAdditionalEntries) payloads[entry.key] = bytes;
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final documentFiles = payloads.keys
      .where((path) => path.startsWith('documents/'))
      .length;
  final mediaFiles = payloads.keys
      .where((path) => path.startsWith('media/'))
      .length;
  addText(
    atlasProjectBundleManifestPath,
    jsonEncode({
      'schema': atlasProjectBundleManifestSchema,
      'project': {'id': projectId, 'title': 'Alpha'},
      'contents': {
        'projectBundle': 'project_bundle.json',
        'manifest': atlasProjectBundleManifestPath,
        'readme': 'README.md',
        'documentFiles': documentFiles,
        'mediaFiles': mediaFiles,
      },
      'files': payloads.entries
          .map((entry) => projectBundleFileDescriptor(entry.key, entry.value))
          .toList(),
    }),
  );
  await output.writeAsBytes(ZipEncoder().encode(archive)!);
}

Future<void> _rewriteManifest(
  File source,
  void Function(Map<String, dynamic> manifest) mutate,
) async {
  await _rewriteArchive(source, (entries) {
    final manifest =
        jsonDecode(utf8.decode(entries[atlasProjectBundleManifestPath]!))
            as Map<String, dynamic>;
    mutate(manifest);
    entries[atlasProjectBundleManifestPath] = utf8.encode(jsonEncode(manifest));
  });
}

Future<void> _rewriteEntry(File source, String path, List<int> bytes) =>
    _rewriteArchive(source, (entries) => entries[path] = bytes);

Future<void> _addEntry(File source, String path, List<int> bytes) =>
    _rewriteArchive(source, (entries) => entries[path] = bytes);

Future<void> _rewriteArchive(
  File source,
  void Function(Map<String, List<int>> entries) mutate,
) async {
  final decoded = ZipDecoder().decodeBytes(await source.readAsBytes());
  final entries = <String, List<int>>{
    for (final entry in decoded)
      if (entry.isFile) entry.name: List<int>.from(entry.content as List<int>),
  };
  mutate(entries);
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  await source.writeAsBytes(ZipEncoder().encode(archive)!);
}

Future<void> _patchEntryUncompressedSize(
  File source,
  String path,
  int size,
) async {
  final bytes = await source.readAsBytes();
  var patchedLocal = false;
  var patchedCentral = false;
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    final signature = _readUint32(bytes, offset);
    if (signature == 0x04034b50) {
      final nameLength = _readUint16(bytes, offset + 26);
      final name = utf8.decode(
        bytes.sublist(offset + 30, offset + 30 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 22, size);
        patchedLocal = true;
      }
    } else if (signature == 0x02014b50) {
      final nameLength = _readUint16(bytes, offset + 28);
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 24, size);
        patchedCentral = true;
      }
    }
  }
  expect(patchedLocal, isTrue);
  expect(patchedCentral, isTrue);
  await source.writeAsBytes(bytes);
}

Future<void> _patchEntryCompressedSize(
  File source,
  String path,
  int size,
) async {
  final bytes = await source.readAsBytes();
  var patchedLocal = false;
  var patchedCentral = false;
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    final signature = _readUint32(bytes, offset);
    if (signature == 0x04034b50) {
      final nameLength = _readUint16(bytes, offset + 26);
      final name = utf8.decode(
        bytes.sublist(offset + 30, offset + 30 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 18, size);
        patchedLocal = true;
      }
    } else if (signature == 0x02014b50) {
      final nameLength = _readUint16(bytes, offset + 28);
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 20, size);
        patchedCentral = true;
      }
    }
  }
  expect(patchedLocal, isTrue);
  expect(patchedCentral, isTrue);
  await source.writeAsBytes(bytes);
}

Future<void> _patchEntryName(
  File source,
  String currentPath,
  String replacementPath,
) async {
  final current = utf8.encode(currentPath);
  final replacement = utf8.encode(replacementPath);
  expect(replacement.length, current.length);
  final bytes = await source.readAsBytes();
  var patches = 0;
  for (var offset = 0; offset <= bytes.length - current.length; offset++) {
    var matches = true;
    for (var index = 0; index < current.length; index++) {
      if (bytes[offset + index] != current[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      bytes.setRange(offset, offset + replacement.length, replacement);
      patches++;
    }
  }
  expect(patches, 2);
  await source.writeAsBytes(bytes);
}

Future<void> _patchEntryCrc(File source, String path, int crc) async {
  final bytes = await source.readAsBytes();
  var patchedLocal = false;
  var patchedCentral = false;
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    final signature = _readUint32(bytes, offset);
    if (signature == 0x04034b50) {
      final nameLength = _readUint16(bytes, offset + 26);
      final name = utf8.decode(
        bytes.sublist(offset + 30, offset + 30 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 14, crc);
        patchedLocal = true;
      }
    } else if (signature == 0x02014b50) {
      final nameLength = _readUint16(bytes, offset + 28);
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );
      if (name == path) {
        _writeUint32(bytes, offset + 16, crc);
        patchedCentral = true;
      }
    }
  }
  expect(patchedLocal, isTrue);
  expect(patchedCentral, isTrue);
  await source.writeAsBytes(bytes);
}

Future<void> _patchEocdEntryCount(File source, int count) async {
  final bytes = await source.readAsBytes();
  final offset = _findEocd(bytes);
  _writeUint16(bytes, offset + 8, count);
  _writeUint16(bytes, offset + 10, count);
  await source.writeAsBytes(bytes);
}

int _eocdDirectorySize(List<int> bytes) =>
    _readUint32(bytes, _findEocd(bytes) + 12);

int _findEocd(List<int> bytes) {
  for (var offset = bytes.length - 22; offset >= 0; offset--) {
    if (_readUint32(bytes, offset) == 0x06054b50) return offset;
  }
  throw StateError('EOCD not found');
}

int _readUint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(List<int> bytes, int offset) =>
    _readUint16(bytes, offset) | (_readUint16(bytes, offset + 2) << 16);

void _writeUint32(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}

void _writeUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}
