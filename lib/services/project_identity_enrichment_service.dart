import 'dart:io';

import '../db/app_db.dart';
import 'local_project_refresh_service.dart';
import 'project_capsule_truth_service.dart';
import 'project_enrichment_service.dart';
import 'project_non_truth_metadata_service.dart';

/// Applies deterministic, local project identity updates produced by a refresh
/// plan. UI-facing run state intentionally stays with `AppState`.
class ProjectIdentityEnrichmentService {
  final AppDb db;

  const ProjectIdentityEnrichmentService(this.db);

  Future<ProjectIdentityEnrichmentResult> refreshRecords(
    List<ProjectRegistryEntry> registry, {
    LocalProjectRefreshService service = const LocalProjectRefreshService(),
    ProjectEnrichmentStatusCallback? onStatus,
  }) async {
    final linked = registry
        .where(
          (entry) =>
              entry.reviewState != 'ignored' &&
              (entry.atlasProjectId ?? '').trim().isNotEmpty,
        )
        .toList(growable: false);
    var considered = 0;
    var updated = 0;
    var unchanged = 0;
    var skipped = 0;
    final warnings = <String>[];

    for (final entry in linked) {
      considered++;
      final projectId = entry.atlasProjectId!.trim();
      onStatus?.call(
        'Updating identity for ${entry.displayName} ($considered/${linked.length}).',
        current: considered,
        total: linked.length,
      );
      final localPath = entry.localPath.trim();
      if (_looksLikeRemotePath(localPath)) {
        skipped++;
        warnings.add(
          '${entry.displayName}: identity update skipped because the registered local path is a remote URL.',
        );
        continue;
      }
      if (!_directoryExistsSafely(localPath)) {
        skipped++;
        warnings.add(
          '${entry.displayName}: identity update skipped because the registered local path does not exist: ${entry.localPath}',
        );
        continue;
      }
      final project = await db.getProjectFull(projectId);
      if (project == null) {
        skipped++;
        warnings.add('${entry.displayName}: linked Atlas project is missing.');
        continue;
      }
      try {
        final plan = await service.buildPlan(entry.localPath);
        warnings.addAll(
          plan.warnings.map((warning) => '${entry.displayName}: $warning'),
        );
        final projectActions = plan.actions
            .where((action) => action.targetType == 'project')
            .toList(growable: false);
        var changed = false;
        if (projectActions.isEmpty) {
          changed = await _applyProjectIdentityTags(
            projectId: projectId,
            entry: entry,
            planProfile: plan.profile,
          );
        } else {
          for (final action in projectActions) {
            changed =
                await applyAction(
                  projectId: projectId,
                  entry: entry,
                  action: action,
                  planProfile: plan.profile,
                ) ||
                changed;
          }
        }
        if (changed) {
          updated++;
        } else {
          unchanged++;
        }
      } catch (error) {
        skipped++;
        warnings.add('${entry.displayName}: identity update failed: $error');
      }
    }

    return ProjectIdentityEnrichmentResult(
      considered: considered,
      updated: updated,
      unchanged: unchanged,
      skipped: skipped,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<bool> applyAction({
    required String projectId,
    required ProjectRegistryEntry entry,
    required LocalProjectRefreshAction action,
    required String planProfile,
  }) async {
    final project = await db.getProjectFull(projectId);
    if (project == null) return false;
    final fields = <String, Object?>{};

    void maybeSet(String key, String? current) {
      final value = _payloadCleanString(action.payload, key);
      if (value == null || value == current?.trim()) return;
      fields[key] = value;
    }

    maybeSet('title', project.title);
    maybeSet('description', project.description);
    maybeSet('desiredOutcome', project.desiredOutcome);
    maybeSet('successCriteria', project.successCriteria);
    maybeSet('phase', project.phase);
    maybeSet('priority', project.priority);
    maybeSet('scopeIncluded', project.scopeIncluded);
    maybeSet('scopeExcluded', project.scopeExcluded);
    maybeSet('outcomeSummary', project.outcomeSummary);
    maybeSet('lessonsLearned', project.lessonsLearned);

    return db.transaction(() async {
      var changed = false;
      final truthFields = Map<String, Object?>.from(fields)
        ..remove('lessonsLearned');
      if (truthFields.isNotEmpty) {
        final result = await ProjectCapsuleTruthService(db).acceptPatch(
          projectId: projectId,
          fields: truthFields,
          actorLabel: 'Atlas',
          sourceKind: 'local_project_identity_refresh',
          sourceId: entry.id,
        );
        changed = result.changed || changed;
      }
      if (fields.containsKey('lessonsLearned')) {
        changed =
            await ProjectNonTruthMetadataService(db).updatePatch(
              projectId: projectId,
              fields: {'lessonsLearned': fields['lessonsLearned']},
              actorLabel: 'Atlas',
            ) ||
            changed;
      }
      final tagsChanged = await _applyProjectIdentityTags(
        projectId: projectId,
        entry: entry,
        planProfile: planProfile,
        payload: action.payload,
      );
      return changed || tagsChanged;
    });
  }

  Future<bool> _applyProjectIdentityTags({
    required String projectId,
    required ProjectRegistryEntry entry,
    required String planProfile,
    Map<String, Object?> payload = const {},
  }) async {
    final manifestType = _payloadCleanString(payload, 'manifestType');
    final manifestGroup = _payloadCleanString(payload, 'manifestGroup');
    final tags = <String>[
      ..._payloadStringList(payload, 'manifestTags'),
      ?manifestType,
      ?manifestGroup,
      entry.classification,
      if (planProfile.trim().isNotEmpty && planProfile != 'unknown')
        planProfile,
    ];
    final observation = await db.getLatestProjectObservationForPath(
      entry.localPath,
    );
    final remoteUrl = observation?.remoteUrl?.trim();
    if (remoteUrl != null && remoteUrl.isNotEmpty) {
      tags.add(
        remoteUrl.toLowerCase().contains('github.com') ? 'github' : 'git',
      );
    } else {
      tags.add('local-only');
    }
    if ((observation?.dirtyCount ?? 0) > 0) {
      tags.add('needs-update');
    }
    return _assignProjectTagsByName(projectId, tags);
  }

  Future<bool> _assignProjectTagsByName(
    String projectId,
    Iterable<String> names,
  ) async {
    final existing = await db.getTagsForProject(projectId);
    final assignedNames = existing
        .map((tag) => tag.name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    var changed = false;
    final uniqueNames = <String, String>{};
    for (final rawName in names) {
      final name = _normalizeIdentityTagName(rawName);
      if (name == null) continue;
      uniqueNames.putIfAbsent(name.toLowerCase(), () => name);
    }
    for (final entry in uniqueNames.entries) {
      if (assignedNames.contains(entry.key)) continue;
      final tag = await db.findTagByName(entry.value);
      final tagId = tag?.id ?? await db.saveTag(name: entry.value);
      await db.assignTagToProject(projectId, tagId);
      assignedNames.add(entry.key);
      changed = true;
    }
    return changed;
  }

  String? _normalizeIdentityTagName(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  String? _payloadCleanString(Map<String, Object?> payload, String key) =>
      _normalizeIdentityTagName(payload[key]);

  List<String> _payloadStringList(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is Iterable) {
      return value
          .map(_normalizeIdentityTagName)
          .whereType<String>()
          .toList(growable: false);
    }
    final single = _normalizeIdentityTagName(value);
    return single == null ? const [] : [single];
  }

  bool _looksLikeRemotePath(String value) {
    final lower = value.trim().toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('ssh://') ||
        lower.startsWith('git@');
  }

  bool _directoryExistsSafely(String path) {
    if (path.trim().isEmpty) return false;
    try {
      return Directory(path).existsSync();
    } on FileSystemException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}
