import 'dart:convert';
import 'dart:io';

import '../db/app_db.dart';
import 'github_remote_metadata_service.dart';
import 'project_enrichment_service.dart';

/// Builds the DB-backed, read-only project completeness audit.
///
/// This deliberately owns audit rules and queries only; run state, finding
/// persistence, and UI notifications remain the responsibility of AppState.
class ProjectEnrichmentAuditService {
  final AppDb db;

  const ProjectEnrichmentAuditService(this.db);

  Future<ProjectEnrichmentAudit> build({
    required List<ProjectRegistryEntry> registry,
    required List<Project> projects,
  }) async {
    final findings = <ProjectEnrichmentFindingDraft>[];
    final byProject = <String, List<ProjectRegistryEntry>>{};
    final firstByProject = <String, ProjectRegistryEntry>{};
    for (final entry in registry) {
      final id = entry.atlasProjectId?.trim();
      if (id == null || id.isEmpty) continue;
      byProject.putIfAbsent(id, () => []).add(entry);
      firstByProject.putIfAbsent(id, () => entry);
    }
    final projectsById = {for (final project in projects) project.id: project};
    final projectIds = projectsById.keys.toSet();
    var documents = 0, media = 0, sourceFiles = 0, cards = 0;
    var projectsWithDocs = 0, projectsWithMedia = 0;
    var projectsWithSourceFiles = 0, projectsWithCards = 0;
    var projectsWithPeople = 0, projectsWithTags = 0, projectsWithTasks = 0;
    var projectsWithRisks = 0, projectsWithDecisions = 0;
    var projectsWithGithubCache = 0, activePrimarySources = 0;
    var unresolvedSources = 0, legacyRemoteSources = 0;
    var duplicateSourceIdentities = 0;

    void add({
      Project? project,
      ProjectRegistryEntry? entry,
      required String severity,
      required String category,
      required String title,
      String? detail,
      Map<String, Object?> evidence = const {},
    }) => findings.add(
      ProjectEnrichmentFindingDraft(
        projectId: project?.id,
        registryId: entry?.id,
        severity: severity,
        category: category,
        title: title,
        detail: detail,
        evidence: {
          if (project != null) 'projectTitle': project.title,
          if (entry != null) ...{
            'registryDisplayName': entry.displayName,
            'localPath': entry.localPath,
            'reviewState': entry.reviewState,
          },
          ...evidence,
        },
      ),
    );

    for (final entry in registry) {
      final linkedId = entry.atlasProjectId?.trim();
      if (entry.reviewState == 'ignored') continue;
      final localPath = entry.localPath.trim();
      final remote = _looksLikeRemotePath(localPath);
      final exists = !remote && _directoryExistsSafely(localPath);
      final pathProblem = remote || !exists;
      if (remote) {
        add(
          entry: entry,
          severity: 'info',
          category: 'registry',
          title: 'Registered local path is a remote URL, not a local folder.',
          detail: entry.localPath,
          evidence: {'pathKind': 'remote_url'},
        );
      } else if (!exists) {
        add(
          entry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registered local path does not exist.',
          detail: entry.localPath,
        );
      }
      if (linkedId == null || linkedId.isEmpty) {
        if (!pathProblem && entry.reviewState == 'needs_review') {
          add(
            entry: entry,
            severity: 'warning',
            category: 'registry',
            title: 'Registered local project still needs review.',
            detail:
                'Review it, link it to an existing project, import it as a new project, or mark it ignored.',
          );
        } else if (!pathProblem) {
          add(
            entry: entry,
            severity: 'warning',
            category: 'registry',
            title:
                'Registered local project is not linked to an Atlas project.',
            detail:
                'Link it to an existing project, import it as a new project, or mark it ignored.',
          );
        }
      } else if (!projectIds.contains(linkedId)) {
        add(
          entry: entry,
          severity: 'error',
          category: 'registry',
          title: 'Registry row points to a missing Atlas project.',
          detail: linkedId,
        );
      } else if (!pathProblem && entry.reviewState == 'needs_review') {
        add(
          entry: entry,
          severity: 'warning',
          category: 'registry',
          title: 'Registered local project still needs review.',
          detail:
              'Review this linked registry row or mark it accepted/ignored.',
        );
      }
    }
    for (final group in byProject.entries.where(
      (item) => item.value.length > 1,
    )) {
      final entries = group.value;
      add(
        project: projectsById[group.key],
        entry: entries.first,
        severity: 'warning',
        category: 'registry',
        title:
            'Multiple local registry entries are linked to the same Atlas project.',
        detail:
            'Review these registry rows and merge, unlink, or mark duplicates ignored.',
        evidence: {
          'atlasProjectId': group.key,
          'linkedRegistryIds': entries.map((item) => item.id).toList(),
          'linkedDisplayNames': entries
              .map((item) => item.displayName)
              .toList(),
          'linkedLocalPaths': entries.map((item) => item.localPath).toList(),
        },
      );
    }
    final identities = <String, List<ProjectRegistryEntry>>{};
    for (final entry in registry) {
      if (entry.reviewState == 'ignored') continue;
      final identity = _sourceIdentity(entry);
      if (identity != null)
        identities.putIfAbsent(identity, () => []).add(entry);
    }
    for (final group in identities.entries.where(
      (item) => item.value.length > 1,
    )) {
      duplicateSourceIdentities++;
      final entries = group.value;
      add(
        project: entries.first.atlasProjectId == null
            ? null
            : projectsById[entries.first.atlasProjectId],
        entry: entries.first,
        severity: 'warning',
        category: 'source_topology',
        title: 'Multiple source rows share the same normalized identity.',
        detail:
            'Review these source rows before applying identity reconciliation.',
        evidence: {
          'normalizedIdentity': group.key,
          'registryIds': entries.map((item) => item.id).toList(),
          'atlasProjectIds': entries
              .map((item) => item.atlasProjectId)
              .whereType<String>()
              .toSet()
              .toList(),
          'localPaths': entries.map((item) => item.localPath).toList(),
        },
      );
    }

    for (final project in projects) {
      final entries = byProject[project.id] ?? const <ProjectRegistryEntry>[];
      final entry = entries.firstOrNull;
      final primary = entries
          .where(isActivePrimarySource)
          .toList(growable: false);
      final unresolved = entries
          .where(isUnresolvedSource)
          .toList(growable: false);
      activePrimarySources += primary.length;
      unresolvedSources += unresolved.length;
      legacyRemoteSources += entries
          .where((item) => item.sourceType == 'remote_url_legacy')
          .length;
      final docs = await db.getDocumentsForProject(project.id);
      final mediaItems = await db.getProjectMedia(project.id);
      final tags = await db.getTagsForProject(project.id);
      final people = await db.getProjectPeople(project.id);
      final items = await db.getWorkItemsForProject(project.id);
      final risks = await db.getProjectRisks(project.id);
      final decisions = await db.getProjectDecisions(project.id);
      final observation = entry == null
          ? null
          : await db.getLatestProjectObservationForPath(entry.localPath);
      final github = await db.getLatestProjectGitRemoteStatus(project.id);
      final refreshItems = entry == null
          ? const <LocalProjectRefreshItem>[]
          : await db.getLocalProjectRefreshItemsForRegistry(entry.id);
      final sourceFileCount = refreshItems
          .where((item) => item.sourceKind == 'source_file')
          .length;
      final cardCount = refreshItems
          .where((item) => item.sourceKind == 'atlas_card')
          .length;
      documents += docs.length;
      media += mediaItems.length;
      sourceFiles += sourceFileCount;
      cards += cardCount;
      if (docs.isNotEmpty) projectsWithDocs++;
      if (mediaItems.isNotEmpty) projectsWithMedia++;
      if (sourceFileCount > 0) projectsWithSourceFiles++;
      if (cardCount > 0) projectsWithCards++;
      if (people.isNotEmpty) projectsWithPeople++;
      if (tags.isNotEmpty) projectsWithTags++;
      if (items.isNotEmpty) projectsWithTasks++;
      if (risks.isNotEmpty) projectsWithRisks++;
      if (decisions.isNotEmpty) projectsWithDecisions++;
      if (github != null) projectsWithGithubCache++;
      if (entry == null) {
        add(
          project: project,
          severity: 'warning',
          category: 'registry',
          title: 'Atlas project is not linked to a local registry entry.',
          detail:
              'Run an Operations scan and link or upload the matching local project.',
        );
      } else if (primary.isEmpty) {
        add(
          project: project,
          entry: entry,
          severity: 'error',
          category: 'source_topology',
          title: 'Project has no active primary working source.',
          detail:
              'Mark one valid local source as primary_working before identity reconciliation.',
          evidence: {
            'linkedRegistryIds': entries.map((item) => item.id).toList(),
            'sourceRoles': entries
                .map((item) => item.sourceRole)
                .toSet()
                .toList(),
            'lifecycleStates': entries
                .map((item) => item.lifecycleState)
                .toSet()
                .toList(),
          },
        );
      } else if (primary.length > 1) {
        add(
          project: project,
          entry: primary.first,
          severity: 'error',
          category: 'source_topology',
          title: 'Project has multiple active primary working sources.',
          detail:
              'Resolve source authority before applying identity reconciliation.',
          evidence: {
            'primaryRegistryIds': primary.map((item) => item.id).toList(),
            'primaryLocalPaths': primary.map((item) => item.localPath).toList(),
          },
        );
      }
      for (final source in unresolved) {
        add(
          project: project,
          entry: source,
          severity: source.authorityLevel == 'blocked_unresolved'
              ? 'error'
              : 'warning',
          category: 'source_topology',
          title: 'Source topology is unresolved for this project.',
          detail:
              'Review the source role, lifecycle state, and authority before reconciliation.',
          evidence: {
            'sourceRole': source.sourceRole,
            'sourceType': source.sourceType,
            'lifecycleState': source.lifecycleState,
            'authorityLevel': source.authorityLevel,
            'normalizedIdentity': source.normalizedIdentity,
          },
        );
      }
      if (_blank(project.description))
        add(
          project: project,
          entry: entry,
          severity: 'info',
          category: 'identity',
          title: 'Project description is blank.',
        );
      if (_blank(project.owner))
        add(
          project: project,
          entry: entry,
          severity: 'info',
          category: 'people',
          title: 'Project owner is blank.',
        );
      if (tags.isEmpty)
        add(
          project: project,
          entry: entry,
          severity: 'info',
          category: 'identity',
          title: 'Project has no tags.',
        );
      if (docs.isEmpty)
        add(
          project: project,
          entry: entry,
          severity: 'warning',
          category: 'library',
          title: 'Project has no imported documents.',
        );
      if (_looksLikeSoftwareProject(observation, entry) && sourceFileCount == 0)
        add(
          project: project,
          entry: entry,
          severity: 'warning',
          category: 'library',
          title: 'Software project has no individual source files imported.',
          detail:
              'Run linked project refresh with source documents enabled, or review source import caps/exclusions.',
        );
      if (_looksLikeCardProject(project, entry) && cardCount == 0)
        add(
          project: project,
          entry: entry,
          severity: 'warning',
          category: 'library',
          title: 'Card-style project has no individual cards imported.',
          detail:
              'Run linked project refresh and review card source parser coverage.',
        );
      final remote = observation?.remoteUrl;
      if (GithubRemoteMetadataService.parseGithubRemoteUrl(remote) != null &&
          github == null) {
        add(
          project: project,
          entry: entry,
          severity: 'warning',
          category: 'repository',
          title: 'GitHub remote is detected but metadata is not cached.',
          detail:
              'Use Refresh GitHub so Atlas can show public/private/default-branch state.',
          evidence: {'remoteUrl': remote},
        );
      } else if (github?.hasError == true) {
        add(
          project: project,
          entry: entry,
          severity: 'warning',
          category: 'repository',
          title: 'Latest GitHub metadata refresh has a warning.',
          detail: github?.error,
          evidence: {'remoteUrl': github?.remoteUrl},
        );
      }
      if ((observation?.dirtyCount ?? 0) > 0)
        add(
          project: project,
          entry: entry,
          severity: 'info',
          category: 'repository',
          title: 'Latest local git observation has uncommitted changes.',
          evidence: {'dirtyCount': observation!.dirtyCount},
        );
    }
    return ProjectEnrichmentAudit(
      findings: findings,
      coverage: {
        'projects': projects.length,
        'registryEntries': registry.length,
        'linkedSources': byProject.values.fold<int>(
          0,
          (total, entries) => total + entries.length,
        ),
        'linkedProjects': firstByProject.length,
        'distinctLinkedProjects': firstByProject.length,
        'unlinkedRegistryEntries': registry
            .where(
              (entry) =>
                  entry.reviewState != 'ignored' &&
                  (entry.atlasProjectId ?? '').isEmpty,
            )
            .length,
        'atlasProjectsWithoutRegistry': projects
            .where((project) => !firstByProject.containsKey(project.id))
            .length,
        'documents': documents,
        'media': media,
        'sourceFiles': sourceFiles,
        'cards': cards,
        'projectsWithDocs': projectsWithDocs,
        'projectsWithMedia': projectsWithMedia,
        'projectsWithSourceFiles': projectsWithSourceFiles,
        'projectsWithCards': projectsWithCards,
        'projectsWithPeople': projectsWithPeople,
        'projectsWithTags': projectsWithTags,
        'projectsWithTasks': projectsWithTasks,
        'projectsWithRisks': projectsWithRisks,
        'projectsWithDecisions': projectsWithDecisions,
        'projectsWithGithubCache': projectsWithGithubCache,
        'sourceTopology': {
          'activePrimarySources': activePrimarySources,
          'unresolvedSources': unresolvedSources,
          'legacyRemoteSources': legacyRemoteSources,
          'duplicateNormalizedIdentities': duplicateSourceIdentities,
        },
      },
    );
  }

  static bool isActivePrimarySource(ProjectRegistryEntry entry) =>
      entry.reviewState != 'ignored' &&
      entry.sourceRole == 'primary_working' &&
      entry.lifecycleState == 'active';
  static bool isUnresolvedSource(ProjectRegistryEntry entry) =>
      entry.reviewState != 'ignored' &&
      (entry.sourceRole == 'unresolved_candidate' ||
          entry.lifecycleState == 'legacy_remote' ||
          entry.authorityLevel == 'blocked_unresolved');
  String? _sourceIdentity(ProjectRegistryEntry entry) {
    final normalized = entry.normalizedIdentity?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
    final gitRoot = entry.gitRoot?.trim();
    if (gitRoot != null && gitRoot.isNotEmpty) return _pathKey(gitRoot);
    final local = entry.localPath.trim();
    return local.isEmpty ? null : _pathKey(local);
  }

  bool _looksLikeSoftwareProject(
    ProjectObservation? observation,
    ProjectRegistryEntry? registry,
  ) {
    final markers = observation == null
        ? const <String>[]
        : _decodeStringList(observation.markerFilesJson);
    const softwareMarkers = {
      'package.json',
      'pubspec.yaml',
      'pyproject.toml',
      'Cargo.toml',
      'go.mod',
      'pom.xml',
      'build.gradle',
    };
    if (markers.any(softwareMarkers.contains)) return true;
    final path = [
      registry?.localPath,
      observation?.observedPath,
    ].whereType<String>().join(' ').toLowerCase();
    return path.contains(r'\src') ||
        path.contains(r'\lib') ||
        path.contains(r'\app') ||
        path.contains('flutter') ||
        path.contains('python') ||
        path.contains('node');
  }

  bool _looksLikeCardProject(Project project, ProjectRegistryEntry? registry) {
    final haystack = [
      project.title,
      project.description,
      registry?.displayName,
      registry?.localPath,
    ].whereType<String>().join(' ').toLowerCase();
    return haystack.contains('goalcard') || haystack.contains('card library');
  }

  bool _blank(String? value) => value == null || value.trim().isEmpty;
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

  List<String> _decodeStringList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((item) => '$item').toList();
    } catch (_) {}
    return const [];
  }

  String _pathKey(String value) => value
      .trim()
      .replaceAll('/', r'\')
      .replaceAll(RegExp(r'\\+$'), '')
      .toLowerCase();
}
