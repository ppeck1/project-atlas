import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

const recoveryArtifactLifecycleSchema =
    'project_atlas_recovery_artifact_lifecycle_v1';
const recoveryArtifactLifecycleMarkerFile = '.atlas_artifact_incomplete.json';
const recoveryArtifactFailedMarkerFile = '.atlas_artifact_failed.json';
const recoveryArtifactMaxMarkerBytes = 4096;
const recoveryArtifactMaxDeletionEntries = 65536;
const recoveryArtifactMaxDeletionBytes = 16 * 1024 * 1024 * 1024;
const recoveryArtifactMaxScannedChildren = 8192;
const recoveryArtifactMaxCleanupCandidates = 256;

enum RecoveryArtifactKind {
  fullBackup('full_backup'),
  fullBackupStagingRestore('full_backup_staging_restore'),
  projectBundleStaging('project_bundle_staging');

  final String wireName;

  const RecoveryArtifactKind(this.wireName);
}

enum RecoveryArtifactState {
  incomplete('incomplete'),
  failed('failed');

  final String wireName;

  const RecoveryArtifactState(this.wireName);
}

class RecoveryArtifactMarker {
  final RecoveryArtifactKind kind;
  final RecoveryArtifactState state;
  final String operationId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RecoveryArtifactMarker({
    required this.kind,
    required this.state,
    required this.operationId,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toJson() => {
    'schema': recoveryArtifactLifecycleSchema,
    'kind': kind.wireName,
    'state': state.wireName,
    'operationId': operationId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static Future<RecoveryArtifactMarker> read(File file) async {
    final bytes = <int>[];
    await for (final chunk in file.openRead(
      0,
      recoveryArtifactMaxMarkerBytes + 1,
    )) {
      bytes.addAll(chunk);
      if (bytes.length > recoveryArtifactMaxMarkerBytes) {
        throw const FormatException('Lifecycle marker exceeds its byte limit.');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('Lifecycle marker root must be an object.');
    }
    final marker = decoded.map((key, value) => MapEntry('$key', value));
    const expectedKeys = {
      'schema',
      'kind',
      'state',
      'operationId',
      'createdAt',
      'updatedAt',
    };
    if (marker.length != expectedKeys.length ||
        !marker.keys.toSet().containsAll(expectedKeys)) {
      throw const FormatException(
        'Lifecycle marker fields do not match the schema.',
      );
    }
    if (marker['schema'] != recoveryArtifactLifecycleSchema) {
      throw const FormatException('Unsupported lifecycle marker schema.');
    }
    final kind = RecoveryArtifactKind.values
        .where((candidate) => candidate.wireName == marker['kind'])
        .firstOrNull;
    final state = RecoveryArtifactState.values
        .where((candidate) => candidate.wireName == marker['state'])
        .firstOrNull;
    final operationId = marker['operationId'];
    final createdAt = _parseTimestamp(marker['createdAt']);
    final updatedAt = _parseTimestamp(marker['updatedAt']);
    if (kind == null ||
        state == null ||
        operationId is! String ||
        !_operationIdPattern.hasMatch(operationId) ||
        createdAt == null ||
        updatedAt == null ||
        updatedAt.isBefore(createdAt)) {
      throw const FormatException('Lifecycle marker values are invalid.');
    }
    return RecoveryArtifactMarker(
      kind: kind,
      state: state,
      operationId: operationId,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static DateTime? _parseTimestamp(Object? value) {
    if (value is! String || value.length > 32 || !value.endsWith('Z')) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    return parsed != null &&
            parsed.isUtc &&
            parsed.toUtc().toIso8601String() == value
        ? parsed
        : null;
  }
}

class RecoveryArtifactDeletionLimits {
  final int maxEntries;
  final int maxBytes;

  const RecoveryArtifactDeletionLimits({
    this.maxEntries = 4096,
    this.maxBytes = 1024 * 1024 * 1024,
  });
}

class RecoveryArtifactCleanupLimits extends RecoveryArtifactDeletionLimits {
  final int maxScannedChildren;
  final int maxCandidates;
  final Duration minimumAge;

  const RecoveryArtifactCleanupLimits({
    super.maxEntries,
    super.maxBytes,
    this.maxScannedChildren = 1024,
    this.maxCandidates = 64,
    this.minimumAge = const Duration(hours: 1),
  });
}

enum RecoveryArtifactCleanupDisposition {
  deleted,
  retainedActive,
  retainedTooNew,
  refusedInvalidMarker,
  refusedLink,
  refusedBudget,
  refusedMutation,
  deleteFailed,
}

class RecoveryArtifactCleanupResult {
  final Directory artifact;
  final RecoveryArtifactCleanupDisposition disposition;
  final int entries;
  final int bytes;

  const RecoveryArtifactCleanupResult({
    required this.artifact,
    required this.disposition,
    this.entries = 0,
    this.bytes = 0,
  });
}

class RecoveryArtifactCleanupReport {
  final int scannedChildren;
  final int matchedCandidates;
  final bool scanLimitReached;
  final bool candidateLimitReached;
  final List<RecoveryArtifactCleanupResult> results;

  const RecoveryArtifactCleanupReport({
    required this.scannedChildren,
    required this.matchedCandidates,
    required this.scanLimitReached,
    required this.candidateLimitReached,
    required this.results,
  });

  int get deletedCount => results
      .where(
        (result) =>
            result.disposition == RecoveryArtifactCleanupDisposition.deleted,
      )
      .length;
}

/// An opaque, checksummed snapshot of one regular file or real directory.
///
/// Retention callers may show the public size and timestamp fields in a
/// preview, but deletion must return this exact object to
/// [RecoveryArtifactLifecycle.deletePreviewedArtifact]. The lifecycle service
/// re-snapshots the path before deleting anything.
class RecoveryArtifactDeletionPreview {
  final FileSystemEntity entity;
  final Directory trustedParent;
  final int entries;
  final int bytes;
  final DateTime observedAt;
  final String snapshotId;
  final FileSystemEntityType _type;
  final _ArtifactSnapshot? _directorySnapshot;
  final _SnapshotEntry? _fileSnapshot;

  const RecoveryArtifactDeletionPreview._({
    required this.entity,
    required this.trustedParent,
    required this.entries,
    required this.bytes,
    required this.observedAt,
    required this.snapshotId,
    required FileSystemEntityType type,
    required _ArtifactSnapshot? directorySnapshot,
    required _SnapshotEntry? fileSnapshot,
  }) : _type = type,
       _directorySnapshot = directorySnapshot,
       _fileSnapshot = fileSnapshot;
}

class RecoveryArtifactDeletionResult {
  final FileSystemEntity entity;
  final RecoveryArtifactCleanupDisposition disposition;
  final int entries;
  final int bytes;

  const RecoveryArtifactDeletionResult({
    required this.entity,
    required this.disposition,
    this.entries = 0,
    this.bytes = 0,
  });
}

typedef RecoveryArtifactDelete =
    Future<void> Function(Directory artifactDirectory);
typedef RecoveryArtifactDeleteEntry =
    Future<void> Function(FileSystemEntity entity);
typedef RecoveryArtifactOperationId = String Function();
typedef RecoveryArtifactCreateMarker = Future<void> Function(File marker);
typedef RecoveryArtifactWriteMarker =
    Future<void> Function(File marker, String contents);
typedef RecoveryArtifactRename =
    Future<Directory> Function(Directory source, String destination);
typedef RecoveryArtifactCleanupRecheckHook =
    Future<void> Function(Directory artifact);

class RecoveryArtifactLifecycle {
  static final Set<String> _activeOperationIds = <String>{};

  final DateTime Function() _clock;
  final RecoveryArtifactDelete? _deleteArtifact;
  final RecoveryArtifactDeleteEntry _deleteEntry;
  final RecoveryArtifactOperationId _operationId;
  final RecoveryArtifactCreateMarker _createMarker;
  final RecoveryArtifactWriteMarker _writeMarker;
  final RecoveryArtifactRename _rename;
  final RecoveryArtifactCleanupRecheckHook? _cleanupRecheckHook;
  final RecoveryArtifactDeletionLimits failureDeletionLimits;

  RecoveryArtifactLifecycle({
    DateTime Function()? clock,
    RecoveryArtifactDelete? deleteArtifact,
    RecoveryArtifactDeleteEntry? deleteEntry,
    RecoveryArtifactOperationId? operationId,
    RecoveryArtifactCreateMarker? createMarker,
    RecoveryArtifactWriteMarker? writeMarker,
    RecoveryArtifactRename? rename,
    RecoveryArtifactCleanupRecheckHook? cleanupRecheckHook,
    this.failureDeletionLimits = const RecoveryArtifactDeletionLimits(),
  }) : _clock = clock ?? DateTime.now,
       _deleteArtifact = deleteArtifact,
       _deleteEntry =
           deleteEntry ??
           ((entity) async {
             await entity.delete();
           }),
       _operationId = operationId ?? _randomOperationId,
       _createMarker =
           createMarker ??
           ((marker) async {
             await marker.create(exclusive: true);
           }),
       _writeMarker =
           writeMarker ??
           ((marker, contents) => marker.writeAsString(contents, flush: true)),
       _rename =
           rename ?? ((source, destination) => source.rename(destination)),
       _cleanupRecheckHook = cleanupRecheckHook {
    _validateDeletionLimits(failureDeletionLimits);
  }

  Future<RecoveryArtifactOperation> begin(
    Directory finalDirectory, {
    required RecoveryArtifactKind kind,
  }) async {
    final operationId = _operationId();
    if (!_operationIdPattern.hasMatch(operationId)) {
      throw ArgumentError.value(
        operationId,
        'operationId',
        'Operation IDs must be 32 lowercase hexadecimal characters.',
      );
    }
    if (!_activeOperationIds.add(operationId)) {
      throw StateError('The recovery artifact operation ID is already active.');
    }
    try {
      if (!await finalDirectory.parent.exists()) {
        throw FileSystemException(
          'The recovery artifact parent directory does not exist.',
          finalDirectory.parent.path,
        );
      }
      if (await finalDirectory.exists()) {
        throw FileSystemException(
          'Refusing to overwrite an existing recovery artifact.',
          finalDirectory.path,
        );
      }
      final artifactDirectory = Directory(
        '${finalDirectory.path}.atlas-incomplete-$operationId',
      );
      if (await FileSystemEntity.type(
            artifactDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Refusing to adopt an existing recovery artifact.',
          artifactDirectory.path,
        );
      }
      await artifactDirectory.create();
      final createdAt = _clock().toUtc();
      final operation = RecoveryArtifactOperation._(
        lifecycle: this,
        artifactDirectory: artifactDirectory,
        finalDirectory: finalDirectory,
        kind: kind,
        operationId: operationId,
        createdAt: createdAt,
      );
      // A create/write fault deliberately leaves the typed sibling path in
      // place. Persisted cleanup refuses it unless a complete owned marker can
      // be read.
      await _createMarker(operation.marker);
      await operation._writeIncompleteMarker();
      await operation._assertOwnedIncompleteMarker();
      return operation;
    } on Object {
      _activeOperationIds.remove(operationId);
      rethrow;
    }
  }

  Future<RecoveryArtifactCleanupReport> cleanupPersistedArtifacts(
    Directory parent, {
    RecoveryArtifactCleanupLimits limits =
        const RecoveryArtifactCleanupLimits(),
  }) async {
    _validateCleanupLimits(limits);
    final results = <RecoveryArtifactCleanupResult>[];
    var scanned = 0;
    var matched = 0;
    var scanLimitReached = false;
    var candidateLimitReached = false;
    var remainingEntries = limits.maxEntries;
    var remainingBytes = limits.maxBytes;
    var deletionBudgetExhausted = false;
    if (!await parent.exists()) {
      return const RecoveryArtifactCleanupReport(
        scannedChildren: 0,
        matchedCandidates: 0,
        scanLimitReached: false,
        candidateLimitReached: false,
        results: [],
      );
    }
    try {
      await _assertDirectoryChainSafe(parent.path);
    } on _ArtifactLinkException {
      throw FileSystemException(
        'Recovery artifact cleanup root must be a real directory.',
        parent.path,
      );
    }
    await for (final entity in parent.list(followLinks: false)) {
      if (scanned == limits.maxScannedChildren) {
        scanLimitReached = true;
        break;
      }
      scanned++;
      final parsed = _parseArtifactName(p.basename(entity.path));
      if (parsed == null) continue;
      matched++;
      if (results.length == limits.maxCandidates) {
        candidateLimitReached = true;
        continue;
      }
      final artifact = Directory(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.directory) {
        results.add(
          RecoveryArtifactCleanupResult(
            artifact: artifact,
            disposition: RecoveryArtifactCleanupDisposition.refusedLink,
          ),
        );
        continue;
      }
      if (deletionBudgetExhausted ||
          remainingEntries == 0 ||
          remainingBytes == 0) {
        results.add(
          RecoveryArtifactCleanupResult(
            artifact: artifact,
            disposition: RecoveryArtifactCleanupDisposition.refusedBudget,
          ),
        );
        deletionBudgetExhausted = true;
        continue;
      }
      final result = await _cleanupPersistedCandidate(
        artifact,
        parsed,
        limits: limits,
        deletionLimits: RecoveryArtifactDeletionLimits(
          maxEntries: remainingEntries,
          maxBytes: remainingBytes,
        ),
      );
      results.add(result);
      if (result.disposition ==
          RecoveryArtifactCleanupDisposition.refusedBudget) {
        deletionBudgetExhausted = true;
      } else {
        remainingEntries = max(0, remainingEntries - result.entries);
        remainingBytes = max(0, remainingBytes - result.bytes);
      }
    }
    return RecoveryArtifactCleanupReport(
      scannedChildren: scanned,
      matchedCandidates: matched,
      scanLimitReached: scanLimitReached,
      candidateLimitReached: candidateLimitReached,
      results: List.unmodifiable(results),
    );
  }

  /// Produces a bounded, no-follow snapshot suitable for an operator preview.
  ///
  /// Only a direct child of [trustedParent] can be previewed. Links, reparse
  /// points, unsupported filesystem entities, and paths outside that parent
  /// fail closed.
  Future<RecoveryArtifactDeletionPreview> previewArtifactForDeletion(
    FileSystemEntity entity, {
    required Directory trustedParent,
    RecoveryArtifactDeletionLimits limits =
        const RecoveryArtifactDeletionLimits(),
  }) async {
    _validateDeletionLimits(limits);
    final entityPath = p.normalize(p.absolute(entity.path));
    final parentPath = p.normalize(p.absolute(trustedParent.path));
    if (!p.equals(p.dirname(entityPath), parentPath)) {
      throw FileSystemException(
        'Recovery artifact must be a direct child of its trusted parent.',
        entity.path,
      );
    }
    await _assertDirectoryChainSafe(parentPath);
    final type = await FileSystemEntity.type(entityPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final directory = Directory(entityPath);
      await _assertArtifactRootSafe(directory, trustedParent: trustedParent);
      final snapshot = await _snapshotArtifact(directory, limits);
      final stat = await directory.stat();
      if (stat.type != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Recovery artifact changed during preview.',
          entity.path,
        );
      }
      final observedMicros = snapshot.entries.values.fold<int>(
        stat.modified.microsecondsSinceEpoch,
        (latest, entry) => max(latest, entry.modifiedMicros),
      );
      return RecoveryArtifactDeletionPreview._(
        entity: directory,
        trustedParent: trustedParent,
        entries: snapshot.entries.length + 1,
        bytes: snapshot.bytes,
        observedAt: DateTime.fromMicrosecondsSinceEpoch(
          observedMicros,
          isUtc: true,
        ),
        snapshotId: _snapshotId(
          entityPath,
          type,
          stat.modified.microsecondsSinceEpoch,
          snapshot,
        ),
        type: type,
        directorySnapshot: snapshot,
        fileSnapshot: null,
      );
    }
    if (type == FileSystemEntityType.file) {
      if (limits.maxEntries < 1) {
        throw const _ArtifactBudgetException();
      }
      final file = File(entityPath);
      final snapshot = await _snapshotRegularFile(file, limits.maxBytes);
      return RecoveryArtifactDeletionPreview._(
        entity: file,
        trustedParent: trustedParent,
        entries: 1,
        bytes: snapshot.bytes,
        observedAt: DateTime.fromMicrosecondsSinceEpoch(
          snapshot.modifiedMicros,
          isUtc: true,
        ),
        snapshotId: _snapshotId(
          entityPath,
          type,
          snapshot.modifiedMicros,
          null,
          file: snapshot,
        ),
        type: type,
        directorySnapshot: null,
        fileSnapshot: snapshot,
      );
    }
    throw FileSystemException(
      'Recovery artifact must be a regular file or real directory.',
      entity.path,
    );
  }

  /// Deletes only if [preview] still describes the exact filesystem entity.
  ///
  /// A fresh full snapshot is compared before deletion. Directory deletion
  /// then uses the existing two-pass R11 deletion boundary, so mutation after
  /// the preview also fails closed.
  Future<RecoveryArtifactDeletionResult> deletePreviewedArtifact(
    RecoveryArtifactDeletionPreview preview, {
    RecoveryArtifactCleanupRecheckHook? mutationHook,
    RecoveryArtifactDeletionLimits limits =
        const RecoveryArtifactDeletionLimits(),
  }) async {
    _validateDeletionLimits(limits);
    RecoveryArtifactDeletionPreview current;
    try {
      current = await previewArtifactForDeletion(
        preview.entity,
        trustedParent: preview.trustedParent,
        limits: limits,
      );
    } on _ArtifactLinkException {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedLink,
      );
    } on _ArtifactBudgetException {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedBudget,
      );
    } on Object {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
      );
    }
    if (current.snapshotId != preview.snapshotId ||
        current._type != preview._type ||
        (preview._directorySnapshot != null &&
            current._directorySnapshot?.sameAs(preview._directorySnapshot) !=
                true)) {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
        entries: current.entries,
        bytes: current.bytes,
      );
    }
    await mutationHook?.call(
      preview._type == FileSystemEntityType.directory
          ? Directory(preview.entity.path)
          : Directory(preview.trustedParent.path),
    );
    if (preview._type == FileSystemEntityType.directory) {
      final result = await _boundedDelete(
        Directory(preview.entity.path),
        limits: limits,
        trustedParent: preview.trustedParent,
      );
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: result.disposition,
        entries: result.entries,
        bytes: result.bytes,
      );
    }
    try {
      final second = await previewArtifactForDeletion(
        preview.entity,
        trustedParent: preview.trustedParent,
        limits: limits,
      );
      if (second.snapshotId != preview.snapshotId ||
          second._fileSnapshot?.sameAs(preview._fileSnapshot!) != true) {
        return RecoveryArtifactDeletionResult(
          entity: preview.entity,
          disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
          entries: second.entries,
          bytes: second.bytes,
        );
      }
      await File(preview.entity.path).delete();
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.deleted,
        entries: 1,
        bytes: preview.bytes,
      );
    } on _ArtifactLinkException {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedLink,
      );
    } on _ArtifactBudgetException {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedBudget,
      );
    } on Object {
      return RecoveryArtifactDeletionResult(
        entity: preview.entity,
        disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
      );
    }
  }

  Future<RecoveryArtifactCleanupResult> _cleanupPersistedCandidate(
    Directory artifact,
    _ParsedArtifactName parsed, {
    required RecoveryArtifactCleanupLimits limits,
    required RecoveryArtifactDeletionLimits deletionLimits,
  }) async {
    if (_activeOperationIds.contains(parsed.operationId)) {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedActive,
      );
    }
    RecoveryArtifactMarker incomplete;
    RecoveryArtifactMarker? failed;
    try {
      await _assertArtifactRootSafe(artifact, trustedParent: artifact.parent);
      incomplete = await _readRegularLifecycleMarker(
        File(p.join(artifact.path, recoveryArtifactLifecycleMarkerFile)),
      );
      if (incomplete.operationId != parsed.operationId ||
          incomplete.state != RecoveryArtifactState.incomplete) {
        throw const FormatException('Marker does not own the artifact path.');
      }
      final failedFile = File(
        p.join(artifact.path, recoveryArtifactFailedMarkerFile),
      );
      if (parsed.state == RecoveryArtifactState.failed) {
        failed = await _readRegularLifecycleMarker(failedFile);
        if (failed.operationId != parsed.operationId ||
            failed.kind != incomplete.kind ||
            failed.createdAt != incomplete.createdAt ||
            failed.state != RecoveryArtifactState.failed) {
          throw const FormatException('Failed marker does not match.');
        }
      } else if (await FileSystemEntity.type(
            failedFile.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        failed = await _readRegularLifecycleMarker(failedFile);
        if (failed.operationId != parsed.operationId ||
            failed.kind != incomplete.kind ||
            failed.createdAt != incomplete.createdAt ||
            failed.state != RecoveryArtifactState.failed) {
          throw const FormatException('Failed marker does not match.');
        }
      }
    } on _ArtifactLinkException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.refusedLink,
      );
    } on Object {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.refusedInvalidMarker,
      );
    }
    final observedAt = failed?.updatedAt ?? incomplete.updatedAt;
    if (_clock().toUtc().difference(observedAt) < limits.minimumAge) {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedTooNew,
      );
    }
    return _boundedDelete(
      artifact,
      limits: deletionLimits,
      mutationHook: _cleanupRecheckHook,
      trustedParent: artifact.parent,
      activeOperationId: parsed.operationId,
    );
  }

  Future<RecoveryArtifactCleanupResult> _boundedDelete(
    Directory artifact, {
    required RecoveryArtifactDeletionLimits limits,
    RecoveryArtifactCleanupRecheckHook? mutationHook,
    Directory? trustedParent,
    String? activeOperationId,
  }) async {
    if (activeOperationId != null &&
        _activeOperationIds.contains(activeOperationId)) {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedActive,
      );
    }
    _ArtifactSnapshot first;
    try {
      await _assertArtifactRootSafe(artifact, trustedParent: trustedParent);
      first = await _snapshotArtifact(artifact, limits);
    } on _ArtifactActiveException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedActive,
      );
    } on _ArtifactLinkException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.refusedLink,
      );
    } on _ArtifactBudgetException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.refusedBudget,
      );
    } on Object {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.deleteFailed,
      );
    }
    await mutationHook?.call(artifact);
    try {
      if (activeOperationId != null &&
          _activeOperationIds.contains(activeOperationId)) {
        throw const _ArtifactActiveException();
      }
      await _assertArtifactRootSafe(artifact, trustedParent: trustedParent);
      final second = await _snapshotArtifact(artifact, limits);
      if (!first.sameAs(second)) {
        return RecoveryArtifactCleanupResult(
          artifact: artifact,
          disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
          entries: second.entries.length,
          bytes: second.bytes,
        );
      }
    } on _ArtifactActiveException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedActive,
        entries: first.entries.length,
        bytes: first.bytes,
      );
    } on Object {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
        entries: first.entries.length,
        bytes: first.bytes,
      );
    }
    try {
      if (_deleteArtifact != null) {
        if (activeOperationId != null &&
            _activeOperationIds.contains(activeOperationId)) {
          throw const _ArtifactActiveException();
        }
        await _assertArtifactRootSafe(artifact, trustedParent: trustedParent);
        await _deleteArtifact(artifact);
      } else {
        final paths = first.entries.keys.toList()
          ..sort((left, right) {
            final depth = p.split(right).length.compareTo(p.split(left).length);
            return depth != 0 ? depth : right.compareTo(left);
          });
        for (final relativePath in paths) {
          if (activeOperationId != null &&
              _activeOperationIds.contains(activeOperationId)) {
            throw const _ArtifactActiveException();
          }
          final absolutePath = p.join(artifact.path, relativePath);
          final expected = first.entries[relativePath]!;
          await _assertDeletionPathSafe(
            artifact,
            absolutePath,
            expected,
            trustedParent: trustedParent,
          );
          await _deleteEntry(_entityForType(absolutePath, expected.type));
        }
        if (activeOperationId != null &&
            _activeOperationIds.contains(activeOperationId)) {
          throw const _ArtifactActiveException();
        }
        await _assertArtifactRootSafe(artifact, trustedParent: trustedParent);
        await _deleteEntry(artifact);
      }
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.deleted,
        entries: first.entries.length,
        bytes: first.bytes,
      );
    } on _ArtifactActiveException {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.retainedActive,
        entries: first.entries.length,
        bytes: first.bytes,
      );
    } on Object {
      return RecoveryArtifactCleanupResult(
        artifact: artifact,
        disposition: RecoveryArtifactCleanupDisposition.deleteFailed,
        entries: first.entries.length,
        bytes: first.bytes,
      );
    }
  }

  static String _randomOperationId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static void _releaseActive(String operationId) {
    _activeOperationIds.remove(operationId);
  }
}

class RecoveryArtifactOperation {
  final RecoveryArtifactLifecycle _lifecycle;
  Directory _artifactDirectory;
  final Directory finalDirectory;
  final RecoveryArtifactKind kind;
  final String operationId;
  final DateTime createdAt;
  Future<void> _tail = Future.value();
  _OperationTerminalState _state = _OperationTerminalState.active;
  bool _promoted = false;

  RecoveryArtifactOperation._({
    required RecoveryArtifactLifecycle lifecycle,
    required Directory artifactDirectory,
    required this.finalDirectory,
    required this.kind,
    required this.operationId,
    required this.createdAt,
  }) : _lifecycle = lifecycle,
       _artifactDirectory = artifactDirectory;

  Directory get artifactDirectory => _artifactDirectory;

  Directory get failedDirectory =>
      Directory('${finalDirectory.path}.atlas-failed-$operationId');

  File get marker => File(
    p.join(_artifactDirectory.path, recoveryArtifactLifecycleMarkerFile),
  );

  File get failedMarker =>
      File(p.join(_artifactDirectory.path, recoveryArtifactFailedMarkerFile));

  Future<void> complete() => _serialize(() async {
    if (_state == _OperationTerminalState.completed) return;
    if (_state == _OperationTerminalState.failed) {
      throw StateError('A failed recovery artifact cannot be completed.');
    }
    await _assertOwnedIncompleteMarker();
    if (!_promoted) {
      if (await FileSystemEntity.type(
            finalDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Refusing to overwrite the final recovery artifact.',
          finalDirectory.path,
        );
      }
      _artifactDirectory = await _lifecycle._rename(
        _artifactDirectory,
        finalDirectory.path,
      );
      _promoted = true;
    }
    await _assertOwnedIncompleteMarker();
    await marker.delete();
    _state = _OperationTerminalState.completed;
    RecoveryArtifactLifecycle._releaseActive(operationId);
  });

  Future<void> fail() => _serialize(() async {
    if (_state != _OperationTerminalState.active) return;
    _state = _OperationTerminalState.failed;
    try {
      try {
        await _assertOwnedIncompleteMarker();
        await _publishFailedMarker();
      } on Object {
        return;
      }
      try {
        if (await FileSystemEntity.type(
              failedDirectory.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          return;
        }
        _artifactDirectory = await _lifecycle._rename(
          _artifactDirectory,
          failedDirectory.path,
        );
        _promoted = false;
      } on Object {
        return;
      }
      await _lifecycle._boundedDelete(
        _artifactDirectory,
        limits: _lifecycle.failureDeletionLimits,
        trustedParent: finalDirectory.parent,
      );
    } finally {
      RecoveryArtifactLifecycle._releaseActive(operationId);
    }
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return (() async {
      await previous;
      try {
        return await action();
      } finally {
        done.complete();
      }
    })();
  }

  Future<void> _writeIncompleteMarker() async {
    final payload = RecoveryArtifactMarker(
      kind: kind,
      state: RecoveryArtifactState.incomplete,
      operationId: operationId,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await _lifecycle._writeMarker(marker, jsonEncode(payload.toJson()));
  }

  Future<void> _publishFailedMarker() async {
    final observedAt = _lifecycle._clock().toUtc();
    final payload = RecoveryArtifactMarker(
      kind: kind,
      state: RecoveryArtifactState.failed,
      operationId: operationId,
      createdAt: createdAt,
      updatedAt: observedAt.isBefore(createdAt) ? createdAt : observedAt,
    );
    // Creating the final name exclusively is the ownership boundary. Never use
    // an exists-check followed by rename: rename can replace a raced file on
    // some platforms. If the subsequent write is partial, the valid incomplete
    // marker and typed sibling path remain the fail-closed classification.
    await _lifecycle._createMarker(failedMarker);
    await _lifecycle._writeMarker(failedMarker, jsonEncode(payload.toJson()));
  }

  Future<void> _assertOwnedIncompleteMarker() async {
    final current = await RecoveryArtifactMarker.read(marker);
    if (current.kind != kind ||
        current.operationId != operationId ||
        current.createdAt != createdAt ||
        current.updatedAt != createdAt ||
        current.state != RecoveryArtifactState.incomplete) {
      throw const FileSystemException(
        'Recovery artifact lifecycle ownership marker changed.',
      );
    }
  }
}

enum _OperationTerminalState { active, completed, failed }

final RegExp _operationIdPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _artifactNamePattern = RegExp(
  r'^(.+)\.atlas-(incomplete|failed)-([0-9a-f]{32})$',
);

class _ParsedArtifactName {
  final RecoveryArtifactState state;
  final String operationId;

  const _ParsedArtifactName(this.state, this.operationId);
}

_ParsedArtifactName? _parseArtifactName(String name) {
  final match = _artifactNamePattern.firstMatch(name);
  if (match == null) return null;
  final finalName = match.group(1)!;
  if (finalName == '.' ||
      finalName == '..' ||
      finalName.contains('/') ||
      finalName.contains('\\') ||
      _artifactNamePattern.hasMatch(finalName)) {
    return null;
  }
  return _ParsedArtifactName(
    match.group(2) == 'failed'
        ? RecoveryArtifactState.failed
        : RecoveryArtifactState.incomplete,
    match.group(3)!,
  );
}

Future<RecoveryArtifactMarker> _readRegularLifecycleMarker(File marker) async {
  final type = await FileSystemEntity.type(marker.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw const _ArtifactLinkException();
  }
  if (type != FileSystemEntityType.file) {
    throw const FormatException('Lifecycle marker must be a regular file.');
  }
  return RecoveryArtifactMarker.read(marker);
}

void _validateDeletionLimits(RecoveryArtifactDeletionLimits limits) {
  if (limits.maxEntries <= 0 ||
      limits.maxEntries > recoveryArtifactMaxDeletionEntries) {
    throw RangeError.range(
      limits.maxEntries,
      1,
      recoveryArtifactMaxDeletionEntries,
      'maxEntries',
    );
  }
  if (limits.maxBytes <= 0 ||
      limits.maxBytes > recoveryArtifactMaxDeletionBytes) {
    throw RangeError.range(
      limits.maxBytes,
      1,
      recoveryArtifactMaxDeletionBytes,
      'maxBytes',
    );
  }
}

void _validateCleanupLimits(RecoveryArtifactCleanupLimits limits) {
  _validateDeletionLimits(limits);
  if (limits.maxScannedChildren <= 0 ||
      limits.maxScannedChildren > recoveryArtifactMaxScannedChildren) {
    throw RangeError.range(
      limits.maxScannedChildren,
      1,
      recoveryArtifactMaxScannedChildren,
      'maxScannedChildren',
    );
  }
  if (limits.maxCandidates <= 0 ||
      limits.maxCandidates > recoveryArtifactMaxCleanupCandidates) {
    throw RangeError.range(
      limits.maxCandidates,
      1,
      recoveryArtifactMaxCleanupCandidates,
      'maxCandidates',
    );
  }
  if (limits.minimumAge <= Duration.zero) {
    throw ArgumentError.value(
      limits.minimumAge,
      'minimumAge',
      'minimumAge must be positive.',
    );
  }
}

class _SnapshotEntry {
  final FileSystemEntityType type;
  final int bytes;
  final int modifiedMicros;
  final String? sha256;

  const _SnapshotEntry(this.type, this.bytes, this.modifiedMicros, this.sha256);

  bool sameAs(_SnapshotEntry other) =>
      type == other.type &&
      bytes == other.bytes &&
      modifiedMicros == other.modifiedMicros &&
      sha256 == other.sha256;
}

Future<_SnapshotEntry> _snapshotRegularFile(File file, int maxBytes) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _ArtifactLinkException();
  }
  if (Platform.isWindows) {
    final nativePath = file.path.toNativeUtf16();
    try {
      final attributes = GetFileAttributes(nativePath);
      if (attributes == 0xffffffff ||
          attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) {
        throw const _ArtifactLinkException();
      }
    } finally {
      calloc.free(nativePath);
    }
  }
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size > maxBytes) {
    throw const _ArtifactBudgetException();
  }
  final digest = (await sha256.bind(file.openRead(0, stat.size)).first)
      .toString();
  final afterRead = await file.stat();
  if (afterRead.type != FileSystemEntityType.file ||
      afterRead.size != stat.size ||
      afterRead.modified != stat.modified) {
    throw const _ArtifactMutationException();
  }
  return _SnapshotEntry(
    FileSystemEntityType.file,
    stat.size,
    stat.modified.microsecondsSinceEpoch,
    digest,
  );
}

String _snapshotId(
  String path,
  FileSystemEntityType type,
  int rootModifiedMicros,
  _ArtifactSnapshot? directory, {
  _SnapshotEntry? file,
}) {
  final entries = <Map<String, Object?>>[];
  if (directory != null) {
    final sorted = directory.entries.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in sorted) {
      entries.add({
        'path': entry.key,
        'type': entry.value.type.toString(),
        'bytes': entry.value.bytes,
        'modifiedMicros': entry.value.modifiedMicros,
        'sha256': entry.value.sha256,
      });
    }
  }
  final canonical = {
    'path': p.normalize(p.absolute(path)),
    'type': type.toString(),
    'rootModifiedMicros': rootModifiedMicros,
    'fileBytes': file?.bytes,
    'fileSha256': file?.sha256,
    'entries': entries,
  };
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

class _ArtifactSnapshot {
  final Map<String, _SnapshotEntry> entries;
  final int bytes;

  const _ArtifactSnapshot(this.entries, this.bytes);

  bool sameAs(_ArtifactSnapshot other) {
    if (bytes != other.bytes || entries.length != other.entries.length) {
      return false;
    }
    for (final entry in entries.entries) {
      final candidate = other.entries[entry.key];
      if (candidate == null || !entry.value.sameAs(candidate)) return false;
    }
    return true;
  }
}

Future<_ArtifactSnapshot> _snapshotArtifact(
  Directory artifact,
  RecoveryArtifactDeletionLimits limits,
) async {
  final entries = <String, _SnapshotEntry>{};
  var bytes = 0;
  await for (final entity in artifact.list(
    recursive: true,
    followLinks: false,
  )) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory)) {
      throw const _ArtifactLinkException();
    }
    final relativePath = p.relative(entity.path, from: artifact.path);
    if (p.isAbsolute(relativePath) ||
        relativePath == '..' ||
        relativePath.startsWith('..${p.separator}')) {
      throw const _ArtifactLinkException();
    }
    final stat = await entity.stat();
    final entryBytes = type == FileSystemEntityType.file ? stat.size : 0;
    bytes += entryBytes;
    if (entries.length + 1 > limits.maxEntries || bytes > limits.maxBytes) {
      throw const _ArtifactBudgetException();
    }
    String? digest;
    if (type == FileSystemEntityType.file) {
      digest =
          (await sha256.bind(File(entity.path).openRead(0, entryBytes)).first)
              .toString();
      final afterRead = await entity.stat();
      if (afterRead.type != FileSystemEntityType.file ||
          afterRead.size != stat.size ||
          afterRead.modified != stat.modified) {
        throw const _ArtifactMutationException();
      }
    }
    entries[relativePath] = _SnapshotEntry(
      type,
      entryBytes,
      stat.modified.microsecondsSinceEpoch,
      digest,
    );
  }
  return _ArtifactSnapshot(Map.unmodifiable(entries), bytes);
}

Future<void> _assertArtifactRootSafe(
  Directory artifact, {
  Directory? trustedParent,
}) async {
  final artifactPath = p.normalize(p.absolute(artifact.path));
  if (trustedParent != null) {
    final parentPath = p.normalize(p.absolute(trustedParent.path));
    if (!p.equals(p.dirname(artifactPath), parentPath)) {
      throw const _ArtifactLinkException();
    }
    await _assertDirectoryChainSafe(parentPath);
  }
  await _assertDirectoryChainSafe(artifactPath);
}

Future<void> _assertDirectoryChainSafe(String directoryPath) async {
  final normalized = p.normalize(p.absolute(directoryPath));
  String resolved;
  try {
    resolved = p.normalize(
      p.absolute(await Directory(normalized).resolveSymbolicLinks()),
    );
  } on Object {
    throw const _ArtifactLinkException();
  }
  await _assertRealDirectoryChain(normalized);
  if (!p.equals(normalized, resolved)) {
    // Windows canonicalization expands valid 8.3 path components (for example,
    // RUNNER~1) even when no link is present. Validate the canonical chain as
    // well instead of treating that textual difference as proof of a link.
    await _assertRealDirectoryChain(resolved);
  }
}

Future<void> _assertRealDirectoryChain(String directoryPath) async {
  final parts = p.split(directoryPath);
  if (parts.isEmpty) throw const _ArtifactLinkException();
  var current = parts.first;
  await _assertRealDirectoryComponent(current);
  for (final part in parts.skip(1)) {
    current = p.join(current, part);
    await _assertRealDirectoryComponent(current);
  }
}

Future<void> _assertRealDirectoryComponent(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _ArtifactLinkException();
  }
  if (!Platform.isWindows) return;

  final nativePath = path.toNativeUtf16();
  try {
    final attributes = GetFileAttributes(nativePath);
    if (attributes == 0xffffffff ||
        attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) {
      // Junctions, symbolic links, mount points, and other reparse-backed
      // directories are not valid cleanup ancestors.
      throw const _ArtifactLinkException();
    }
  } finally {
    calloc.free(nativePath);
  }
}

Future<void> _assertDeletionPathSafe(
  Directory artifact,
  String absolutePath,
  _SnapshotEntry expected, {
  Directory? trustedParent,
}) async {
  await _assertArtifactRootSafe(artifact, trustedParent: trustedParent);
  final rootPath = p.normalize(p.absolute(artifact.path));
  final targetPath = p.normalize(p.absolute(absolutePath));
  if (!p.isWithin(rootPath, targetPath)) {
    throw const _ArtifactLinkException();
  }
  final relativePath = p.relative(targetPath, from: rootPath);
  final parts = p.split(relativePath);
  var ancestor = rootPath;
  for (final part in parts.take(parts.length - 1)) {
    ancestor = p.join(ancestor, part);
    if (await FileSystemEntity.type(ancestor, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const _ArtifactLinkException();
    }
  }
  if (await FileSystemEntity.type(targetPath, followLinks: false) !=
      expected.type) {
    throw const FileSystemException(
      'Recovery artifact changed during deletion.',
    );
  }
}

FileSystemEntity _entityForType(String path, FileSystemEntityType type) {
  if (type == FileSystemEntityType.directory) return Directory(path);
  if (type == FileSystemEntityType.file) return File(path);
  return Link(path);
}

class _ArtifactLinkException implements Exception {
  const _ArtifactLinkException();
}

class _ArtifactBudgetException implements Exception {
  const _ArtifactBudgetException();
}

class _ArtifactMutationException implements Exception {
  const _ArtifactMutationException();
}

class _ArtifactActiveException implements Exception {
  const _ArtifactActiveException();
}
