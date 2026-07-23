import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'recovery_artifact_lifecycle.dart';

const atlasProjectBundleSchema = 'project_atlas_project_bundle_v1';
const atlasProjectBundleManifestSchema =
    'project_atlas_project_bundle_manifest_v2';
const atlasProjectBundleManifestPath = 'manifest/export_manifest.json';

/// Explicit recovery limits for untrusted project ZIPs.
class ProjectBundleRecoveryLimits {
  final int maxSourceBytes;
  final int maxEntries;
  final int maxCentralDirectoryBytes;
  final int maxCompressedEntryBytes;
  final int maxExpandedEntryBytes;
  final int maxTotalExpandedBytes;
  final int maxMetadataJsonBytes;
  final int maxPathLength;

  const ProjectBundleRecoveryLimits({
    this.maxSourceBytes = 512 * 1024 * 1024,
    this.maxEntries = 2048,
    this.maxCentralDirectoryBytes = 16 * 1024 * 1024,
    this.maxCompressedEntryBytes = 256 * 1024 * 1024,
    this.maxExpandedEntryBytes = 512 * 1024 * 1024,
    this.maxTotalExpandedBytes = 1024 * 1024 * 1024,
    this.maxMetadataJsonBytes = 8 * 1024 * 1024,
    this.maxPathLength = 512,
  });
}

/// Creates the v2 integrity descriptor used by Atlas project-bundle exports.
Map<String, Object?> projectBundleFileDescriptor(
  String path,
  List<int> bytes,
) => {
  'path': path,
  'kind': projectBundleKindForPath(path),
  'bytes': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
};

String projectBundleKindForPath(String path) {
  if (path == 'project_bundle.json') return 'project_payload';
  if (path == 'README.md') return 'readme';
  if (path.startsWith('bootstrap/')) return 'bootstrap';
  if (path.startsWith('summary/')) return 'summary';
  if (path == 'logs/project_event_log.json') return 'event_log';
  if (path == 'logs/export_warnings.txt') return 'export_warnings';
  if (path.startsWith('change_log/')) return 'change_log';
  if (path.startsWith('git/')) return 'clean_git_archive';
  if (path.startsWith('documents/')) return 'document';
  if (path.startsWith('media/')) return 'media';
  throw ProjectBundleRecoveryException(
    'Project bundle contains an unsupported archive path: $path',
  );
}

/// Validates a project bundle and writes a separate, inspectable recovery
/// staging folder. It never imports into, replaces, or changes the live Atlas
/// database.
class ProjectBundleRecoveryService {
  final ProjectBundleRecoveryLimits limits;
  final Future<void> Function(String step)? _recoveryStepHook;
  final RecoveryArtifactLifecycle _artifactLifecycle;

  ProjectBundleRecoveryService({
    this.limits = const ProjectBundleRecoveryLimits(),
    Future<void> Function(String step)? recoveryStepHook,
    RecoveryArtifactLifecycle? artifactLifecycle,
  }) : _recoveryStepHook = recoveryStepHook,
       _artifactLifecycle = artifactLifecycle ?? RecoveryArtifactLifecycle();

  Future<ProjectBundleStagingReport> validateAndStage(
    File bundle,
    Directory destinationRoot, {
    String? expectedProjectId,
  }) async {
    if (!await bundle.exists()) {
      throw const ProjectBundleRecoveryException(
        'Project bundle was not found.',
      );
    }
    final sourceBytes = await bundle.length();
    if (sourceBytes > limits.maxSourceBytes) {
      throw const ProjectBundleRecoveryException(
        'Project bundle exceeds the source-size limit.',
      );
    }
    await _preflightZipDirectory(bundle, sourceBytes);
    final sourceDigest = await _sha256File(bundle);
    final validated = await _validateArchive(bundle, expectedProjectId);
    if (await _sha256File(bundle) != sourceDigest) {
      throw const ProjectBundleRecoveryException(
        'Project bundle changed during validation.',
      );
    }
    await _recoveryStepHook?.call('validated');
    await _preflightZipDirectory(bundle, await bundle.length());
    if (await _sha256File(bundle) != sourceDigest) {
      throw const ProjectBundleRecoveryException(
        'Project bundle changed before staging.',
      );
    }

    await destinationRoot.create(recursive: true);
    final stage = Directory(
      p.join(
        destinationRoot.path,
        'project-recovery-stage-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}-${_safeStem(validated.projectTitle)}',
      ),
    );
    final artifact = await _artifactLifecycle.begin(
      stage,
      kind: RecoveryArtifactKind.projectBundleStaging,
    );
    final workStage = artifact.artifactDirectory;
    try {
      await _recoveryStepHook?.call('stage-created');
      final stagedFiles = await _extractValidatedArchive(
        bundle,
        workStage,
        validated,
      );
      await _recoveryStepHook?.call('stage-extracted');
      if (await _sha256File(bundle) != sourceDigest) {
        throw const ProjectBundleRecoveryException(
          'Project bundle changed during staging.',
        );
      }
      await _recoveryStepHook?.call('before-report');
      final report = ProjectBundleStagingReport(
        sourceBundlePath: bundle.path,
        stagingPath: artifact.finalDirectory.path,
        projectId: validated.projectId,
        projectTitle: validated.projectTitle,
        stagedFiles: stagedFiles,
      );
      await File(
        p.join(workStage.path, 'project_bundle_staged.json'),
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
      await _recoveryStepHook?.call('report-written');
      await artifact.complete();
      return report;
    } on Object catch (error, stackTrace) {
      try {
        final report = File(
          p.join(artifact.artifactDirectory.path, 'project_bundle_staged.json'),
        );
        if (await report.exists()) await report.delete();
      } on Object {
        // Completion-report cleanup is subordinate to the initiating failure.
      }
      await artifact.fail();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<_ValidatedProjectBundle> _validateArchive(
    File bundle,
    String? expectedProjectId,
  ) async {
    final decoded = _openArchive(bundle);
    try {
      final entries = _inspectArchive(decoded);
      final manifestEntry = entries[atlasProjectBundleManifestPath];
      if (manifestEntry == null) {
        throw const ProjectBundleRecoveryException(
          'Project bundle is missing manifest/export_manifest.json.',
        );
      }
      if (manifestEntry.size > limits.maxMetadataJsonBytes) {
        throw const ProjectBundleRecoveryException(
          'Project bundle manifest exceeds the metadata-size limit.',
        );
      }
      final budget = _ExpansionBudget(limits.maxTotalExpandedBytes);
      final manifestBytes = _readEntryBytes(
        manifestEntry,
        budget,
        maxBytes: limits.maxMetadataJsonBytes,
      );
      final manifest = _decodeJson(
        manifestBytes,
        atlasProjectBundleManifestPath,
      );
      final manifestDigest = sha256.convert(manifestBytes).toString();
      if (manifest['schema'] != atlasProjectBundleManifestSchema) {
        throw const ProjectBundleRecoveryException(
          'Unsupported or legacy project bundle manifest; re-export the project with the current Atlas version.',
        );
      }
      final descriptors = _parseDescriptors(manifest['files']);
      final actualPayloadPaths = entries.keys
          .where((path) => path != atlasProjectBundleManifestPath)
          .toSet();
      if (!_sameSet(actualPayloadPaths, descriptors.keys.toSet())) {
        throw const ProjectBundleRecoveryException(
          'Project bundle inventory does not exactly match its manifest.',
        );
      }

      Map<String, dynamic>? payload;
      for (final path in actualPayloadPaths) {
        final entry = entries[path]!;
        final descriptor = descriptors[path]!;
        final expectedKind = projectBundleKindForPath(path);
        if (descriptor.kind != expectedKind) {
          throw ProjectBundleRecoveryException(
            'Project bundle has the wrong file kind for $path.',
          );
        }
        if (descriptor.bytes != entry.size) {
          throw ProjectBundleRecoveryException(
            'Project bundle has the wrong byte length for $path.',
          );
        }
        final capture = path == 'project_bundle.json';
        if (capture && entry.size > limits.maxMetadataJsonBytes) {
          throw const ProjectBundleRecoveryException(
            'Project bundle payload exceeds the metadata-size limit.',
          );
        }
        final result = _streamEntry(
          entry,
          budget,
          capture: capture,
          maxCaptureBytes: limits.maxMetadataJsonBytes,
        );
        if (result.bytes != descriptor.bytes ||
            result.sha256 != descriptor.sha256) {
          throw ProjectBundleRecoveryException(
            'Project bundle integrity check failed for $path.',
          );
        }
        if (capture) {
          payload = _decodeJson(result.captured!, path);
        }
      }
      if (payload == null || payload['schema'] != atlasProjectBundleSchema) {
        throw const ProjectBundleRecoveryException(
          'Unsupported project bundle schema.',
        );
      }
      final project = _map(payload['project'], 'project');
      final manifestProject = _map(manifest['project'], 'manifest project');
      final projectId = _text(project['id'], 'project id');
      final projectTitle = _text(project['title'], 'project title');
      if (manifestProject['id'] != projectId) {
        throw const ProjectBundleRecoveryException(
          'The manifest and project payload identify different projects.',
        );
      }
      if (expectedProjectId != null && expectedProjectId != projectId) {
        throw const ProjectBundleRecoveryException(
          'This bundle belongs to a different selected project.',
        );
      }
      _validateContents(manifest, descriptors);
      return _ValidatedProjectBundle(
        projectId,
        projectTitle,
        Map.unmodifiable(descriptors),
        manifestDigest,
      );
    } finally {
      decoded.close();
    }
  }

  Future<int> _extractValidatedArchive(
    File bundle,
    Directory stage,
    _ValidatedProjectBundle validated,
  ) async {
    await _preflightZipDirectory(bundle, await bundle.length());
    final decoded = _openArchive(bundle);
    try {
      final entries = _inspectArchive(decoded);
      final expectedPaths = <String>{
        ...validated.descriptors.keys,
        atlasProjectBundleManifestPath,
      };
      if (!_sameSet(entries.keys.toSet(), expectedPaths)) {
        throw const ProjectBundleRecoveryException(
          'Project bundle changed after validation.',
        );
      }
      final budget = _ExpansionBudget(limits.maxTotalExpandedBytes);
      var count = 0;
      for (final entry in entries.values) {
        final output = File(_resolveContainedPath(stage, entry.name));
        await output.parent.create(recursive: true);
        final result = _streamEntry(entry, budget, output: output);
        if (entry.name == atlasProjectBundleManifestPath) {
          if (result.sha256 != validated.manifestSha256) {
            throw const ProjectBundleRecoveryException(
              'Project bundle manifest changed after validation.',
            );
          }
        } else {
          final descriptor = validated.descriptors[entry.name]!;
          if (descriptor.kind != projectBundleKindForPath(entry.name) ||
              result.bytes != descriptor.bytes ||
              result.sha256 != descriptor.sha256) {
            throw ProjectBundleRecoveryException(
              'Project bundle entry changed after validation: ${entry.name}',
            );
          }
        }
        if (result.bytes != entry.size) {
          throw ProjectBundleRecoveryException(
            'Project bundle entry length changed during staging: ${entry.name}',
          );
        }
        count++;
        await _recoveryStepHook?.call('entry-staged:${entry.name}');
      }
      return count;
    } finally {
      decoded.close();
    }
  }

  _DecodedArchive _openArchive(File bundle) {
    final input = InputFileStream(bundle.path);
    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input, verify: false);
      return _DecodedArchive(input, decoder, archive);
    } on Object catch (error) {
      input.closeSync();
      throw ProjectBundleRecoveryException(
        'Project bundle is not a valid ZIP archive: $error',
      );
    }
  }

  Future<void> _preflightZipDirectory(File bundle, int sourceBytes) async {
    const minimumEocdBytes = 22;
    const maximumCommentBytes = 0xffff;
    if (sourceBytes > limits.maxSourceBytes) {
      throw const ProjectBundleRecoveryException(
        'Project bundle exceeds the source-size limit.',
      );
    }
    if (sourceBytes < minimumEocdBytes) {
      throw const ProjectBundleRecoveryException(
        'Project bundle is not a complete ZIP archive.',
      );
    }
    final tailBytes = sourceBytes < minimumEocdBytes + maximumCommentBytes
        ? sourceBytes
        : minimumEocdBytes + maximumCommentBytes;
    final handle = await bundle.open();
    try {
      await handle.setPosition(sourceBytes - tailBytes);
      final tail = await handle.read(tailBytes);
      var eocd = -1;
      for (var index = tail.length - minimumEocdBytes; index >= 0; index--) {
        if (_uint32(tail, index) == 0x06054b50) {
          eocd = index;
          break;
        }
      }
      if (eocd < 0) {
        throw const ProjectBundleRecoveryException(
          'Project bundle ZIP directory is missing.',
        );
      }
      final disk = _uint16(tail, eocd + 4);
      final directoryDisk = _uint16(tail, eocd + 6);
      final entriesOnDisk = _uint16(tail, eocd + 8);
      final entries = _uint16(tail, eocd + 10);
      final directoryBytes = _uint32(tail, eocd + 12);
      final directoryOffset = _uint32(tail, eocd + 16);
      final commentBytes = _uint16(tail, eocd + 20);
      final absoluteEocd = sourceBytes - tailBytes + eocd;
      if (absoluteEocd + minimumEocdBytes + commentBytes != sourceBytes) {
        throw const ProjectBundleRecoveryException(
          'Project bundle ZIP directory has an invalid extent.',
        );
      }
      if (disk != 0 || directoryDisk != 0 || entriesOnDisk != entries) {
        throw const ProjectBundleRecoveryException(
          'Multi-disk project bundle ZIPs are unsupported.',
        );
      }
      if (entries == 0xffff ||
          directoryBytes == 0xffffffff ||
          directoryOffset == 0xffffffff) {
        throw const ProjectBundleRecoveryException(
          'ZIP64 project bundles are unsupported.',
        );
      }
      if (entries > limits.maxEntries) {
        throw const ProjectBundleRecoveryException(
          'Project bundle exceeds the entry-count limit.',
        );
      }
      if (directoryBytes > limits.maxCentralDirectoryBytes ||
          directoryOffset + directoryBytes != absoluteEocd) {
        throw const ProjectBundleRecoveryException(
          'Project bundle ZIP directory exceeds its bounds.',
        );
      }
      await handle.setPosition(directoryOffset);
      final directory = await handle.read(directoryBytes);
      if (directory.length != directoryBytes) {
        throw const ProjectBundleRecoveryException(
          'Project bundle ZIP directory is truncated.',
        );
      }
      var offset = 0;
      var parsedEntries = 0;
      final centralEntries = <_CentralDirectoryEntry>[];
      while (offset < directory.length) {
        if (directory.length - offset < 46 ||
            _uint32(directory, offset) != 0x02014b50) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP directory contains an invalid record.',
          );
        }
        final nameBytes = _uint16(directory, offset + 28);
        final extraBytes = _uint16(directory, offset + 30);
        final fileCommentBytes = _uint16(directory, offset + 32);
        final recordBytes = 46 + nameBytes + extraBytes + fileCommentBytes;
        if (recordBytes < 46 || offset + recordBytes > directory.length) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP directory record exceeds its bounds.',
          );
        }
        parsedEntries++;
        if (parsedEntries > limits.maxEntries) {
          throw const ProjectBundleRecoveryException(
            'Project bundle exceeds the entry-count limit.',
          );
        }
        final flags = _uint16(directory, offset + 8);
        final compressedBytes = _uint32(directory, offset + 20);
        final expandedBytes = _uint32(directory, offset + 24);
        final diskStart = _uint16(directory, offset + 34);
        final localOffset = _uint32(directory, offset + 42);
        if (diskStart != 0 || (flags & 0x09) != 0) {
          throw const ProjectBundleRecoveryException(
            'Encrypted, data-descriptor, or multi-disk ZIP entries are unsupported.',
          );
        }
        if (compressedBytes > limits.maxCompressedEntryBytes ||
            expandedBytes > limits.maxExpandedEntryBytes) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP entry exceeds its pre-decode size limit.',
          );
        }
        centralEntries.add(
          _CentralDirectoryEntry(
            localOffset: localOffset,
            flags: flags,
            compression: _uint16(directory, offset + 10),
            crc32: _uint32(directory, offset + 16),
            compressedBytes: compressedBytes,
            expandedBytes: expandedBytes,
            nameBytes: List<int>.from(
              directory.sublist(offset + 46, offset + 46 + nameBytes),
            ),
          ),
        );
        offset += recordBytes;
      }
      if (offset != directory.length ||
          parsedEntries != entries ||
          parsedEntries != entriesOnDisk) {
        throw const ProjectBundleRecoveryException(
          'Project bundle ZIP directory count does not match its records.',
        );
      }
      centralEntries.sort((a, b) => a.localOffset.compareTo(b.localOffset));
      for (var index = 0; index < centralEntries.length; index++) {
        final central = centralEntries[index];
        final nextOffset = index + 1 < centralEntries.length
            ? centralEntries[index + 1].localOffset
            : directoryOffset;
        if (central.localOffset < 0 ||
            central.localOffset + 30 > nextOffset ||
            nextOffset > directoryOffset) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP local entry has an invalid extent.',
          );
        }
        await handle.setPosition(central.localOffset);
        final local = await handle.read(30);
        if (local.length != 30 || _uint32(local, 0) != 0x04034b50) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP local entry is invalid.',
          );
        }
        final localNameBytes = _uint16(local, 26);
        final localExtraBytes = _uint16(local, 28);
        final dataOffset =
            central.localOffset + 30 + localNameBytes + localExtraBytes;
        if (_uint16(local, 6) != central.flags ||
            _uint16(local, 8) != central.compression ||
            _uint32(local, 14) != central.crc32 ||
            _uint32(local, 18) != central.compressedBytes ||
            _uint32(local, 22) != central.expandedBytes ||
            dataOffset + central.compressedBytes != nextOffset) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP compressed extent is inconsistent.',
          );
        }
        await handle.setPosition(central.localOffset + 30);
        final localName = await handle.read(localNameBytes);
        if (!_sameBytes(localName, central.nameBytes)) {
          throw const ProjectBundleRecoveryException(
            'Project bundle ZIP local and central names differ.',
          );
        }
      }
    } finally {
      await handle.close();
    }
  }

  Map<String, ArchiveFile> _inspectArchive(_DecodedArchive decoded) {
    if (decoded.archive.length > limits.maxEntries) {
      throw const ProjectBundleRecoveryException(
        'Project bundle exceeds the entry-count limit.',
      );
    }
    final entries = <String, ArchiveFile>{};
    final canonicalKeys = <String>{};
    var expandedBytes = 0;
    for (var index = 0; index < decoded.archive.length; index++) {
      final entry = decoded.archive[index];
      final header = decoded.decoder.directory.fileHeaders[index];
      final rawName = header.filename;
      final pathError = _archivePathError(rawName, limits.maxPathLength);
      if (pathError != null) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains an unsafe archive path: $rawName ($pathError)',
        );
      }
      if (!entry.isFile || entry.isSymbolicLink) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains a non-regular entry: $rawName',
        );
      }
      if ((header.generalPurposeBitFlag & 0x1) != 0) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains an encrypted entry: $rawName',
        );
      }
      if (entry.compressionType != ArchiveFile.STORE &&
          entry.compressionType != ArchiveFile.DEFLATE) {
        throw ProjectBundleRecoveryException(
          'Project bundle uses unsupported compression: $rawName',
        );
      }
      final compressedBytes = header.compressedSize;
      final actualCompressedBytes = entry.rawContent?.length;
      if (compressedBytes == null ||
          compressedBytes < 0 ||
          compressedBytes > limits.maxCompressedEntryBytes ||
          actualCompressedBytes != compressedBytes ||
          actualCompressedBytes! > limits.maxCompressedEntryBytes) {
        throw ProjectBundleRecoveryException(
          'Project bundle entry exceeds the compressed-size limit: $rawName',
        );
      }
      if (entry.size < 0 || entry.size > limits.maxExpandedEntryBytes) {
        throw ProjectBundleRecoveryException(
          'Project bundle entry exceeds the expanded-size limit: $rawName',
        );
      }
      expandedBytes += entry.size;
      if (expandedBytes > limits.maxTotalExpandedBytes) {
        throw const ProjectBundleRecoveryException(
          'Project bundle exceeds the total expanded-size limit.',
        );
      }
      final key = _windowsCanonicalKey(rawName);
      if (!canonicalKeys.add(key) || entries.containsKey(rawName)) {
        throw ProjectBundleRecoveryException(
          'Project bundle contains a duplicate or aliased archive path: $rawName',
        );
      }
      entries[rawName] = entry;
    }
    for (final key in canonicalKeys) {
      var separator = key.lastIndexOf('/');
      while (separator > 0) {
        final ancestor = key.substring(0, separator);
        if (canonicalKeys.contains(ancestor)) {
          throw ProjectBundleRecoveryException(
            'Project bundle contains a file/ancestor path collision: $key',
          );
        }
        separator = ancestor.lastIndexOf('/');
      }
    }
    return entries;
  }

  Map<String, _ProjectBundleDescriptor> _parseDescriptors(Object? raw) {
    if (raw is! List) {
      throw const ProjectBundleRecoveryException(
        'Project bundle manifest files must be a list.',
      );
    }
    final descriptors = <String, _ProjectBundleDescriptor>{};
    final canonicalKeys = <String>{};
    final digestPattern = RegExp(r'^[0-9a-f]{64}$');
    for (final value in raw) {
      if (value is! Map) {
        throw const ProjectBundleRecoveryException(
          'Project bundle has a malformed file descriptor.',
        );
      }
      final map = Map<String, dynamic>.from(value);
      final path = map['path'];
      final kind = map['kind'];
      final bytes = map['bytes'];
      final digest = map['sha256'];
      if (map.length != 4 ||
          path is! String ||
          kind is! String ||
          bytes is! int ||
          bytes < 0 ||
          digest is! String ||
          !digestPattern.hasMatch(digest) ||
          _archivePathError(path, limits.maxPathLength) != null ||
          path == atlasProjectBundleManifestPath) {
        throw const ProjectBundleRecoveryException(
          'Project bundle has a malformed file descriptor.',
        );
      }
      if (!canonicalKeys.add(_windowsCanonicalKey(path)) ||
          descriptors.containsKey(path)) {
        throw ProjectBundleRecoveryException(
          'Project bundle manifest contains a duplicate or aliased path: $path',
        );
      }
      descriptors[path] = _ProjectBundleDescriptor(path, kind, bytes, digest);
    }
    return descriptors;
  }

  void _validateContents(
    Map<String, dynamic> manifest,
    Map<String, _ProjectBundleDescriptor> descriptors,
  ) {
    final contents = _map(manifest['contents'], 'manifest contents');
    if (contents['projectBundle'] != 'project_bundle.json' ||
        contents['manifest'] != atlasProjectBundleManifestPath ||
        contents['readme'] != 'README.md') {
      throw const ProjectBundleRecoveryException(
        'Project bundle is missing a required content pointer.',
      );
    }
    const pointerKinds = <String, String?>{
      'projectBundle': 'project_payload',
      'manifest': null,
      'readme': 'readme',
      'bootstrapContext': 'bootstrap',
      'bootstrapContextMarkdown': 'bootstrap',
      'summary': 'summary',
      'summaryInput': 'summary',
      'eventLogs': 'event_log',
      'changeLog': 'change_log',
      'changeSummaryEvidence': 'change_log',
      'changeSummary': 'change_log',
      'changeSummaryInput': 'change_log',
      'warnings': 'export_warnings',
      'cleanGitArchive': 'clean_git_archive',
    };
    for (final pointer in pointerKinds.entries) {
      final value = contents[pointer.key];
      if (value == null) continue;
      if (value is! String || value.isEmpty) {
        throw ProjectBundleRecoveryException(
          'Project bundle has an invalid ${pointer.key} content pointer.',
        );
      }
      if (pointer.key == 'manifest') {
        if (value != atlasProjectBundleManifestPath) {
          throw const ProjectBundleRecoveryException(
            'Project bundle manifest pointer is invalid.',
          );
        }
      } else if (descriptors[value]?.kind != pointer.value) {
        throw ProjectBundleRecoveryException(
          'Project bundle content pointer has the wrong kind: ${pointer.key}',
        );
      }
    }
    final documentFiles = contents['documentFiles'];
    final mediaFiles = contents['mediaFiles'];
    if (documentFiles is! int ||
        documentFiles < 0 ||
        descriptors.values.where((value) => value.kind == 'document').length !=
            documentFiles) {
      throw const ProjectBundleRecoveryException(
        'Document file count does not match the project bundle manifest.',
      );
    }
    if (mediaFiles is! int ||
        mediaFiles < 0 ||
        descriptors.values.where((value) => value.kind == 'media').length !=
            mediaFiles) {
      throw const ProjectBundleRecoveryException(
        'Media file count does not match the project bundle manifest.',
      );
    }
  }

  _StreamedEntry _streamEntry(
    ArchiveFile entry,
    _ExpansionBudget budget, {
    bool capture = false,
    int? maxCaptureBytes,
    File? output,
  }) {
    final sink = _BoundedEntrySink(
      maxEntryBytes: limits.maxExpandedEntryBytes,
      budget: budget,
      capture: capture,
      maxCaptureBytes: maxCaptureBytes,
      output: output,
    );
    try {
      final raw = entry.rawContent;
      if (raw == null) {
        throw ProjectBundleRecoveryException(
          'Project bundle entry could not be read: ${entry.name}',
        );
      }
      if (entry.compressionType == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, sink);
      } else if (entry.compressionType == ArchiveFile.STORE) {
        sink.writeInputStream(raw);
      } else {
        throw ProjectBundleRecoveryException(
          'Project bundle uses unsupported compression: ${entry.name}',
        );
      }
      final result = sink.finish();
      if (entry.crc32 != null && result.crc32 != entry.crc32) {
        throw ProjectBundleRecoveryException(
          'Project bundle CRC check failed for ${entry.name}.',
        );
      }
      return result;
    } finally {
      sink.close();
    }
  }

  List<int> _readEntryBytes(
    ArchiveFile entry,
    _ExpansionBudget budget, {
    required int maxBytes,
  }) {
    final result = _streamEntry(
      entry,
      budget,
      capture: true,
      maxCaptureBytes: maxBytes,
    );
    return result.captured!;
  }

  Map<String, dynamic> _decodeJson(List<int> bytes, String label) {
    try {
      return _map(jsonDecode(utf8.decode(bytes)), label);
    } on Object catch (error) {
      if (error is ProjectBundleRecoveryException) rethrow;
      throw ProjectBundleRecoveryException(
        'Project bundle has invalid $label.',
      );
    }
  }

  static Map<String, dynamic> _map(Object? value, String label) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw ProjectBundleRecoveryException(
      'Project bundle has an invalid $label.',
    );
  }

  static String _text(Object? value, String label) {
    if (value is String && value.trim().isNotEmpty) return value;
    throw ProjectBundleRecoveryException(
      'Project bundle has an invalid $label.',
    );
  }

  static String _safeStem(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'project' : safe;
  }
}

String? _archivePathError(String value, int maxLength) {
  if (value.isEmpty || value.length > maxLength) return 'invalid length';
  if (value.contains('\\')) return 'backslash separators are not canonical';
  if (value.startsWith('/') || value.startsWith('//')) return 'rooted path';
  if (value.contains(':')) return 'drive or alternate-data-stream path';
  final parts = value.split('/');
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
    caseSensitive: false,
  );
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return 'empty or dot part';
    if (part.endsWith('.') || part.endsWith(' ')) {
      return 'trailing dot or space';
    }
    if (part.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return 'control character';
    }
    if (RegExp(r'[<>"|?*]').hasMatch(part)) {
      return 'invalid Windows filename character';
    }
    if (reserved.hasMatch(part)) return 'reserved Windows device name';
  }
  return null;
}

String _windowsCanonicalKey(String value) => value.toLowerCase();

String _resolveContainedPath(Directory root, String archivePath) {
  final rootPath = p.absolute(p.normalize(root.path));
  final candidate = p.absolute(
    p.normalize(p.joinAll([rootPath, ...archivePath.split('/')])),
  );
  if (!p.isWithin(rootPath, candidate)) {
    throw ProjectBundleRecoveryException(
      'Project bundle entry escapes the staging root: $archivePath',
    );
  }
  return candidate;
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Future<String> _sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint32(List<int> bytes, int offset) =>
    _uint16(bytes, offset) | (_uint16(bytes, offset + 2) << 16);

class _DecodedArchive {
  final InputFileStream input;
  final ZipDecoder decoder;
  final Archive archive;

  const _DecodedArchive(this.input, this.decoder, this.archive);

  void close() {
    for (final entry in archive) {
      entry.closeSync();
    }
    input.closeSync();
  }
}

class _CentralDirectoryEntry {
  final int localOffset;
  final int flags;
  final int compression;
  final int crc32;
  final int compressedBytes;
  final int expandedBytes;
  final List<int> nameBytes;

  const _CentralDirectoryEntry({
    required this.localOffset,
    required this.flags,
    required this.compression,
    required this.crc32,
    required this.compressedBytes,
    required this.expandedBytes,
    required this.nameBytes,
  });
}

class _ValidatedProjectBundle {
  final String projectId;
  final String projectTitle;
  final Map<String, _ProjectBundleDescriptor> descriptors;
  final String manifestSha256;

  const _ValidatedProjectBundle(
    this.projectId,
    this.projectTitle,
    this.descriptors,
    this.manifestSha256,
  );
}

class _ProjectBundleDescriptor {
  final String path;
  final String kind;
  final int bytes;
  final String sha256;

  const _ProjectBundleDescriptor(this.path, this.kind, this.bytes, this.sha256);
}

class _ExpansionBudget {
  final int maximum;
  int used = 0;

  _ExpansionBudget(this.maximum);

  void add(int bytes) {
    used += bytes;
    if (used > maximum) {
      throw const ProjectBundleRecoveryException(
        'Project bundle exceeds the actual expanded-size limit.',
      );
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _BoundedEntrySink extends OutputStreamBase {
  final int maxEntryBytes;
  final _ExpansionBudget budget;
  final bool capture;
  final int? maxCaptureBytes;
  final RandomAccessFile? _output;
  final List<int>? _captured;
  final List<int> _history = <int>[];
  final _DigestSink _digestSink = _DigestSink();
  late final ByteConversionSink _hashSink;
  var _crc = 0xffffffff;
  var _finished = false;

  @override
  int length = 0;

  _BoundedEntrySink({
    required this.maxEntryBytes,
    required this.budget,
    required this.capture,
    required this.maxCaptureBytes,
    File? output,
  }) : _output = output?.openSync(mode: FileMode.write),
       _captured = capture ? <int>[] : null {
    _hashSink = sha256.startChunkedConversion(_digestSink);
  }

  @override
  void flush() => _output?.flushSync();

  @override
  void writeByte(int value) => writeBytes([value]);

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final count = len ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const ProjectBundleRecoveryException(
        'Project bundle decoder produced an invalid byte count.',
      );
    }
    if (length + count > maxEntryBytes) {
      throw const ProjectBundleRecoveryException(
        'Project bundle entry exceeds the actual expanded-size limit.',
      );
    }
    budget.add(count);
    final chunk = count == bytes.length ? bytes : bytes.sublist(0, count);
    length += count;
    _hashSink.add(chunk);
    _updateCrc(chunk);
    _history.addAll(chunk);
    if (_history.length > 32768) {
      _history.removeRange(0, _history.length - 32768);
    }
    if (_captured != null) {
      if (_captured.length + count > (maxCaptureBytes ?? maxEntryBytes)) {
        throw const ProjectBundleRecoveryException(
          'Project bundle metadata exceeds the capture limit.',
        );
      }
      _captured.addAll(chunk);
    }
    _output?.writeFromSync(chunk);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 64 * 1024;
    while (!stream.isEOS) {
      final count = stream.length < chunkSize ? stream.length : chunkSize;
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  /// The archive inflater uses this dynamically for its bounded DEFLATE
  /// history window even though OutputStreamBase does not declare it.
  List<int> subset(int start, [int? end]) {
    final absoluteStart = start < 0 ? length + start : start;
    final absoluteEnd = end == null
        ? length
        : end < 0
        ? length + end
        : end;
    final historyStart = length - _history.length;
    if (absoluteStart < historyStart ||
        absoluteEnd < absoluteStart ||
        absoluteEnd > length) {
      throw const ProjectBundleRecoveryException(
        'Project bundle contains an invalid DEFLATE history reference.',
      );
    }
    return _history.sublist(
      absoluteStart - historyStart,
      absoluteEnd - historyStart,
    );
  }

  @override
  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >> 8);
  }

  @override
  void writeUint32(int value) {
    writeUint16(value);
    writeUint16(value >> 16);
  }

  @override
  void writeUint64(int value) {
    writeUint32(value);
    writeUint32(value >> 32);
  }

  void _updateCrc(List<int> bytes) {
    for (final byte in bytes) {
      _crc = _crc32Table[(_crc ^ byte) & 0xff] ^ (_crc >> 8);
    }
  }

  _StreamedEntry finish() {
    if (!_finished) {
      _hashSink.close();
      _finished = true;
    }
    flush();
    return _StreamedEntry(
      length,
      _digestSink.value!.toString(),
      (_crc ^ 0xffffffff) & 0xffffffff,
      _captured,
    );
  }

  void close() {
    if (!_finished) {
      _hashSink.close();
      _finished = true;
    }
    _output?.closeSync();
  }
}

class _StreamedEntry {
  final int bytes;
  final String sha256;
  final int crc32;
  final List<int>? captured;

  const _StreamedEntry(this.bytes, this.sha256, this.crc32, this.captured);
}

final List<int> _crc32Table = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1;
  }
  return value;
}, growable: false);

class ProjectBundleRecoveryException implements Exception {
  final String message;

  const ProjectBundleRecoveryException(this.message);

  @override
  String toString() => 'ProjectBundleRecoveryException: $message';
}

class ProjectBundleStagingReport {
  final String sourceBundlePath;
  final String stagingPath;
  final String projectId;
  final String projectTitle;
  final int stagedFiles;

  const ProjectBundleStagingReport({
    required this.sourceBundlePath,
    required this.stagingPath,
    required this.projectId,
    required this.projectTitle,
    required this.stagedFiles,
  });

  Map<String, Object?> toJson() => {
    'schema': 'project_atlas_project_bundle_stage_v1',
    'sourceBundlePath': sourceBundlePath,
    'stagingPath': stagingPath,
    'project': {'id': projectId, 'title': projectTitle},
    'stagedFiles': stagedFiles,
    'stagedAt': DateTime.now().toUtc().toIso8601String(),
    'liveAtlasChanged': false,
  };
}
