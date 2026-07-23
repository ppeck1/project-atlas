import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'atlas_full_backup_service.dart';
import 'atlas_live_recovery_service.dart';
import 'recovery_artifact_lifecycle.dart';
import 'recovery_artifact_lock.dart';

const recoveryArtifactRetentionDefaultBytes = 10 * 1024 * 1024 * 1024;
const recoveryArtifactRetentionMaxScannedEntities = 8192;
const recoveryArtifactRetentionMaxCandidates = 256;
const recoveryArtifactRetentionMaxMetadataBytes = 64 * 1024;

enum RecoveryRetentionArtifactKind {
  safetyBackup,
  failedSafetyBackup,
  rollback,
  stagingRestore,
  failedStagingArtifact,
  failedPlan,
  failedRecoveryDiagnostic,
  orphanedAcknowledgement,
  temporaryHandoff,
  completionMarker,
}

enum RecoveryRetentionDisposition {
  candidate,
  retainedActivePlan,
  retainedNewestSafetyBackup,
  retainedPolicy,
}

enum RecoveryRetentionTrigger { age, size }

class RecoveryArtifactRetentionPolicy {
  final Duration maximumAge;
  final int maximumRetainedBytes;
  final int maxScannedEntities;
  final int maxCandidates;
  final RecoveryArtifactDeletionLimits perArtifactDeletionLimits;

  const RecoveryArtifactRetentionPolicy({
    this.maximumAge = const Duration(days: 30),
    this.maximumRetainedBytes = recoveryArtifactRetentionDefaultBytes,
    this.maxScannedEntities = 2048,
    this.maxCandidates = 128,
    this.perArtifactDeletionLimits = const RecoveryArtifactDeletionLimits(
      maxEntries: 16384,
      maxBytes: 8 * 1024 * 1024 * 1024,
    ),
  });

  void validate() {
    if (maximumAge <= Duration.zero) {
      throw ArgumentError.value(
        maximumAge,
        'maximumAge',
        'maximumAge must be positive.',
      );
    }
    if (maximumRetainedBytes <= 0 ||
        maximumRetainedBytes > recoveryArtifactMaxDeletionBytes) {
      throw RangeError.range(
        maximumRetainedBytes,
        1,
        recoveryArtifactMaxDeletionBytes,
        'maximumRetainedBytes',
      );
    }
    if (maxScannedEntities <= 0 ||
        maxScannedEntities > recoveryArtifactRetentionMaxScannedEntities) {
      throw RangeError.range(
        maxScannedEntities,
        1,
        recoveryArtifactRetentionMaxScannedEntities,
        'maxScannedEntities',
      );
    }
    if (maxCandidates <= 0 ||
        maxCandidates > recoveryArtifactRetentionMaxCandidates) {
      throw RangeError.range(
        maxCandidates,
        1,
        recoveryArtifactRetentionMaxCandidates,
        'maxCandidates',
      );
    }
    if (perArtifactDeletionLimits.maxEntries <= 0 ||
        perArtifactDeletionLimits.maxEntries >
            recoveryArtifactMaxDeletionEntries) {
      throw RangeError.range(
        perArtifactDeletionLimits.maxEntries,
        1,
        recoveryArtifactMaxDeletionEntries,
        'perArtifactDeletionLimits.maxEntries',
      );
    }
    if (perArtifactDeletionLimits.maxBytes <= 0 ||
        perArtifactDeletionLimits.maxBytes > recoveryArtifactMaxDeletionBytes) {
      throw RangeError.range(
        perArtifactDeletionLimits.maxBytes,
        1,
        recoveryArtifactMaxDeletionBytes,
        'perArtifactDeletionLimits.maxBytes',
      );
    }
  }
}

class RecoveryBackupInspection {
  final DateTime createdAt;

  const RecoveryBackupInspection({required this.createdAt});
}

typedef RecoveryBackupInspector =
    Future<RecoveryBackupInspection?> Function(Directory bundle);
typedef RecoveryPreparedPlanActivity = bool Function(File plan);

class RecoveryArtifactRetentionItem {
  final String id;
  final RecoveryRetentionArtifactKind kind;
  final RecoveryRetentionDisposition disposition;
  final String path;
  final int entries;
  final int bytes;
  final DateTime observedAt;
  final Set<RecoveryRetentionTrigger> triggers;
  final RecoveryArtifactDeletionPreview? _deletionPreview;

  const RecoveryArtifactRetentionItem._({
    required this.id,
    required this.kind,
    required this.disposition,
    required this.path,
    required this.entries,
    required this.bytes,
    required this.observedAt,
    required this.triggers,
    required RecoveryArtifactDeletionPreview? deletionPreview,
  }) : _deletionPreview = deletionPreview;
}

class RecoveryArtifactRetentionIssue {
  final String path;
  final String message;

  const RecoveryArtifactRetentionIssue({
    required this.path,
    required this.message,
  });
}

class RecoveryArtifactRetentionPreview {
  final Directory handoffRoot;
  final List<Directory> requestedSafetyBackupRoots;
  final List<Directory> inspectedSafetyBackupRoots;
  final RecoveryArtifactRetentionPolicy policy;
  final DateTime createdAt;
  final int scannedEntities;
  final bool scanLimitReached;
  final bool candidateLimitReached;
  final List<RecoveryArtifactRetentionItem> candidates;
  final List<RecoveryArtifactRetentionItem> retained;
  final List<RecoveryArtifactRetentionIssue> issues;

  const RecoveryArtifactRetentionPreview._({
    required this.handoffRoot,
    required this.requestedSafetyBackupRoots,
    required this.inspectedSafetyBackupRoots,
    required this.policy,
    required this.createdAt,
    required this.scannedEntities,
    required this.scanLimitReached,
    required this.candidateLimitReached,
    required this.candidates,
    required this.retained,
    required this.issues,
  });

  int get candidateBytes =>
      candidates.fold(0, (total, item) => total + item.bytes);
}

class RecoveryArtifactRetentionApplyItem {
  final RecoveryArtifactRetentionItem requested;
  final RecoveryArtifactCleanupDisposition disposition;

  const RecoveryArtifactRetentionApplyItem({
    required this.requested,
    required this.disposition,
  });
}

class RecoveryArtifactRetentionApplyReport {
  final List<RecoveryArtifactRetentionApplyItem> results;

  const RecoveryArtifactRetentionApplyReport(this.results);

  int get deletedCount => results
      .where(
        (result) =>
            result.disposition == RecoveryArtifactCleanupDisposition.deleted,
      )
      .length;
}

class RecoveryArtifactRetentionService {
  final Directory handoffRoot;
  final RecoveryBackupInspector _inspectBackup;
  final RecoveryArtifactLifecycle _lifecycle;
  final RecoveryPreparedPlanActivity _isPreparedPlanActive;
  final DateTime Function() _clock;

  RecoveryArtifactRetentionService({
    required this.handoffRoot,
    required RecoveryBackupInspector inspectBackup,
    RecoveryArtifactLifecycle? lifecycle,
    RecoveryPreparedPlanActivity? isPreparedPlanActive,
    DateTime Function()? clock,
  }) : _inspectBackup = inspectBackup,
       _lifecycle = lifecycle ?? RecoveryArtifactLifecycle(clock: clock),
       _isPreparedPlanActive =
           isPreparedPlanActive ??
           AtlasLiveRecoveryService.isPreparedPlanActive,
       _clock = clock ?? DateTime.now;

  static Future<RecoveryArtifactRetentionService> forCurrentAtlasApp() async {
    final backup = await AtlasFullBackupService.forCurrentAtlasApp();
    return RecoveryArtifactRetentionService(
      handoffRoot: await AtlasLiveRecoveryService.currentHandoffRoot(),
      inspectBackup: (bundle) async {
        final report = await backup.validateBundle(bundle);
        if (!report.isValid || report.manifest == null) return null;
        final createdAt = _parseUtcTimestamp(report.manifest!['createdAt']);
        return createdAt == null
            ? null
            : RecoveryBackupInspection(createdAt: createdAt);
      },
    );
  }

  Future<RecoveryArtifactRetentionPreview> preview({
    Iterable<Directory> safetyBackupRoots = const [],
    RecoveryArtifactRetentionPolicy policy =
        const RecoveryArtifactRetentionPolicy(),
  }) async {
    policy.validate();
    final requested = _normalizeDistinctRoots(safetyBackupRoots);
    return withRecoveryArtifactLock(
      handoffRoot,
      () => _previewLocked(requested, policy),
    );
  }

  Future<RecoveryArtifactRetentionApplyReport> apply(
    RecoveryArtifactRetentionPreview preview, {
    Iterable<String>? candidateIds,
  }) async {
    final selectedIds =
        candidateIds?.toSet() ??
        preview.candidates.map((item) => item.id).toSet();
    final knownIds = preview.candidates.map((item) => item.id).toSet();
    final unknown = selectedIds.difference(knownIds);
    if (unknown.isNotEmpty) {
      throw ArgumentError.value(
        unknown,
        'candidateIds',
        'Every selected candidate must come from the supplied preview.',
      );
    }
    return withRecoveryArtifactLock(handoffRoot, () async {
      final current = await _previewLocked(
        preview.requestedSafetyBackupRoots,
        preview.policy,
      );
      final currentById = {
        for (final item in current.candidates) item.id: item,
      };
      final results = <RecoveryArtifactRetentionApplyItem>[];
      final requestedItems =
          preview.candidates
              .where((item) => selectedIds.contains(item.id))
              .toList()
            ..sort((left, right) {
              final leftLast =
                  left.kind == RecoveryRetentionArtifactKind.completionMarker;
              final rightLast =
                  right.kind == RecoveryRetentionArtifactKind.completionMarker;
              if (leftLast != rightLast) return leftLast ? 1 : -1;
              return left.path.compareTo(right.path);
            });
      for (final requested in requestedItems) {
        final candidate = currentById[requested.id];
        final deletionPreview = candidate?._deletionPreview;
        if (candidate == null || deletionPreview == null) {
          results.add(
            RecoveryArtifactRetentionApplyItem(
              requested: requested,
              disposition: RecoveryArtifactCleanupDisposition.refusedMutation,
            ),
          );
          continue;
        }
        final result = await _lifecycle.deletePreviewedArtifact(
          deletionPreview,
          limits: preview.policy.perArtifactDeletionLimits,
        );
        results.add(
          RecoveryArtifactRetentionApplyItem(
            requested: requested,
            disposition: result.disposition,
          ),
        );
      }
      return RecoveryArtifactRetentionApplyReport(List.unmodifiable(results));
    });
  }

  Future<RecoveryArtifactRetentionPreview> _previewLocked(
    List<Directory> requestedSafetyRoots,
    RecoveryArtifactRetentionPolicy policy,
  ) async {
    final scan = _RetentionScan(policy);
    final discoveredSafetyRoots = <Directory>[...requestedSafetyRoots];
    final topLevel = await _boundedChildren(handoffRoot, scan);
    final byName = {
      for (final entity in topLevel) p.basename(entity.path): entity,
    };
    final activePlanIds = <String>{};
    final activePlanPaths = <String>{};
    final failedPlanPaths = <String>{};
    final untrustedPlanPaths = <String>{};
    final trustedCompletionPaths = <String>{};

    for (final entry in byName.entries) {
      if (_acceptedPattern.hasMatch(entry.key)) continue;
      final parsed = _parsePlanArtifactName(entry.key);
      if (parsed == null) continue;
      final failurePath = p.join(
        handoffRoot.path,
        'live-recovery-${parsed.handoffId}.json.failed.txt',
      );
      final failed =
          await FileSystemEntity.type(failurePath, followLinks: false) ==
          FileSystemEntityType.file;
      final safetyRoot = await _readSafetyRootFromPlan(
        File(entry.value.path),
        scan,
      );
      if (safetyRoot == null) {
        untrustedPlanPaths.add(entry.value.path);
        if (_isPreparedPlanActive(File(entry.value.path))) {
          activePlanIds.add(parsed.handoffId);
          activePlanPaths.add(entry.value.path);
        }
        continue;
      }
      discoveredSafetyRoots.add(safetyRoot);
      // A live worker holds the recovery-artifact lock from consumption
      // through terminal cleanup. Once this preview owns that lock, a
      // persisted consuming file cannot still belong to an active worker.
      if (failed ||
          parsed.consuming ||
          !_isPreparedPlanActive(File(entry.value.path))) {
        failedPlanPaths.add(entry.value.path);
      } else {
        activePlanIds.add(parsed.handoffId);
        activePlanPaths.add(entry.value.path);
      }
    }

    for (final entry in byName.entries) {
      if (entry.value is! File ||
          (entry.key != 'live_recovery_complete.json' &&
              !_historicalCompletionPattern.hasMatch(entry.key))) {
        continue;
      }
      final safetyRoot = await _readSafetyRootFromCompletion(
        File(entry.value.path),
        scan,
      );
      if (safetyRoot != null) {
        trustedCompletionPaths.add(entry.value.path);
        discoveredSafetyRoots.add(safetyRoot);
      }
    }

    final hasActivePlan = activePlanPaths.isNotEmpty;
    for (final entity in topLevel) {
      final name = p.basename(entity.path);
      if (name == recoveryArtifactLockFile || name == 'staging') continue;
      final accepted = _acceptedPattern.firstMatch(name);
      if (accepted != null) {
        final disposition = activePlanIds.contains(accepted.group(1))
            ? RecoveryRetentionDisposition.retainedActivePlan
            : null;
        if (disposition != null) {
          await scan.retain(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.orphanedAcknowledgement,
            disposition,
            _lifecycle,
          );
        } else {
          await scan.eligible(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.orphanedAcknowledgement,
            _lifecycle,
          );
        }
        continue;
      }
      final plan = _parsePlanArtifactName(name);
      if (plan != null) {
        if (activePlanPaths.contains(entity.path)) {
          await scan.retain(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.failedPlan,
            RecoveryRetentionDisposition.retainedActivePlan,
            _lifecycle,
          );
        } else if (untrustedPlanPaths.contains(entity.path)) {
          await scan.retain(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.failedPlan,
            RecoveryRetentionDisposition.retainedPolicy,
            _lifecycle,
          );
        } else if (failedPlanPaths.contains(entity.path)) {
          await scan.eligible(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.failedPlan,
            _lifecycle,
          );
        }
        continue;
      }
      if (_failedDiagnosticPattern.hasMatch(name)) {
        await scan.eligible(
          entity,
          handoffRoot,
          RecoveryRetentionArtifactKind.failedRecoveryDiagnostic,
          _lifecycle,
        );
        continue;
      }
      if (_temporaryHandoffPattern.hasMatch(name)) {
        await scan.eligible(
          entity,
          handoffRoot,
          RecoveryRetentionArtifactKind.temporaryHandoff,
          _lifecycle,
        );
        continue;
      }
      if (name == 'live_recovery_complete.json' ||
          _historicalCompletionPattern.hasMatch(name)) {
        if (trustedCompletionPaths.contains(entity.path)) {
          await scan.eligible(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.completionMarker,
            _lifecycle,
          );
        } else {
          await scan.retain(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.completionMarker,
            RecoveryRetentionDisposition.retainedPolicy,
            _lifecycle,
          );
        }
        continue;
      }
      if (entity is Directory && _rollbackPattern.hasMatch(name)) {
        if (hasActivePlan) {
          await scan.retain(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.rollback,
            RecoveryRetentionDisposition.retainedActivePlan,
            _lifecycle,
          );
        } else {
          await scan.eligible(
            entity,
            handoffRoot,
            RecoveryRetentionArtifactKind.rollback,
            _lifecycle,
          );
        }
      }
    }

    final stagingRoot = Directory(p.join(handoffRoot.path, 'staging'));
    for (final entity in await _boundedChildren(stagingRoot, scan)) {
      if (hasActivePlan) {
        await scan.retain(
          entity,
          stagingRoot,
          RecoveryRetentionArtifactKind.stagingRestore,
          RecoveryRetentionDisposition.retainedActivePlan,
          _lifecycle,
        );
        continue;
      }
      if (entity is! Directory) {
        scan.issue(entity.path, 'Non-directory staging artifact was ignored.');
        continue;
      }
      final inspection = await _safeInspectBackup(entity, scan);
      if (inspection != null) {
        await scan.eligible(
          entity,
          stagingRoot,
          RecoveryRetentionArtifactKind.stagingRestore,
          _lifecycle,
          observedAt: inspection.createdAt,
        );
      } else if (_failedLifecyclePattern.hasMatch(p.basename(entity.path))) {
        await scan.eligible(
          entity,
          stagingRoot,
          RecoveryRetentionArtifactKind.failedStagingArtifact,
          _lifecycle,
        );
      } else if (_incompleteLifecyclePattern.hasMatch(
        p.basename(entity.path),
      )) {
        await scan.retain(
          entity,
          stagingRoot,
          RecoveryRetentionArtifactKind.failedStagingArtifact,
          RecoveryRetentionDisposition.retainedActivePlan,
          _lifecycle,
        );
      } else {
        scan.issue(entity.path, 'Unverified staging directory was retained.');
      }
    }

    final safetyRoots = _normalizeDistinctRoots(discoveredSafetyRoots);
    for (final root in safetyRoots) {
      if (_pathsOverlap(root.path, handoffRoot.path)) {
        scan.issue(
          root.path,
          'Safety-backup root overlaps the owned handoff root and was skipped.',
        );
        continue;
      }
      final valid = <(_RetentionEntity, RecoveryBackupInspection)>[];
      final failed = <_RetentionEntity>[];
      for (final entity in await _boundedChildren(root, scan)) {
        if (entity is! Directory) continue;
        final inspection = await _safeInspectBackup(entity, scan);
        if (inspection != null) {
          final retained = await scan.snapshot(
            entity,
            root,
            RecoveryRetentionArtifactKind.safetyBackup,
            _lifecycle,
            observedAt: inspection.createdAt,
          );
          if (retained != null) valid.add((retained, inspection));
        } else if (_failedLifecyclePattern.hasMatch(p.basename(entity.path))) {
          final item = await scan.snapshot(
            entity,
            root,
            RecoveryRetentionArtifactKind.failedSafetyBackup,
            _lifecycle,
          );
          if (item != null) failed.add(item);
        } else if (_incompleteLifecyclePattern.hasMatch(
          p.basename(entity.path),
        )) {
          await scan.retain(
            entity,
            root,
            RecoveryRetentionArtifactKind.failedSafetyBackup,
            RecoveryRetentionDisposition.retainedActivePlan,
            _lifecycle,
          );
        }
      }
      valid.sort((left, right) {
        final byDate = right.$2.createdAt.compareTo(left.$2.createdAt);
        return byDate != 0
            ? byDate
            : right.$1.preview.entity.path.compareTo(
                left.$1.preview.entity.path,
              );
      });
      if (valid.isNotEmpty) {
        scan.addRetainedEntity(
          valid.first.$1,
          RecoveryRetentionDisposition.retainedNewestSafetyBackup,
        );
        for (final older in valid.skip(1)) {
          scan.addEligibleEntity(older.$1);
        }
      }
      for (final item in failed) {
        scan.addEligibleEntity(item);
      }
    }

    scan.finalize(_clock().toUtc());
    return RecoveryArtifactRetentionPreview._(
      handoffRoot: handoffRoot,
      requestedSafetyBackupRoots: List.unmodifiable(requestedSafetyRoots),
      inspectedSafetyBackupRoots: List.unmodifiable(safetyRoots),
      policy: policy,
      createdAt: _clock().toUtc(),
      scannedEntities: scan.scannedEntities,
      scanLimitReached: scan.scanLimitReached,
      candidateLimitReached: scan.candidateLimitReached,
      candidates: List.unmodifiable(scan.candidates),
      retained: List.unmodifiable(scan.retained),
      issues: List.unmodifiable(scan.issues),
    );
  }

  Future<List<FileSystemEntity>> _boundedChildren(
    Directory directory,
    _RetentionScan scan,
  ) async {
    if (scan.scanLimitReached || !await directory.exists()) return const [];
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.directory) {
      scan.issue(directory.path, 'Retention root is not a real directory.');
      return const [];
    }
    final result = <FileSystemEntity>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (!scan.countScannedEntity()) break;
        result.add(entity);
      }
    } on Object catch (error) {
      scan.issue(directory.path, 'Retention scan failed: $error');
    }
    return result;
  }

  Future<RecoveryBackupInspection?> _safeInspectBackup(
    Directory bundle,
    _RetentionScan scan,
  ) async {
    try {
      return await _inspectBackup(bundle);
    } on Object catch (error) {
      scan.issue(bundle.path, 'Backup validation failed closed: $error');
      return null;
    }
  }

  Future<Directory?> _readSafetyRootFromPlan(
    File file,
    _RetentionScan scan,
  ) async {
    try {
      if (await file.length() > recoveryArtifactRetentionMaxMetadataBytes) {
        throw const FormatException('Plan exceeds its retention byte limit.');
      }
      final plan = await AtlasLiveRecoveryPlan.read(file);
      return _validatedExternalRoot(plan.safetyBackupRoot.path);
    } on Object catch (error) {
      scan.issue(
        file.path,
        'Plan metadata was retained but not trusted: $error',
      );
      return null;
    }
  }

  Future<Directory?> _readSafetyRootFromCompletion(
    File file,
    _RetentionScan scan,
  ) async {
    try {
      final decoded = await _readBoundedJson(file);
      const expectedKeys = {
        'schema',
        'sourceBundle',
        'safetyBackup',
        'stagedBundle',
        'completedAt',
      };
      if (decoded is! Map ||
          decoded.keys
              .map((key) => '$key')
              .toSet()
              .difference(expectedKeys)
              .isNotEmpty ||
          expectedKeys
              .difference(decoded.keys.map((key) => '$key').toSet())
              .isNotEmpty ||
          decoded['schema'] != 'project_atlas_live_recovery_complete_v1') {
        throw const FormatException('Unsupported completion marker.');
      }
      final safetyBackup = decoded['safetyBackup'];
      final sourceBundle = decoded['sourceBundle'];
      final stagedBundle = decoded['stagedBundle'];
      if (safetyBackup is! String ||
          sourceBundle is! String ||
          stagedBundle is! String ||
          _parseUtcTimestamp(decoded['completedAt']) == null) {
        throw const FormatException('Completion marker values are invalid.');
      }
      _validatedExternalRoot(sourceBundle);
      _validatedExternalRoot(stagedBundle);
      return _validatedExternalRoot(p.dirname(safetyBackup));
    } on Object catch (error) {
      scan.issue(
        file.path,
        'Completion metadata was retained but not trusted: $error',
      );
      return null;
    }
  }

  Directory _validatedExternalRoot(String value) {
    if (!p.isAbsolute(value) || p.normalize(value) != value) {
      throw const FormatException(
        'Safety-backup root must be absolute and normalized.',
      );
    }
    return Directory(value);
  }
}

class _RetentionScan {
  final RecoveryArtifactRetentionPolicy policy;
  final List<_RetentionEntity> _eligible = [];
  final List<RecoveryArtifactRetentionItem> retained = [];
  final List<RecoveryArtifactRetentionItem> candidates = [];
  final List<RecoveryArtifactRetentionIssue> issues = [];
  int scannedEntities = 0;
  bool scanLimitReached = false;
  bool candidateLimitReached = false;

  _RetentionScan(this.policy);

  bool countScannedEntity() {
    if (scannedEntities >= policy.maxScannedEntities) {
      scanLimitReached = true;
      return false;
    }
    scannedEntities++;
    return true;
  }

  void issue(String path, String message) {
    issues.add(RecoveryArtifactRetentionIssue(path: path, message: message));
  }

  Future<_RetentionEntity?> snapshot(
    FileSystemEntity entity,
    Directory trustedParent,
    RecoveryRetentionArtifactKind kind,
    RecoveryArtifactLifecycle lifecycle, {
    DateTime? observedAt,
  }) async {
    try {
      final preview = await lifecycle.previewArtifactForDeletion(
        entity,
        trustedParent: trustedParent,
        limits: policy.perArtifactDeletionLimits,
      );
      return _RetentionEntity(
        kind: kind,
        preview: preview,
        observedAt: observedAt ?? preview.observedAt,
      );
    } on Object catch (error) {
      issue(
        entity.path,
        'Artifact was retained because preview failed: $error',
      );
      return null;
    }
  }

  Future<void> eligible(
    FileSystemEntity entity,
    Directory trustedParent,
    RecoveryRetentionArtifactKind kind,
    RecoveryArtifactLifecycle lifecycle, {
    DateTime? observedAt,
  }) async {
    final item = await snapshot(
      entity,
      trustedParent,
      kind,
      lifecycle,
      observedAt: observedAt,
    );
    if (item != null) addEligibleEntity(item);
  }

  Future<void> retain(
    FileSystemEntity entity,
    Directory trustedParent,
    RecoveryRetentionArtifactKind kind,
    RecoveryRetentionDisposition disposition,
    RecoveryArtifactLifecycle lifecycle,
  ) async {
    final item = await snapshot(entity, trustedParent, kind, lifecycle);
    if (item != null) addRetainedEntity(item, disposition);
  }

  void addEligibleEntity(_RetentionEntity item) {
    _eligible.add(item);
  }

  void addRetainedEntity(
    _RetentionEntity item,
    RecoveryRetentionDisposition disposition,
  ) {
    retained.add(item.toItem(disposition: disposition));
  }

  void finalize(DateTime now) {
    if (scanLimitReached) {
      for (final item in _eligible) {
        retained.add(
          item.toItem(disposition: RecoveryRetentionDisposition.retainedPolicy),
        );
      }
      issue('', 'The scan limit was reached; the deletion set was suppressed.');
      return;
    }
    final selected = <_RetentionEntity, Set<RecoveryRetentionTrigger>>{};
    for (final item in _eligible) {
      if (now.difference(item.observedAt) >= policy.maximumAge) {
        selected[item] = {RecoveryRetentionTrigger.age};
      }
    }
    var retainedBytes = retained.fold<int>(
      0,
      (total, item) => total + item.bytes,
    );
    for (final item in _eligible) {
      if (!selected.containsKey(item)) retainedBytes += item.preview.bytes;
    }
    if (retainedBytes > policy.maximumRetainedBytes) {
      final oldest =
          _eligible.where((item) => !selected.containsKey(item)).toList()
            ..sort((left, right) {
              final byDate = left.observedAt.compareTo(right.observedAt);
              return byDate != 0
                  ? byDate
                  : left.preview.entity.path.compareTo(
                      right.preview.entity.path,
                    );
            });
      for (final item in oldest) {
        if (retainedBytes <= policy.maximumRetainedBytes) break;
        selected[item] = {RecoveryRetentionTrigger.size};
        retainedBytes = max(0, retainedBytes - item.preview.bytes);
      }
    }
    final selectedEntries = selected.entries.toList()
      ..sort((left, right) {
        final byDate = left.key.observedAt.compareTo(right.key.observedAt);
        return byDate != 0
            ? byDate
            : left.key.preview.entity.path.compareTo(
                right.key.preview.entity.path,
              );
      });
    for (final entry in selectedEntries) {
      if (candidates.length == policy.maxCandidates) {
        candidateLimitReached = true;
        retained.add(
          entry.key.toItem(
            disposition: RecoveryRetentionDisposition.retainedPolicy,
          ),
        );
        continue;
      }
      candidates.add(
        entry.key.toItem(
          disposition: RecoveryRetentionDisposition.candidate,
          triggers: entry.value,
        ),
      );
    }
    for (final item in _eligible.where((item) => !selected.containsKey(item))) {
      retained.add(
        item.toItem(disposition: RecoveryRetentionDisposition.retainedPolicy),
      );
    }
    if (retainedBytes > policy.maximumRetainedBytes) {
      issue(
        '',
        'Protected recovery artifacts alone exceed the configured size limit.',
      );
    }
  }
}

class _RetentionEntity {
  final RecoveryRetentionArtifactKind kind;
  final RecoveryArtifactDeletionPreview preview;
  final DateTime observedAt;

  const _RetentionEntity({
    required this.kind,
    required this.preview,
    required this.observedAt,
  });

  RecoveryArtifactRetentionItem toItem({
    required RecoveryRetentionDisposition disposition,
    Set<RecoveryRetentionTrigger> triggers = const {},
  }) {
    final path = p.normalize(p.absolute(preview.entity.path));
    final id = sha256
        .convert(
          utf8.encode('${kind.name}\u0000$path\u0000${preview.snapshotId}'),
        )
        .toString();
    return RecoveryArtifactRetentionItem._(
      id: id,
      kind: kind,
      disposition: disposition,
      path: path,
      entries: preview.entries,
      bytes: preview.bytes,
      observedAt: observedAt,
      triggers: Set.unmodifiable(triggers),
      deletionPreview: preview,
    );
  }
}

class _ParsedPlanArtifact {
  final String handoffId;
  final bool consuming;

  const _ParsedPlanArtifact(this.handoffId, {required this.consuming});
}

_ParsedPlanArtifact? _parsePlanArtifactName(String name) {
  final pending = _pendingPlanPattern.firstMatch(name);
  if (pending != null) {
    return _ParsedPlanArtifact(pending.group(1)!, consuming: false);
  }
  final consuming = _consumingPlanPattern.firstMatch(name);
  if (consuming != null) {
    return _ParsedPlanArtifact(consuming.group(1)!, consuming: true);
  }
  return null;
}

Future<Object?> _readBoundedJson(File file) async {
  final bytes = <int>[];
  await for (final chunk in file.openRead(
    0,
    recoveryArtifactRetentionMaxMetadataBytes + 1,
  )) {
    bytes.addAll(chunk);
    if (bytes.length > recoveryArtifactRetentionMaxMetadataBytes) {
      throw const FormatException('Metadata exceeds its byte limit.');
    }
  }
  return jsonDecode(utf8.decode(bytes));
}

DateTime? _parseUtcTimestamp(Object? value) {
  if (value is! String || !value.endsWith('Z')) return null;
  final parsed = DateTime.tryParse(value);
  return parsed?.isUtc == true ? parsed!.toUtc() : null;
}

List<Directory> _normalizeDistinctRoots(Iterable<Directory> roots) {
  final result = <String, Directory>{};
  for (final root in roots) {
    final normalized = p.normalize(p.absolute(root.path));
    result[Platform.isWindows ? normalized.toLowerCase() : normalized] =
        Directory(normalized);
  }
  return List.unmodifiable(result.values);
}

bool _pathsOverlap(String left, String right) {
  final normalizedLeft = p.normalize(p.absolute(left));
  final normalizedRight = p.normalize(p.absolute(right));
  return p.equals(normalizedLeft, normalizedRight) ||
      p.isWithin(normalizedLeft, normalizedRight) ||
      p.isWithin(normalizedRight, normalizedLeft);
}

final _pendingPlanPattern = RegExp(r'^live-recovery-(.+)\.json$');
final _consumingPlanPattern = RegExp(
  r'^live-recovery-(.+)\.json\.consuming-\d+$',
);
final _acceptedPattern = RegExp(r'^live-recovery-(.+)\.accepted\.json$');
final _failedDiagnosticPattern = RegExp(
  r'^live-recovery-.+\.json\.failed\.txt$',
);
final _temporaryHandoffPattern = RegExp(
  r'^live-recovery-.+\.(?:json|accepted\.json)\.tmp-\d+$',
);
final _historicalCompletionPattern = RegExp(
  r'^live-recovery-.+\.completed\.json$',
);
final _rollbackPattern = RegExp(
  r'^rollback-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z?$',
);
final _failedLifecyclePattern = RegExp(r'^.+\.atlas-failed-[0-9a-f]{32}$');
final _incompleteLifecyclePattern = RegExp(
  r'^.+\.atlas-incomplete-[0-9a-f]{32}$',
);
