import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/github_remote_metadata_service.dart';
import 'package:project_atlas/services/local_operations_scanner.dart';
import 'package:project_atlas/services/local_project_refresh_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String base;
  _FakePathProvider(this.base);

  @override
  Future<String?> getApplicationDocumentsPath() async => base;

  @override
  Future<String?> getApplicationSupportPath() async => base;
}

void main() {
  late Directory tempDir;
  late AppDb db;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('atlas_ops_db_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    db = AppDb.withExecutor(NativeDatabase.memory());
    state = AppState(db, enableBackgroundSummaryRefresh: false);
  });

  tearDown(() async {
    state.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'schema v19 creates local operations, runtime, git remote, enrichment, and queue tables',
    () async {
      expect(db.schemaVersion, 19);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .get();
      final tableNames = tables.map((row) => row.data['name']).toSet();

      expect(tableNames, contains('project_registry'));
      expect(tableNames, contains('project_observations'));
      expect(tableNames, contains('project_scan_runs'));
      expect(tableNames, contains('local_project_refresh_items'));
      expect(tableNames, contains('project_git_remotes'));
      expect(tableNames, contains('project_enrichment_runs'));
      expect(tableNames, contains('project_enrichment_findings'));
      expect(tableNames, contains('project_enrichment_steps'));
      expect(tableNames, contains('project_enrichment_proposals'));
      expect(tableNames, contains('llm_task_queue'));
      expect(tableNames, contains('media_links'));
      expect(tableNames, contains('work_item_tags'));
      expect(tableNames, contains('project_runtime_profiles'));
      expect(tableNames, contains('project_runtime_runs'));
    },
  );

  test(
    'schema v10 migration creates local operations tables and supports writes',
    () async {
      final dbPath = p.join(tempDir.path, 'schema10.sqlite');
      final legacy = sqlite3.sqlite3.open(dbPath);
      try {
        legacy.execute('PRAGMA user_version = 10');
      } finally {
        legacy.dispose();
      }

      final migrated = AppDb.withExecutor(NativeDatabase(File(dbPath)));
      try {
        final tables = await migrated
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get();
        final tableNames = tables.map((row) => row.data['name']).toSet();

        expect(tableNames, contains('project_registry'));
        expect(tableNames, contains('project_observations'));
        expect(tableNames, contains('project_scan_runs'));
        expect(tableNames, contains('local_project_refresh_items'));
        expect(tableNames, contains('work_item_tags'));
        expect(tableNames, contains('project_git_remotes'));
        expect(tableNames, contains('project_enrichment_runs'));
        expect(tableNames, contains('llm_task_queue'));
        expect(tableNames, contains('media_links'));

        final runId = await migrated.startProjectScanRun(
          rootsJson: jsonEncode([tempDir.path]),
          startedAt: DateTime(2026),
        );
        await migrated.addProjectObservation(
          id: 'obs-migrated',
          scanRunId: runId,
          observedPath: p.join(tempDir.path, 'migrated_project'),
          classificationGuess: 'active_project',
          confidence: 95,
          markerFilesJson: jsonEncode(['README.md']),
          warningsJson: '[]',
          rawJson: jsonEncode({
            'displayName': 'Migrated Project',
            'gitRoot': null,
          }),
          observedAt: DateTime(2026, 1, 1),
        );

        final registryId = await migrated.reviewProjectObservation(
          observationId: 'obs-migrated',
          reviewState: 'accepted',
        );
        final refreshItem = await migrated.upsertLocalProjectRefreshItem(
          registryId: registryId,
          sourceKind: 'doc',
          sourceKey: 'README.md',
          targetType: 'document',
          targetId: 'doc-1',
          sourceFingerprint: 'fingerprint',
          lastImportedAt: DateTime(2026, 1, 2),
        );

        expect(refreshItem, isNotNull);
        expect(refreshItem!.registryId, registryId);
      } finally {
        await migrated.close();
      }
    },
  );

  test('manual scan persists scan run and append-only observations', () async {
    _makeCandidate(tempDir, 'ops_one');

    final runId = await state.runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
    );

    final run = await db.getProjectScanRun(runId);
    final observations = await db.getProjectObservationsForScanRun(runId);

    expect(run, isNotNull);
    expect(run!.status, 'completed');
    expect(run.candidates, 1);
    expect(observations, hasLength(1));
    expect(observations.first.observedPath, contains('ops_one'));
  });

  test('accepting candidate creates reviewed registry record', () async {
    _makeCandidate(tempDir, 'accepted_project');
    final observation = await _scanOne(state, db, tempDir);

    await state.acceptProjectObservation(observation.id);

    final registry = await db.getProjectRegistry();
    expect(registry, hasLength(1));
    expect(registry.first.displayName, 'accepted_project');
    expect(registry.first.reviewState, 'accepted');
    expect(registry.first.localPath, observation.observedPath);
  });

  test(
    'linking candidate connects registry record to existing Atlas project',
    () async {
      _makeCandidate(tempDir, 'linked_project');
      await db.createProject(
        'atlas-project-1',
        'Atlas Project',
        DateTime(2026),
      );
      final observation = await _scanOne(state, db, tempDir);

      await state.linkProjectObservation(observation.id, 'atlas-project-1');

      final registry = await db.getProjectRegistry();
      expect(registry, hasLength(1));
      expect(registry.first.reviewState, 'linked');
      expect(registry.first.atlasProjectId, 'atlas-project-1');
    },
  );

  test('candidate can be ignored', () async {
    _makeCandidate(tempDir, 'ignored_project');
    final observation = await _scanOne(state, db, tempDir);

    await state.ignoreProjectObservation(observation.id);

    final registry = await db.getProjectRegistry();
    expect(registry.single.reviewState, 'ignored');
  });

  test('candidate can be marked needs-review', () async {
    _makeCandidate(tempDir, 'review_project');
    final observation = await _scanOne(state, db, tempDir);

    await state.markProjectObservationNeedsReview(observation.id);

    final registry = await db.getProjectRegistry();
    expect(registry.single.reviewState, 'needs_review');
  });

  test('bulk review accepts selected observations', () async {
    _makeCandidate(tempDir, 'bulk_one');
    _makeCandidate(tempDir, 'bulk_two');
    final runId = await state.runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
    );
    final observations = await db.getProjectObservationsForScanRun(runId);

    await state.acceptProjectObservations(
      observations.map((observation) => observation.id),
    );

    final registry = await db.getProjectRegistry();
    expect(registry, hasLength(2));
    expect(registry.map((entry) => entry.reviewState).toSet(), {'accepted'});
  });

  test(
    'repeat scans attach prior registry decisions to new observations',
    () async {
      _makeCandidate(tempDir, 'remembered_project');
      final first = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(first.id);
      final registry = (await db.getProjectRegistry()).single;

      final secondRunId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final second = (await db.getProjectObservationsForScanRun(
        secondRunId,
      )).single;

      expect(second.registryId, registry.id);
    },
  );

  test(
    'accepted registry entry imports as Atlas project with marker docs',
    () async {
      _makeCandidate(tempDir, 'imported_project');
      File(
        p.join(tempDir.path, 'imported_project', '.env'),
      ).writeAsStringSync('SECRET_VALUE=do-not-import');
      final observation = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;

      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
      );

      final project = await db.getProjectFull(projectId);
      final linkedRegistry = (await db.getProjectRegistry()).single;
      final stages = await db.getStagesForProject(projectId);
      final docs = await db.watchDocumentsForProject(projectId).first;

      expect(project, isNotNull);
      expect(project!.title, 'imported_project');
      expect(project.description, contains('Local path:'));
      expect(linkedRegistry.reviewState, 'linked');
      expect(linkedRegistry.atlasProjectId, projectId);
      expect(stages, hasLength(1));
      expect(stages.single.title, 'Tasks');
      expect(docs.map((doc) => doc.originalFilename), contains('README.md'));
      expect(docs.map((doc) => doc.originalFilename), contains('pubspec.yaml'));
      expect(docs.map((doc) => doc.originalFilename), isNot(contains('.env')));
    },
  );

  test('importing an already linked registry entry is idempotent', () async {
    _makeCandidate(tempDir, 'idempotent_project');
    final observation = await _scanOne(state, db, tempDir);
    await state.acceptProjectObservation(observation.id);
    final registry = (await db.getProjectRegistry()).single;

    final firstProjectId = await state.importProjectRegistryEntryAsProject(
      registry.id,
    );
    final secondProjectId = await state.importProjectRegistryEntryAsProject(
      registry.id,
    );

    final projects = await db.getProjectsFull();
    final docs = await db.watchDocumentsForProject(firstProjectId).first;
    expect(secondProjectId, firstProjectId);
    expect(projects, hasLength(1));
    expect(docs, hasLength(2));
  });

  test('registry import reuses a single matching Atlas project', () async {
    _makeCandidate(tempDir, 'matching_project');
    await db.createProject(
      'existing-project',
      'matching_project',
      DateTime(2026),
    );
    final observation = await _scanOne(state, db, tempDir);
    await state.acceptProjectObservation(observation.id);
    final registry = (await db.getProjectRegistry()).single;

    final projectId = await state.importProjectRegistryEntryAsProject(
      registry.id,
    );

    final projects = await db.getProjectsFull();
    final linkedRegistry = (await db.getProjectRegistry()).single;
    final docs = await db.watchDocumentsForProject(projectId).first;

    expect(projectId, 'existing-project');
    expect(projects, hasLength(1));
    expect(linkedRegistry.atlasProjectId, 'existing-project');
    expect(linkedRegistry.reviewState, 'linked');
    expect(docs.map((doc) => doc.originalFilename), contains('README.md'));
  });

  test(
    'registry row can update an existing BOH project without duplication',
    () async {
      final root = _makeBohCandidate(tempDir);
      await db.createProject('existing-boh', 'Bag.of.holding', DateTime(2026));
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;

      final projectId = await state.updateExistingProjectFromRegistryEntry(
        registry.id,
        'existing-boh',
      );

      final projects = await db.getProjectsFull();
      final linkedRegistry = (await db.getProjectRegistry()).single;
      final decisions = await db.getProjectDecisions(projectId);
      final workItems = await db.getWorkItemsForProject(projectId);
      final docs = await db.getDocumentsForProject(projectId);

      expect(projectId, 'existing-boh');
      expect(projects, hasLength(1));
      expect(linkedRegistry.atlasProjectId, 'existing-boh');
      expect(decisions, hasLength(1));
      expect(decisions.single.title, contains('DEC-0001'));
      expect(
        workItems.map((item) => item.title),
        contains('Await owner-authorized BOH work order'),
      );
      expect(
        docs.where((doc) => doc.originalFilename == 'README.md'),
        hasLength(1),
      );
    },
  );

  test(
    'upload-style existing project update previews before applying refresh',
    () async {
      final root = _makeBohCandidate(tempDir);
      await db.createProject('existing-boh', 'Bag.of.holding', DateTime(2026));
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;

      final projectId = await state.updateExistingProjectFromRegistryEntry(
        registry.id,
        'existing-boh',
        refresh: false,
      );
      final preview = await state.previewLocalProjectRefreshForRegistryEntry(
        registry.id,
        projectId,
      );
      final selected = preview.entries
          .where((entry) => entry.shouldApplyByDefault)
          .map((entry) => entry.action.id)
          .toList(growable: false);
      final beforeApplyDecisions = await db.getProjectDecisions(projectId);
      final beforeApplyLedgers = await db
          .select(db.localProjectRefreshItems)
          .get();

      final result = await state.applyLocalProjectRefreshForRegistryEntry(
        registry.id,
        projectId,
        selectedActionIds: selected,
      );

      final projects = await db.getProjectsFull();
      final linkedRegistry = (await db.getProjectRegistry()).single;
      final decisions = await db.getProjectDecisions(projectId);
      final media = await db.getProjectMedia(projectId);
      final ledgers = await db.select(db.localProjectRefreshItems).get();

      expect(projectId, 'existing-boh');
      expect(projects, hasLength(1));
      expect(linkedRegistry.atlasProjectId, 'existing-boh');
      expect(preview.entries, isNotEmpty);
      expect(selected, isNotEmpty);
      expect(beforeApplyDecisions, isEmpty);
      expect(beforeApplyLedgers, isEmpty);
      expect(result.created + result.updated, greaterThan(0));
      expect(
        decisions.map((decision) => decision.title),
        anyElement(contains('DEC-0001')),
      );
      expect(media.map((item) => item.originalFilename), contains('cover.png'));
      expect(ledgers, isNotEmpty);
    },
  );

  test(
    'new registry import applies the local refresh profile by default',
    () async {
      final root = _makeBohCandidate(tempDir);
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;

      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
      );

      final decisions = await db.getProjectDecisions(projectId);
      final workItems = await db.getWorkItemsForProject(projectId);
      final media = await db.getProjectMedia(projectId);
      final ledgers = await db.select(db.localProjectRefreshItems).get();

      expect(
        decisions.map((decision) => decision.title),
        contains('DEC-0001 - Use Governed Patch Execution'),
      );
      expect(workItems.map((item) => item.title), contains('First next step.'));
      expect(media.map((item) => item.originalFilename), contains('cover.png'));
      expect(ledgers, isNotEmpty);
    },
  );

  test('scan export includes summary and flattened warnings', () async {
    final startedAt = DateTime(2026, 6, 27, 12);
    final runId = await db.startProjectScanRun(
      rootsJson: jsonEncode([tempDir.path]),
      startedAt: startedAt,
    );
    await db.addProjectObservation(
      id: 'obs_warning',
      scanRunId: runId,
      observedPath: p.join(tempDir.path, 'warned_project'),
      classificationGuess: 'needs_review',
      confidence: 55,
      markerFilesJson: jsonEncode(['README.md']),
      warningsJson: jsonEncode(['git remote get-url origin failed']),
      rawJson: jsonEncode({'displayName': 'warned_project'}),
      observedAt: startedAt,
    );
    await db.finishProjectScanRun(
      id: runId,
      completedAt: startedAt.add(const Duration(seconds: 1)),
      status: 'completed',
      totalSeen: 1,
      candidates: 1,
      ignored: 0,
      warningsJson: jsonEncode(['run warning']),
    );

    final exported = await state.buildProjectScanRunExportJson(runId);
    final payload = jsonDecode(exported) as Map<String, Object?>;
    final summary = payload['summary'] as Map<String, Object?>;
    final warnings = payload['warnings'] as Map<String, Object?>;
    final runWarnings = warnings['run'] as List<Object?>;
    final observationWarnings = warnings['observations'] as List<Object?>;

    expect(summary['candidates'], 1);
    expect(summary['runWarnings'], 1);
    expect(summary['observationWarnings'], 1);
    expect(runWarnings, contains('run warning'));
    expect(
      observationWarnings.single.toString(),
      contains('git remote get-url origin failed'),
    );
  });

  test('scan exports can be saved to the app operations folder', () async {
    final runId = await _createWarningRun(db, tempDir);

    final scanPath = await state.saveProjectScanRunExportToAppFolder(runId);
    final warningsPath = await state.saveProjectScanRunWarningsToAppFolder(
      runId,
    );

    expect(scanPath, contains('operations_scans'));
    expect(scanPath, contains('runs'));
    expect(warningsPath, contains('operations_scans'));
    expect(warningsPath, contains('warnings'));
    expect(File(scanPath).existsSync(), isTrue);
    expect(File(warningsPath).existsSync(), isTrue);

    final warningsPayload =
        jsonDecode(File(warningsPath).readAsStringSync())
            as Map<String, Object?>;
    expect(
      warningsPayload['schema'],
      'project_atlas_local_operations_warnings_v1',
    );
    expect(
      warningsPayload.toString(),
      contains('git remote get-url origin failed'),
    );
  });

  test(
    'operations warnings export includes recent run and observation warnings',
    () async {
      await _createWarningRun(db, tempDir);

      final exported = await state.buildOperationsWarningsExportJson();
      final payload = jsonDecode(exported) as Map<String, Object?>;
      final summary = payload['summary'] as Map<String, Object?>;
      final warnings = payload['warnings'] as Map<String, Object?>;
      final runWarnings = warnings['run'] as List<Object?>;
      final observationWarnings = warnings['observations'] as List<Object?>;

      expect(payload['schema'], 'project_atlas_operations_warnings_v1');
      expect(summary['totalWarnings'], 2);
      expect(runWarnings.single.toString(), contains('run warning'));
      expect(
        observationWarnings.single.toString(),
        contains('git remote get-url origin failed'),
      );

      final savedPath = await state.saveOperationsWarningsToAppFolder();
      expect(savedPath, contains('operations_scans'));
      expect(savedPath, contains('warnings'));
      expect(File(savedPath).existsSync(), isTrue);
    },
  );

  test('project health warning groups collapse raw refresh warnings', () {
    final groups = groupProjectHealthWarnings([
      'Artifact not imported as source: release/a.zip (123 bytes).',
      'Artifact not imported as source: release/b.zip (456 bytes).',
      'Bag of Holding: Artifact not imported as source: Bag-of-Holding-clean.tar.gz (45 bytes).',
      'Skipped 3 source file(s) over 256 KB.',
      'Bag of Holding: Skipped 59 source file(s) over 256 KB.',
      'Source file refresh plan capped at 250 actions; skipped 10 additional candidate(s).',
      'Bag of Holding: Source file refresh plan capped at 250 actions; skipped 2294 additional candidate(s).',
      'Coheron: registered local path is a remote URL; replace the folder link or ignore the registry row.',
      r'Old Project: registered local path does not exist: B:\missing',
      'Odd project warning.',
    ]);
    final byKey = {for (final group in groups) group.key: group};

    expect(byKey['artifact_not_imported']?.count, 3);
    expect(byKey['large_source_files']?.count, 2);
    expect(byKey['source_refresh_cap']?.count, 2);
    expect(byKey['remote_url_registry_path']?.count, 1);
    expect(byKey['missing_registry_path']?.count, 1);
    expect(byKey['other_project_warnings']?.count, 1);
    expect(
      byKey['artifact_not_imported']?.title,
      'Artifacts skipped as source files',
    );
  });

  test(
    'BOH refresh preview applies native project updates idempotently',
    () async {
      final root = _makeBohCandidate(tempDir);
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;
      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
        refresh: false,
      );

      final preview = await state.previewLocalProjectRefresh(projectId);
      expect(preview.profile, 'boh');
      expect(
        preview.entries.map((entry) => entry.action.sourceKey),
        contains('DECISIONS.md#dec-0001'),
      );
      expect(
        preview.entries.map((entry) => entry.action.sourceKey),
        contains('ROADMAP.md#next-1'),
      );

      final first = await state.applyLocalProjectRefresh(projectId);
      final second = await state.applyLocalProjectRefresh(projectId);

      final decisions = await db.getProjectDecisions(projectId);
      final workItems = await db.getWorkItemsForProject(projectId);
      final docs = await db.getDocumentsForProject(projectId);
      final ledgers = await db.select(db.localProjectRefreshItems).get();

      expect(first.created + first.updated, greaterThan(0));
      expect(second.created, 0);
      expect(second.updated, 0);
      expect(decisions, hasLength(1));
      expect(decisions.single.title, contains('DEC-0001'));
      expect(workItems.map((item) => item.title), contains('First next step.'));
      expect(
        workItems.map((item) => item.title),
        contains('Await owner-authorized BOH work order'),
      );
      expect(docs.map((doc) => doc.originalFilename), contains('DECISIONS.md'));
      expect(
        docs.where((doc) => doc.originalFilename == 'README.md'),
        hasLength(1),
      );
      expect(ledgers, isNotEmpty);
    },
  );

  test(
    'registry-specific refresh works when multiple entries link to one project',
    () async {
      final bohRoot = _makeBohCandidate(tempDir);
      _makeCandidate(tempDir, 'docs');
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observations = await db.getProjectObservationsForScanRun(runId);
      final bohObservation = observations.singleWhere(
        (row) => row.observedPath == bohRoot.path,
      );
      final docsObservation = observations.singleWhere(
        (row) => row.observedPath.endsWith('${p.separator}docs'),
      );

      await db.createProject(
        'shared-project',
        'Shared Project',
        DateTime(2026),
      );
      await state.linkProjectObservation(bohObservation.id, 'shared-project');
      await state.linkProjectObservation(docsObservation.id, 'shared-project');

      final bohRegistry = await db.getProjectRegistryByPath(bohRoot.path);
      expect(bohRegistry, isNotNull);

      final preview = await state.previewLocalProjectRefreshForRegistryEntry(
        bohRegistry!.id,
        'shared-project',
      );
      expect(preview.localPath, bohRoot.path);

      final result = await state.applyLocalProjectRefreshForRegistryEntry(
        bohRegistry.id,
        'shared-project',
      );
      expect(result.created + result.updated, greaterThan(0));
    },
  );

  test('project detail replacement keeps one active local repo link', () async {
    final oldRoot = _makeSourceCandidate(tempDir, 'old_repo', 'old.dart');
    final newRoot = _makeSourceCandidate(tempDir, 'new_repo', 'new.dart');
    await db.createProject(
      'replace-project',
      'Replace Project',
      DateTime(2026),
    );

    final oldRegistry = await state.replaceProjectLocalRepoLink(
      'replace-project',
      oldRoot.path,
    );
    final newRegistry = await state.replaceProjectLocalRepoLink(
      'replace-project',
      newRoot.path,
    );

    final activeLinks = await db.getProjectRegistryEntriesByAtlasProjectId(
      'replace-project',
    );
    final allRegistry = await db.getProjectRegistry();
    final oldRow = allRegistry.singleWhere((row) => row.id == oldRegistry.id);
    final newRow = allRegistry.singleWhere((row) => row.id == newRegistry.id);
    final preview = await state.previewLocalProjectRefresh('replace-project');
    final sourceKeys = preview.entries
        .where((entry) => entry.action.sourceKind == 'source_file')
        .map((entry) => entry.action.sourceKey)
        .toSet();

    expect(activeLinks, hasLength(1));
    expect(activeLinks.single.id, newRegistry.id);
    expect(oldRow.atlasProjectId, isNull);
    expect(oldRow.reviewState, 'accepted');
    expect(newRow.atlasProjectId, 'replace-project');
    expect(newRow.reviewState, 'linked');
    expect(preview.localPath, newRoot.path);
    expect(sourceKeys, contains('lib/new.dart'));
    expect(sourceKeys, isNot(contains('lib/old.dart')));
  });

  test('project local repo summary reports refresh-associated files', () async {
    final root = _makeSourceCandidate(tempDir, 'summary_repo', 'main.dart');
    await db.createProject(
      'summary-project',
      'Summary Project',
      DateTime(2026),
    );
    await state.replaceProjectLocalRepoLink('summary-project', root.path);

    final before = await state.getProjectLocalRepoSummary('summary-project');
    final result = await state.applyLocalProjectRefresh('summary-project');
    final after = await state.getProjectLocalRepoSummary('summary-project');

    expect(before, isNotNull);
    expect(before!.repoRoot, root.path);
    expect(result.created + result.updated, greaterThan(0));
    expect(after, isNotNull);
    expect(after!.registry?.localPath, root.path);
    expect(after.sourceFileCount, greaterThan(0));
    expect(
      after.documents.map((doc) => doc.originalFilename),
      contains('README.md'),
    );
    expect(
      after.refreshItems.map((item) => item.sourceKey),
      contains('lib/main.dart'),
    );
  });

  test(
    'project local repo summary includes manually associated paths',
    () async {
      await db.createProject(
        'associated-project',
        'Associated Project',
        DateTime(2026),
      );
      final folder = Directory(p.join(tempDir.path, 'reference_folder'))
        ..createSync();
      final file = File(p.join(tempDir.path, 'notes.txt'))
        ..writeAsStringSync('Important project note.');

      await state.associateProjectFolder('associated-project', folder.path);
      await state.associateProjectFile('associated-project', file.path);

      final summary = await state.getProjectLocalRepoSummary(
        'associated-project',
      );

      expect(summary, isNotNull);
      expect(summary!.registry, isNull);
      expect(
        summary.documents.map((doc) => doc.originalFilename),
        contains('notes.txt'),
      );
      expect(summary.media.map((item) => item.mediaType), contains('folder'));
      expect(
        summary.media.map((item) => item.source),
        contains('associated_folder:${folder.path}'),
      );
    },
  );

  test('linked project can cache read-only GitHub remote metadata', () async {
    final root = Directory(p.join(tempDir.path, 'github_project'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'README.md')).writeAsStringSync('# GitHub Project');
    await db.createProject('github-project', 'GitHub Project', DateTime(2026));
    final runId = await db.startProjectScanRun(
      rootsJson: jsonEncode([root.path]),
      startedAt: DateTime(2026, 6, 29),
    );
    await db.addProjectObservation(
      id: 'github_obs',
      scanRunId: runId,
      observedPath: root.path,
      classificationGuess: 'software',
      confidence: 90,
      remoteUrl: 'https://github.com/ppeck1/project-atlas.git',
      markerFilesJson: jsonEncode(['README.md', '.git']),
      warningsJson: '[]',
      rawJson: jsonEncode({
        'displayName': 'GitHub Project',
        'gitRoot': root.path,
      }),
      observedAt: DateTime(2026, 6, 29),
    );
    await db.finishProjectScanRun(
      id: runId,
      completedAt: DateTime(2026, 6, 29, 0, 0, 1),
      status: 'completed',
      totalSeen: 1,
      candidates: 1,
      ignored: 0,
      warningsJson: '[]',
    );
    await state.linkProjectObservation('github_obs', 'github-project');

    final service = GithubRemoteMetadataService(
      runner: (args) async {
        final endpoint = args[1];
        if (endpoint.endsWith('/commits/main')) {
          return ProcessResult(1, 0, 'abc123\n', '');
        }
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'private': false,
            'fork': false,
            'archived': false,
            'visibility': 'public',
            'default_branch': 'main',
            'html_url': 'https://github.com/ppeck1/project-atlas',
          }),
          '',
        );
      },
    );

    final status = await state.refreshProjectGithubRemoteMetadata(
      'github-project',
      service: service,
    );
    final cached = await state.getLatestProjectGitRemoteStatus(
      'github-project',
    );

    expect(status.fullName, 'ppeck1/project-atlas');
    expect(status.visibility, 'public');
    expect(status.onlineHeadSha, 'abc123');
    expect(cached?.fullName, 'ppeck1/project-atlas');
  });

  test(
    'linked project GitHub metadata can be manually replaced and cleared',
    () async {
      await db.createProject(
        'github-project',
        'GitHub Project',
        DateTime(2026),
      );

      final saved = await state.saveManualProjectGithubRemoteMetadata(
        'github-project',
        'https://github.com/ppeck1/Coheron',
      );
      final cached = await state.getLatestProjectGitRemoteStatus(
        'github-project',
      );

      expect(saved.fullName, 'ppeck1/Coheron');
      expect(cached?.htmlUrl, 'https://github.com/ppeck1/Coheron');

      await state.clearProjectGithubRemoteMetadata('github-project');
      final cleared = await state.getLatestProjectGitRemoteStatus(
        'github-project',
      );

      expect(cleared, isNull);
    },
  );

  test('local refresh imports project media idempotently', () async {
    final root = _makeBohCandidate(tempDir);
    final runId = await state.runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
    );
    final observation = (await db.getProjectObservationsForScanRun(
      runId,
    )).singleWhere((row) => row.observedPath == root.path);
    await state.acceptProjectObservation(observation.id);
    final registry = (await db.getProjectRegistry()).single;
    final projectId = await state.importProjectRegistryEntryAsProject(
      registry.id,
      refresh: false,
    );

    final first = await state.applyLocalProjectRefresh(projectId);
    final second = await state.applyLocalProjectRefresh(projectId);
    final media = await db.getProjectMedia(projectId);

    expect(first.created + first.updated, greaterThan(0));
    expect(second.created, 0);
    expect(second.updated, 0);
    expect(media, hasLength(1));
    expect(media.single.originalFilename, 'cover.png');
    expect(media.single.source, 'local_refresh:assets/cover.png');
  });

  test(
    'refresh plan includes software source files with strict excludes',
    () async {
      final root = Directory(p.join(tempDir.path, 'source_project'))
        ..createSync(recursive: true);
      Directory(p.join(root.path, 'lib')).createSync();
      File(p.join(root.path, 'README.md')).writeAsStringSync('# Source');
      File(
        p.join(root.path, 'lib', 'main.dart'),
      ).writeAsStringSync('void main() {}\n');
      File(
        p.join(root.path, 'lib', 'generated.g.dart'),
      ).writeAsStringSync('const generated = true;\n');
      File(
        p.join(root.path, 'lib', 'api_key.dart'),
      ).writeAsStringSync('const secret = "do-not-import";\n');
      File(p.join(root.path, '.env')).writeAsStringSync('SECRET_VALUE=abc');
      Directory(
        p.join(root.path, 'node_modules', 'hidden'),
      ).createSync(recursive: true);
      File(
        p.join(root.path, 'node_modules', 'hidden', 'index.js'),
      ).writeAsStringSync('module.exports = {};\n');
      Directory(p.join(root.path, 'build')).createSync();
      File(
        p.join(root.path, 'build', 'bundle.js'),
      ).writeAsStringSync('console.log("built");\n');
      File(p.join(root.path, 'lib', 'large.dart')).writeAsBytesSync(
        List.filled(LocalProjectRefreshService.maxSourceFileBytes + 1, 65),
      );

      final plan = await const LocalProjectRefreshService().buildPlan(
        root.path,
      );
      final sourceKeys = plan.actions
          .where((action) => action.sourceKind == 'source_file')
          .map((action) => action.sourceKey)
          .toSet();

      expect(sourceKeys, contains('lib/main.dart'));
      expect(sourceKeys, isNot(contains('lib/generated.g.dart')));
      expect(sourceKeys, isNot(contains('lib/api_key.dart')));
      expect(sourceKeys, isNot(contains('.env')));
      expect(sourceKeys, isNot(contains('node_modules/hidden/index.js')));
      expect(sourceKeys, isNot(contains('build/bundle.js')));
      expect(sourceKeys, isNot(contains('lib/large.dart')));
      expect(
        plan.warnings,
        contains(
          predicate<String>(
            (warning) => warning.contains('source file(s) over'),
          ),
        ),
      );
    },
  );

  test('refresh plan caps huge software source plans', () async {
    final root = Directory(p.join(tempDir.path, 'cap_project'))
      ..createSync(recursive: true);
    final lib = Directory(p.join(root.path, 'lib'))..createSync();
    for (
      var i = 0;
      i < LocalProjectRefreshService.maxSourceFileActions + 3;
      i++
    ) {
      File(
        p.join(lib.path, 'file_$i.dart'),
      ).writeAsStringSync('void f$i() {}\n');
    }

    final plan = await const LocalProjectRefreshService().buildPlan(root.path);
    final sourceActions = plan.actions
        .where((action) => action.sourceKind == 'source_file')
        .toList();

    expect(
      sourceActions,
      hasLength(LocalProjectRefreshService.maxSourceFileActions),
    );
    expect(
      plan.warnings,
      contains(
        predicate<String>(
          (warning) => warning.contains('Source file refresh plan capped'),
        ),
      ),
    );
  });

  test(
    'refresh plan emits generated-document card actions for atlas libraries',
    () async {
      final root = Directory(p.join(tempDir.path, 'card_project'))
        ..createSync(recursive: true);
      final tradeCards = Directory(p.join(root.path, 'trade_craft', 'cards'))
        ..createSync(recursive: true);
      File(p.join(tradeCards.path, 'flint.md')).writeAsStringSync('''
# Flint Knapper

Pressure flakes a useful edge.
''');
      final productivity = Directory(p.join(root.path, 'productivity'))
        ..createSync();
      File(
        p.join(productivity.path, 'focus.goalcard.md'),
      ).writeAsStringSync('# Focus Block\nProtect one work interval.\n');
      final philosophy = Directory(p.join(root.path, 'philosophy'))
        ..createSync();
      File(p.join(philosophy.path, 'cards.json')).writeAsStringSync(
        jsonEncode({
          'cards': [
            {
              'id': 'stoic-practice',
              'title': 'Stoic Practice',
              'summary': 'Separate control from concern.',
            },
          ],
        }),
      );
      final preIndustrial = Directory(
        p.join(root.path, 'Pre_Industrialization'),
      )..createSync();
      File(p.join(preIndustrial.path, 'index.html')).writeAsStringSync('''
<section><h2>Village Forge</h2><p>Local heat and repair.</p></section>
<details><summary>Canal Lock</summary><p>Water control pattern.</p></details>
''');

      final plan = await const LocalProjectRefreshService().buildPlan(
        root.path,
      );
      final cardActions = plan.actions
          .where((action) => action.sourceKind == 'atlas_card')
          .toList();
      final cardKeys = cardActions.map((action) => action.sourceKey).toSet();

      expect(cardKeys, contains('trade_craft/cards/flint.md#card'));
      expect(cardKeys, contains('productivity/focus.goalcard.md#card'));
      expect(cardKeys, contains('philosophy/cards.json#card-stoic-practice'));
      expect(cardKeys, contains('Pre_Industrialization/index.html#section-1'));
      expect(cardKeys, contains('Pre_Industrialization/index.html#details-1'));
      expect(cardActions.map((action) => action.targetType).toSet(), {
        'document',
      });
      expect(
        cardActions.every(
          (action) =>
              action.payload['generatedText'] is String &&
              action.payload['metadataJson'] is String,
        ),
        isTrue,
      );
      expect(
        (jsonDecode(
              cardActions
                      .singleWhere(
                        (action) =>
                            action.sourceKey ==
                            'philosophy/cards.json#card-stoic-practice',
                      )
                      .payload['metadataJson']!
                  as String,
            )
            as Map<String, Object?>)['cardId'],
        'stoic-practice',
      );
    },
  );

  test(
    'html2md-like refresh uses launchpad metadata and handoff verification',
    () async {
      final root = _makeHtml2mdCandidate(tempDir);

      final plan = await const LocalProjectRefreshService().buildPlan(
        root.path,
      );
      final metaAction = plan.actions.singleWhere(
        (action) =>
            action.sourceKind == 'project_meta' &&
            action.sourceKey == '.project/launchpad.json#project-metadata',
      );
      final workTitles = plan.actions
          .where((action) => action.sourceKind == 'work_item')
          .map((action) => action.title)
          .toSet();
      final documentKeys = plan.actions
          .where((action) => action.sourceKind == 'document')
          .map((action) => action.sourceKey)
          .toSet();
      final sourceKeys = plan.actions
          .where((action) => action.sourceKind == 'source_file')
          .map((action) => action.sourceKey)
          .toSet();

      expect(metaAction.targetType, 'project');
      expect(metaAction.payload['title'], 'HTML2MD Reanimator');
      expect(
        metaAction.payload['description'].toString(),
        contains('Windows-first HTML-to-Markdown recovery workstation'),
      );
      expect(metaAction.payload['scopeIncluded'].toString(), contains('html'));
      expect(metaAction.payload['scopeIncluded'].toString(), contains('start'));
      expect(metaAction.payload['manifestTags'], contains('markdown'));
      expect(documentKeys, contains('docs/HANDOFF.md'));
      expect(workTitles, contains('Run the manifest test command if present.'));
      expect(workTitles, contains('Launch the project from Dev Launchpad.'));
      expect(sourceKeys, contains('codex_reanimator/app.py'));
      expect(sourceKeys, isNot(contains('.project/launchpad.json')));
      expect(sourceKeys, isNot(contains('docs/HANDOFF.md')));
      expect(sourceKeys, isNot(contains('tests/fixtures/simple.html')));
      expect(sourceKeys, isNot(contains('release/CodexReanimator.exe')));
      expect(
        plan.warnings,
        contains(
          predicate<String>(
            (warning) => warning.contains('release/CodexReanimator.exe'),
          ),
        ),
      );

      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;
      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
        refresh: false,
      );

      final first = await state.applyLocalProjectRefresh(projectId);
      final second = await state.applyLocalProjectRefresh(projectId);
      final project = await db.getProjectFull(projectId);
      final workItems = await db.getWorkItemsForProject(projectId);
      final tags = await db.getTagsForProject(projectId);
      final ledgers = await db.select(db.localProjectRefreshItems).get();

      expect(first.created + first.updated, greaterThan(0));
      expect(second.created, 0);
      expect(second.updated, 0);
      expect(project!.title, 'HTML2MD Reanimator');
      expect(
        project.description,
        contains('Windows-first HTML-to-Markdown recovery workstation'),
      );
      expect(
        workItems.map((item) => item.title),
        contains('Run the manifest test command if present.'),
      );
      expect(
        tags.map((tag) => tag.name).toSet(),
        containsAll({'markdown', 'desktop', 'Local AI Stack'}),
      );
      expect(
        ledgers.map((row) => row.sourceKey),
        contains('.project/launchpad.json#project-metadata'),
      );
    },
  );

  test(
    'project enrichment refreshes linked project artifacts and records coverage',
    () async {
      final root = _makeHtml2mdCandidate(tempDir);
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;
      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
        refresh: false,
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: true,
        includeSourceDocuments: true,
        refreshSummaries: false,
        betweenProjects: Duration.zero,
      );
      final ledgers = await db.getLocalProjectRefreshItemsForRegistry(
        registry.id,
      );
      final docs = await db.getDocumentsForProject(projectId);
      final steps = await db.getProjectEnrichmentStepsForRun(result.run.id);
      final proposals = await db.getProjectEnrichmentProposalsForRun(
        result.run.id,
      );
      final coverage = result.run.output['coverage'] as Map;

      expect(result.run.linkedProjects, 1);
      expect(result.run.createdItems, greaterThan(0));
      expect(result.run.findings, result.findings.length);
      expect(result.steps, isNotEmpty);
      expect(result.proposals, isNotEmpty);
      expect(coverage['projects'], 1);
      expect(coverage['sourceFiles'], greaterThan(0));
      expect(coverage['documents'], greaterThan(0));
      expect(ledgers.map((row) => row.sourceKind), contains('source_file'));
      expect(docs.map((doc) => doc.title), contains('codex_reanimator/app.py'));
      expect(
        steps.map((step) => step.worker),
        containsAll([
          'registry',
          'documents_media',
          'identity',
          'verification',
          'correction',
        ]),
      );
      expect(steps.map((step) => step.worker), isNot(contains('summary')));
      expect(proposals.map((proposal) => proposal.worker).toSet(), {
        'correction',
      });
      expect(proposals.first.payload['sourceReposMutated'], isFalse);
    },
  );

  test(
    'project enrichment analyze dry-run records findings without applying refresh',
    () async {
      final root = _makeHtml2mdCandidate(tempDir);
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;
      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
        refresh: false,
      );
      final beforeProject = await db.getProjectFull(projectId);
      final beforeDocs = await db.getDocumentsForProject(projectId);
      final beforeLedgers = await db.getLocalProjectRefreshItemsForRegistry(
        registry.id,
      );
      final beforeWorkItems = await db.getWorkItemsForProject(projectId);
      final beforeTags = await db.getTagsForProject(projectId);

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: true,
        includeSourceDocuments: true,
        analyzeOnly: true,
        projectIds: [projectId],
        refreshSummaries: false,
        betweenProjects: Duration.zero,
      );
      final afterProject = await db.getProjectFull(projectId);
      final afterDocs = await db.getDocumentsForProject(projectId);
      final afterLedgers = await db.getLocalProjectRefreshItemsForRegistry(
        registry.id,
      );
      final afterWorkItems = await db.getWorkItemsForProject(projectId);
      final afterTags = await db.getTagsForProject(projectId);
      final steps = await db.getProjectEnrichmentStepsForRun(result.run.id);
      final proposals = await db.getProjectEnrichmentProposalsForRun(
        result.run.id,
      );
      final coverage = result.run.output['coverage'] as Map;

      expect(result.run.status, 'analyzed_with_findings');
      expect(result.run.createdItems, 0);
      expect(result.run.updatedItems, 0);
      expect(result.findings, isNotEmpty);
      expect(result.proposals, isEmpty);
      expect(proposals, isEmpty);
      expect(coverage['projects'], 1);
      expect(coverage['sourceFiles'], 0);
      expect(afterProject!.title, beforeProject!.title);
      expect(afterProject.description, beforeProject.description);
      expect(afterDocs.map((doc) => doc.id), beforeDocs.map((doc) => doc.id));
      expect(afterLedgers, hasLength(beforeLedgers.length));
      expect(afterWorkItems, hasLength(beforeWorkItems.length));
      expect(afterTags, hasLength(beforeTags.length));
      expect(
        steps.map((step) => '${step.worker}:${step.status}'),
        containsAll([
          'documents_media:skipped',
          'identity:skipped',
          'correction:skipped',
        ]),
      );
    },
  );

  test(
    'project enrichment repairs manifest tags even when metadata ledger is unchanged',
    () async {
      final root = _makeHtml2mdCandidate(tempDir);
      final runId = await state.runLocalOperationsScan(
        scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
      );
      final observation = (await db.getProjectObservationsForScanRun(
        runId,
      )).singleWhere((row) => row.observedPath == root.path);
      await state.acceptProjectObservation(observation.id);
      final registry = (await db.getProjectRegistry()).single;
      final projectId = await state.importProjectRegistryEntryAsProject(
        registry.id,
        refresh: false,
      );

      await state.applyLocalProjectRefresh(projectId);
      await db.setProjectTags(projectId, const []);

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        refreshSummaries: false,
      );
      final tags = await db.getTagsForProject(projectId);
      final steps = await db.getProjectEnrichmentStepsForRun(result.run.id);
      final identityStep = steps.singleWhere(
        (step) => step.worker == 'identity',
      );

      expect(
        tags.map((tag) => tag.name).toSet(),
        containsAll({'markdown', 'desktop', 'Local AI Stack'}),
      );
      expect(identityStep.status, 'completed');
      expect(identityStep.updatedItems, 1);
      expect(result.run.updatedItems, greaterThan(0));
    },
  );

  test(
    'project enrichment records unlinked registry and missing detail findings',
    () async {
      _makeCandidate(tempDir, 'unlinked_project');
      final observation = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(observation.id);
      await db.createProject(
        'manual-project',
        'Manual Project',
        DateTime(2026),
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        refreshSummaries: false,
      );
      final titles = result.findings.map((finding) => finding.title).toSet();
      final categories = result.findings
          .map((finding) => finding.category)
          .toSet();

      expect(result.run.status, 'completed_with_findings');
      expect(result.run.openFindings, greaterThan(0));
      expect(
        titles,
        contains('Registered local project is not linked to an Atlas project.'),
      );
      expect(
        titles,
        contains('Atlas project is not linked to a local registry entry.'),
      );
      expect(categories, contains('library'));
      expect(categories, isNot(contains('governance')));
      expect(
        titles,
        isNot(contains('Project has no people/role assignments.')),
      );
      expect(titles, isNot(contains('Project has no imported media.')));
      expect(titles, isNot(contains('Project workboard has no tasks.')));
      expect(titles, isNot(contains('Project appears local-only.')));
      expect(titles, isNot(contains('Project has no risks/issues recorded.')));
      expect(titles, isNot(contains('Project decision log is empty.')));
    },
  );

  test(
    'project enrichment avoids duplicate needs-review and unlinked registry findings',
    () async {
      _makeCandidate(tempDir, 'needs_review_project');
      final observation = await _scanOne(state, db, tempDir);
      await state.markProjectObservationNeedsReview(observation.id);

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        refreshSummaries: false,
      );
      final titles = result.findings.map((finding) => finding.title).toList();
      final needsReview = result.findings.singleWhere(
        (finding) =>
            finding.title == 'Registered local project still needs review.',
      );

      expect(
        titles,
        isNot(
          contains(
            'Registered local project is not linked to an Atlas project.',
          ),
        ),
      );
      expect(needsReview.registryId, isNotNull);
      expect(
        needsReview.evidence['registryDisplayName'],
        'needs_review_project',
      );
      expect(
        needsReview.evidence['localPath'],
        contains('needs_review_project'),
      );
    },
  );

  test(
    'project enrichment records remote-url registry paths without failing',
    () async {
      await db.createProject(
        'remote-url-project',
        'Remote URL Project',
        DateTime(2026),
      );
      final runId = await db.startProjectScanRun(
        rootsJson: jsonEncode(['https://github.com/ppeck1/Coheron']),
        startedAt: DateTime(2026, 7, 2),
      );
      await db.addProjectObservation(
        id: 'remote_url_obs',
        scanRunId: runId,
        observedPath: 'https://github.com/ppeck1/Coheron',
        classificationGuess: 'software',
        confidence: 80,
        markerFilesJson: jsonEncode(['README.md']),
        warningsJson: '[]',
        rawJson: jsonEncode({'displayName': 'Coheron'}),
        observedAt: DateTime(2026, 7, 2),
      );
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime(2026, 7, 2, 0, 0, 1),
        status: 'completed',
        totalSeen: 1,
        candidates: 1,
        ignored: 0,
        warningsJson: '[]',
      );
      await state.linkProjectObservation(
        'remote_url_obs',
        'remote-url-project',
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        projectIds: const ['remote-url-project'],
        refreshSummaries: false,
      );
      final titles = result.findings.map((finding) => finding.title).toSet();
      final registryFinding = result.findings.singleWhere(
        (finding) =>
            finding.title ==
            'Registered local path is a remote URL, not a local folder.',
      );

      expect(result.run.status, 'analyzed_with_findings');
      expect(titles, contains(registryFinding.title));
      expect(registryFinding.severity, 'info');
      expect(registryFinding.detail, 'https://github.com/ppeck1/Coheron');
      expect(registryFinding.evidence['pathKind'], 'remote_url');
    },
  );

  test(
    'project enrichment skips remote-url registry paths during apply run',
    () async {
      await db.createProject(
        'remote-url-project',
        'Remote URL Project',
        DateTime(2026),
      );
      final runId = await db.startProjectScanRun(
        rootsJson: jsonEncode(['https://github.com/ppeck1/Coheron']),
        startedAt: DateTime(2026, 7, 2),
      );
      await db.addProjectObservation(
        id: 'remote_url_obs',
        scanRunId: runId,
        observedPath: 'https://github.com/ppeck1/Coheron',
        classificationGuess: 'software',
        confidence: 80,
        markerFilesJson: jsonEncode(['README.md']),
        warningsJson: '[]',
        rawJson: jsonEncode({'displayName': 'Coheron'}),
        observedAt: DateTime(2026, 7, 2),
      );
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime(2026, 7, 2, 0, 0, 1),
        status: 'completed',
        totalSeen: 1,
        candidates: 1,
        ignored: 0,
        warningsJson: '[]',
      );
      await state.linkProjectObservation(
        'remote_url_obs',
        'remote-url-project',
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: true,
        refreshIdentity: true,
        createProposals: false,
        projectIds: const ['remote-url-project'],
        refreshSummaries: false,
      );
      final warnings = result.run.warnings.join('\n');
      final titles = result.findings.map((finding) => finding.title).toSet();
      final exported =
          jsonDecode(await state.buildProjectHealthRunExportJson(result.run.id))
              as Map<String, Object?>;
      final exportedSummary = exported['summary'] as Map<String, Object?>;
      final warningGroups = exported['warningGroups'] as List<Object?>;

      expect(result.run.status, 'completed_with_findings');
      expect(result.run.failedProjects, 0);
      expect(warnings, contains('registered local path is a remote URL'));
      expect(warnings, isNot(contains('PathNotFoundException: Exists failed')));
      expect(
        titles,
        contains('Registered local path is a remote URL, not a local folder.'),
      );
      expect(exportedSummary['warningGroups'], greaterThan(0));
      expect(
        warningGroups.map((group) => group.toString()).join('\n'),
        contains('remote_url_registry_path'),
      );
    },
  );

  test(
    'project health finding can ignore registry row and export run',
    () async {
      await db.createProject(
        'remote-url-project',
        'Remote URL Project',
        DateTime(2026),
      );
      final runId = await db.startProjectScanRun(
        rootsJson: jsonEncode(['https://github.com/ppeck1/Coheron']),
        startedAt: DateTime(2026, 7, 2),
      );
      await db.addProjectObservation(
        id: 'remote_url_obs',
        scanRunId: runId,
        observedPath: 'https://github.com/ppeck1/Coheron',
        classificationGuess: 'software',
        confidence: 80,
        markerFilesJson: jsonEncode(['README.md']),
        warningsJson: '[]',
        rawJson: jsonEncode({'displayName': 'Coheron'}),
        observedAt: DateTime(2026, 7, 2),
      );
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime(2026, 7, 2, 0, 0, 1),
        status: 'completed',
        totalSeen: 1,
        candidates: 1,
        ignored: 0,
        warningsJson: '[]',
      );
      await state.linkProjectObservation(
        'remote_url_obs',
        'remote-url-project',
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        projectIds: const ['remote-url-project'],
        refreshSummaries: false,
      );
      final finding = result.findings.singleWhere(
        (finding) =>
            finding.title ==
            'Registered local path is a remote URL, not a local folder.',
      );
      final openBefore = result.run.openFindings;

      await state.dismissProjectEnrichmentFinding(
        findingId: finding.id,
        ignoreRegistryEntry: true,
        actor: 'Paul Peck',
        note: 'No longer part of this project.',
      );
      final updatedFinding = await db.getProjectEnrichmentFinding(finding.id);
      final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
      final registry = await db.getProjectRegistryEntry(finding.registryId!);
      final events = await state.getRecentEvents();
      final exported =
          jsonDecode(await state.buildProjectHealthRunExportJson(result.run.id))
              as Map<String, Object?>;
      final exportedSummary = exported['summary'] as Map<String, Object?>;

      expect(updatedFinding?.status, 'dismissed');
      expect(updatedRun?.openFindings, openBefore - 1);
      expect(registry?.reviewState, 'ignored');
      expect(registry?.atlasProjectId, isNull);
      expect(registry?.notes, contains('Paul Peck'));
      expect(
        events.map((event) => event.action),
        contains('project_health_registry_finding_ignored'),
      );
      expect(exported['schema'], 'project_atlas_project_health_run_v1');
      expect(exportedSummary['findings'], result.findings.length);
      expect(exportedSummary['openFindings'], openBefore - 1);
    },
  );

  test('project health needs-review findings can be marked reviewed', () async {
    _makeCandidate(tempDir, 'review_from_health_one');
    _makeCandidate(tempDir, 'review_from_health_two');
    final runId = await state.runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
    );
    final observations = await db.getProjectObservationsForScanRun(runId);
    for (final observation in observations) {
      await state.markProjectObservationNeedsReview(observation.id);
    }

    final result = await state.runProjectEnrichment(
      refreshLinkedProjects: false,
      analyzeOnly: true,
      refreshSummaries: false,
    );
    final findings = result.findings
        .where(
          (finding) =>
              finding.title == 'Registered local project still needs review.',
        )
        .toList(growable: false);

    final reviewed = await state.markProjectHealthRegistryFindingsReviewed(
      findingIds: findings.map((finding) => finding.id),
      actor: 'Paul Peck',
      note: 'Looks intentional.',
    );
    final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
    final updatedFindings = await db.getProjectEnrichmentFindingsForRun(
      result.run.id,
    );
    final registry = await db.getProjectRegistry();
    final events = await state.getRecentEvents();

    expect(reviewed, hasLength(2));
    expect(registry.map((entry) => entry.reviewState).toSet(), {'accepted'});
    expect(
      updatedFindings
          .where((finding) => findings.any((target) => target.id == finding.id))
          .map((finding) => finding.status)
          .toSet(),
      {'dismissed'},
    );
    expect(updatedRun?.openFindings, result.run.openFindings - findings.length);
    expect(
      events.map((event) => event.action),
      contains('project_health_registry_findings_batch_reviewed'),
    );
    expect(
      events.map((event) => event.action),
      contains('project_health_registry_finding_reviewed'),
    );
  });

  test(
    'project health registry finding can link an existing project',
    () async {
      _makeCandidate(tempDir, 'unlinked_project');
      final observation = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(observation.id);
      await db.createProject(
        'target-project',
        'Target Project',
        DateTime(2026),
      );

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        refreshSummaries: false,
      );
      final finding = result.findings.singleWhere(
        (finding) =>
            finding.title ==
            'Registered local project is not linked to an Atlas project.',
      );

      final projectId = await state.linkProjectHealthRegistryFindingToProject(
        findingId: finding.id,
        projectId: 'target-project',
        actor: 'Paul Peck',
      );
      final updatedFinding = await db.getProjectEnrichmentFinding(finding.id);
      final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
      final registry = await db.getProjectRegistryEntry(finding.registryId!);
      final events = await state.getRecentEvents();

      expect(projectId, 'target-project');
      expect(updatedFinding?.status, 'dismissed');
      expect(updatedRun?.openFindings, result.run.openFindings - 1);
      expect(registry?.atlasProjectId, 'target-project');
      expect(registry?.reviewState, 'linked');
      expect(
        events.map((event) => event.action),
        contains('project_health_registry_finding_linked'),
      );
    },
  );

  test('project health registry finding can import a new project', () async {
    _makeCandidate(tempDir, 'import_from_health');
    final observation = await _scanOne(state, db, tempDir);
    await state.acceptProjectObservation(observation.id);

    final result = await state.runProjectEnrichment(
      refreshLinkedProjects: false,
      analyzeOnly: true,
      refreshSummaries: false,
    );
    final finding = result.findings.singleWhere(
      (finding) =>
          finding.title ==
          'Registered local project is not linked to an Atlas project.',
    );

    final projectId = await state.importProjectHealthRegistryFindingAsProject(
      findingId: finding.id,
      actor: 'Paul Peck',
    );
    final project = await db.getProjectFull(projectId);
    final updatedFinding = await db.getProjectEnrichmentFinding(finding.id);
    final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
    final registry = await db.getProjectRegistryEntry(finding.registryId!);
    final events = await state.getRecentEvents();

    expect(project, isNotNull);
    expect(project?.title, 'import_from_health');
    expect(updatedFinding?.status, 'dismissed');
    expect(updatedRun?.openFindings, result.run.openFindings - 1);
    expect(registry?.atlasProjectId, projectId);
    expect(registry?.reviewState, 'linked');
    expect(
      events.map((event) => event.action),
      contains('project_health_registry_finding_imported'),
    );
  });

  test(
    'project health registry finding can replace a bad folder path',
    () async {
      await db.createProject(
        'remote-url-project',
        'Remote URL Project',
        DateTime(2026),
      );
      final runId = await db.startProjectScanRun(
        rootsJson: jsonEncode(['https://github.com/ppeck1/Coheron']),
        startedAt: DateTime(2026, 7, 2),
      );
      await db.addProjectObservation(
        id: 'remote_url_obs',
        scanRunId: runId,
        observedPath: 'https://github.com/ppeck1/Coheron',
        classificationGuess: 'software',
        confidence: 80,
        markerFilesJson: jsonEncode(['README.md']),
        warningsJson: '[]',
        rawJson: jsonEncode({'displayName': 'Coheron'}),
        observedAt: DateTime(2026, 7, 2),
      );
      await db.finishProjectScanRun(
        id: runId,
        completedAt: DateTime(2026, 7, 2, 0, 0, 1),
        status: 'completed',
        totalSeen: 1,
        candidates: 1,
        ignored: 0,
        warningsJson: '[]',
      );
      await state.linkProjectObservation(
        'remote_url_obs',
        'remote-url-project',
      );
      _makeCandidate(tempDir, 'coheron_replacement');
      final replacementPath = p.join(tempDir.path, 'coheron_replacement');

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        projectIds: const ['remote-url-project'],
        refreshSummaries: false,
      );
      final finding = result.findings.singleWhere(
        (finding) =>
            finding.title ==
            'Registered local path is a remote URL, not a local folder.',
      );

      final updatedRegistry = await state
          .replaceProjectHealthRegistryFindingFolder(
            findingId: finding.id,
            selectedPath: replacementPath,
            actor: 'Paul Peck',
          );
      final updatedFinding = await db.getProjectEnrichmentFinding(finding.id);
      final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
      final project = await db.getProjectFull('remote-url-project');
      final events = await state.getRecentEvents();

      expect(updatedRegistry.localPath, replacementPath);
      expect(updatedRegistry.reviewState, 'linked');
      expect(updatedFinding?.status, 'dismissed');
      expect(updatedRun?.openFindings, result.run.openFindings - 1);
      expect(project?.scopeIncluded, contains(replacementPath));
      expect(updatedRegistry.notes, contains('Paul Peck'));
      expect(
        events.map((event) => event.action),
        contains('project_health_registry_folder_replaced'),
      );
    },
  );

  test('project health finding groups can be batch dismissed', () async {
    _makeCandidate(tempDir, 'unlinked_project');
    final observation = await _scanOne(state, db, tempDir);
    await state.acceptProjectObservation(observation.id);
    await db.createProject('manual-project', 'Manual Project', DateTime(2026));

    final result = await state.runProjectEnrichment(
      refreshLinkedProjects: false,
      analyzeOnly: true,
      refreshSummaries: false,
    );
    final targets = result.findings.take(2).toList(growable: false);

    await state.dismissProjectEnrichmentFindings(
      findingIds: targets.map((finding) => finding.id),
      actor: 'Paul Peck',
      note: 'Batch cleanup.',
    );
    final updatedRun = await db.getProjectEnrichmentRun(result.run.id);
    final updatedFindings = await db.getProjectEnrichmentFindingsForRun(
      result.run.id,
    );
    final events = await state.getRecentEvents();

    expect(
      updatedFindings
          .where((finding) => targets.any((target) => target.id == finding.id))
          .map((finding) => finding.status)
          .toSet(),
      {'dismissed'},
    );
    expect(updatedRun?.openFindings, result.run.openFindings - targets.length);
    expect(
      events.map((event) => event.action),
      contains('project_health_findings_batch_dismissed'),
    );
  });

  test(
    'project health finding suppression prevents matching future findings',
    () async {
      _makeCandidate(tempDir, 'suppressed_project');
      final observation = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(observation.id);

      final first = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        refreshSummaries: false,
      );
      final finding = first.findings.singleWhere(
        (finding) =>
            finding.title ==
            'Registered local project is not linked to an Atlas project.',
      );

      final suppression = await state.suppressProjectHealthFinding(
        findingId: finding.id,
        actor: 'Paul Peck',
        note: 'Known registry row.',
      );
      final updatedFinding = await db.getProjectEnrichmentFinding(finding.id);
      final updatedRun = await db.getProjectEnrichmentRun(first.run.id);
      final suppressions = await state.getProjectHealthFindingSuppressions();

      final second = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        refreshSummaries: false,
      );
      final secondTitles = second.findings
          .map((finding) => finding.title)
          .toSet();
      final secondCoverage = second.run.output['coverage'] as Map;
      final secondExport =
          jsonDecode(await state.buildProjectHealthRunExportJson(second.run.id))
              as Map<String, Object?>;
      final secondSummary = secondExport['summary'] as Map<String, Object?>;

      expect(suppression.fingerprint, isNotEmpty);
      expect(updatedFinding?.status, 'suppressed');
      expect(updatedRun?.openFindings, first.run.openFindings - 1);
      expect(
        suppressions.map((item) => item.fingerprint),
        contains(suppression.fingerprint),
      );
      expect(
        secondTitles,
        isNot(
          contains(
            'Registered local project is not linked to an Atlas project.',
          ),
        ),
      );
      expect(secondCoverage['suppressedFindings'], 1);
      expect(secondSummary['suppressedFindings'], 1);
    },
  );

  test(
    'project enrichment selected project scope limits audit findings',
    () async {
      _makeCandidate(tempDir, 'unlinked_project');
      final observation = await _scanOne(state, db, tempDir);
      await state.acceptProjectObservation(observation.id);
      await db.createProject(
        'selected-project',
        'Selected Project',
        DateTime(2026),
      );
      await db.createProject('other-project', 'Other Project', DateTime(2026));

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        analyzeOnly: true,
        projectIds: const ['selected-project'],
        refreshSummaries: false,
      );
      final titles = result.findings.map((finding) => finding.title).toSet();
      final projectIds = result.findings
          .map((finding) => finding.projectId)
          .toSet();
      final coverage = result.run.output['coverage'] as Map;

      expect(result.run.status, 'analyzed_with_findings');
      expect(result.run.scope['projectIds'], ['selected-project']);
      expect(coverage['projects'], 1);
      expect(coverage['registryEntries'], 0);
      expect(projectIds, {'selected-project'});
      expect(
        titles,
        isNot(
          contains(
            'Registered local project is not linked to an Atlas project.',
          ),
        ),
      );
      expect(
        titles,
        contains('Atlas project is not linked to a local registry entry.'),
      );
    },
  );

  test('stale enrichment runs and steps recover as interrupted', () async {
    final startedAt = DateTime(2026, 6, 29, 12);
    final runId = await db.startProjectEnrichmentRun(
      startedAt: startedAt,
      scopeJson: jsonEncode({'schema': 'test'}),
    );
    await db.startProjectEnrichmentStep(
      runId: runId,
      worker: 'summary',
      title: 'Summary agent',
      startedAt: startedAt,
    );

    await db.recoverStaleProjectEnrichmentRuns(
      recoveredAt: startedAt.add(const Duration(minutes: 5)),
    );

    final run = await db.getProjectEnrichmentRun(runId);
    final steps = await db.getProjectEnrichmentStepsForRun(runId);

    expect(run, isNotNull);
    expect(run!.status, 'interrupted');
    expect(run.completedAt, isNotNull);
    expect(steps.single.status, 'interrupted');
    expect(steps.single.completedAt, isNotNull);
    expect(steps.single.failedItems, 1);
  });

  test(
    'project enrichment reports duplicate registry links instead of failing',
    () async {
      final first = Directory(p.join(tempDir.path, 'duplicate_one'))
        ..createSync(recursive: true);
      final second = Directory(p.join(tempDir.path, 'duplicate_two'))
        ..createSync(recursive: true);
      await db.createProject(
        'duplicate-project',
        'Duplicate Project',
        DateTime(2026),
      );
      final now = DateTime(2026, 6, 29).millisecondsSinceEpoch;
      for (final entry in [
        ('registry_duplicate_1', 'Duplicate One', first.path),
        ('registry_duplicate_2', 'Duplicate Two', second.path),
      ]) {
        await db.customStatement(
          '''INSERT INTO project_registry (
               id, atlas_project_id, display_name, local_path, git_root,
               classification, review_state, notes, created_at, updated_at,
               last_reviewed_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            entry.$1,
            'duplicate-project',
            entry.$2,
            entry.$3,
            null,
            'software',
            'linked',
            null,
            now,
            now,
            now,
          ],
        );
      }

      final result = await state.runProjectEnrichment(
        refreshLinkedProjects: false,
        refreshSummaries: false,
      );
      final steps = await db.getProjectEnrichmentStepsForRun(result.run.id);
      final titles = result.findings.map((finding) => finding.title).toSet();

      expect(result.run.status, 'completed_with_findings');
      expect(
        titles,
        contains(
          'Multiple local registry entries are linked to the same Atlas project.',
        ),
      );
      expect(steps.where((step) => step.status == 'running'), isEmpty);
    },
  );

  test('project bundle export contains project refresh artifacts', () async {
    final root = _makeBohCandidate(tempDir);
    final runId = await state.runLocalOperationsScan(
      scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
    );
    final observation = (await db.getProjectObservationsForScanRun(
      runId,
    )).singleWhere((row) => row.observedPath == root.path);
    await state.acceptProjectObservation(observation.id);
    final registry = (await db.getProjectRegistry()).single;
    final projectId = await state.importProjectRegistryEntryAsProject(
      registry.id,
    );
    await state.applyLocalProjectRefresh(projectId);

    final preview = await state.previewProjectBundleExport(projectId);
    expect(preview.schema, 'project_atlas_project_bundle_v1');
    expect(preview.atlasRecordCount, greaterThan(1));
    expect(preview.documents, greaterThan(0));
    expect(preview.refreshItems, greaterThan(0));

    final zipPath = p.join(tempDir.path, 'boh_bundle.zip');
    await state.exportProjectBundleToZip(projectId, zipPath);

    final bytes = File(zipPath).readAsBytesSync();
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(2)), 'PK');
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.findFile('README.md'), isNotNull);
    expect(archive.findFile('manifest/export_manifest.json'), isNotNull);
  });

  test(
    'project bundle export can include summary and project log sections',
    () async {
      const projectId = 'bundle-options-project';
      await db.createProject(projectId, 'Bundle Options', DateTime.now());
      await state.saveDraft(
        kind: 'project_summary',
        title: 'Bundle Options Summary',
        body: 'Latest summary body.',
        inputJson: '{"source":"test"}',
        projectId: projectId,
      );
      await db.logEvent(
        area: 'project',
        action: 'bundle_option_changed',
        entityType: 'project',
        entityId: projectId,
        outputJson: jsonEncode({'changed': true}),
      );

      final preview = await state.previewProjectBundleExport(
        projectId,
        includeFiles: false,
        includeLatestSummary: true,
        includeEventLogs: true,
        eventLogSince: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(preview.latestSummaryDrafts, 1);
      expect(preview.eventLogs, 1);
      expect(preview.copiedFileCount, 0);

      final zipPath = p.join(tempDir.path, 'bundle_options.zip');
      await state.exportProjectBundleToZip(
        projectId,
        zipPath,
        includeFiles: false,
        includeLatestSummary: true,
        includeEventLogs: true,
        eventLogSince: DateTime.now().subtract(const Duration(days: 1)),
      );

      final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      expect(archive.findFile('README.md'), isNotNull);
      expect(archive.findFile('manifest/export_manifest.json'), isNotNull);
      expect(archive.findFile('summary/latest_project_summary.md'), isNotNull);
      expect(archive.findFile('logs/project_event_log.json'), isNotNull);
      final payload =
          jsonDecode(
                utf8.decode(
                  archive.findFile('project_bundle.json')!.content as List<int>,
                ),
              )
              as Map<String, Object?>;
      final options = payload['options'] as Map<String, Object?>;
      expect(options['includeLatestSummary'], isTrue);
      expect(options['includeEventLogs'], isTrue);
      expect((payload['projectEventLogs'] as List<Object?>), hasLength(1));
      final manifest =
          jsonDecode(
                utf8.decode(
                  archive.findFile('manifest/export_manifest.json')!.content
                      as List<int>,
                ),
              )
              as Map<String, Object?>;
      expect(manifest['schema'], 'project_atlas_project_bundle_manifest_v1');
      final manifestContents = manifest['contents'] as Map<String, Object?>;
      expect(manifestContents['summary'], 'summary/latest_project_summary.md');
      expect(manifestContents['eventLogs'], 'logs/project_event_log.json');
    },
  );

  test('project bundle export includes bootstrap context artifacts', () async {
    const projectId = 'bundle-bootstrap-project';
    await db.createProject(projectId, 'Bundle Bootstrap', DateTime.now());
    await state.enqueueLlmTask(
      projectId: projectId,
      title: 'Use exported bootstrap',
      objective: 'Verify bundle consumers can start from the packet.',
      priority: 'high',
    );
    await state.saveDraft(
      kind: 'atlas_agent_proposal',
      title: 'Review exported bootstrap',
      body: 'Pending agent proposal.',
      inputJson: jsonEncode({
        'schema': 'atlas.agent.proposal.v1',
        'proposalId': 'proposal-bundle-bootstrap',
        'type': 'closeout_record',
        'projectId': projectId,
        'payload': {'summary': 'Review me'},
        'validationErrors': <String>[],
        'warnings': <String>[],
        'createdAt': DateTime.now().toIso8601String(),
      }),
      projectId: projectId,
    );

    final preview = await state.previewProjectBundleExport(
      projectId,
      includeFiles: false,
      includeBootstrapContext: true,
    );
    expect(preview.includeBootstrapContext, isTrue);
    expect(preview.copiedFileCount, 0);

    final zipPath = p.join(tempDir.path, 'bundle_bootstrap.zip');
    await state.exportProjectBundleToZip(
      projectId,
      zipPath,
      includeFiles: false,
      includeBootstrapContext: true,
    );

    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    expect(
      archive.findFile('bootstrap/project_bootstrap_context.json'),
      isNotNull,
    );
    expect(
      archive.findFile('bootstrap/project_bootstrap_context.md'),
      isNotNull,
    );
    final context =
        jsonDecode(
              utf8.decode(
                archive
                        .findFile('bootstrap/project_bootstrap_context.json')!
                        .content
                    as List<int>,
              ),
            )
            as Map<String, Object?>;
    expect(context['schema'], 'atlas.project_bootstrap_context.v1');
    expect(
      (context['recommendedNextAction'] as String),
      contains('Use exported bootstrap'),
    );
    expect((context['pendingLlmTasks'] as List<Object?>), hasLength(1));
    expect((context['pendingAgentProposals'] as List<Object?>), hasLength(1));

    final payload =
        jsonDecode(
              utf8.decode(
                archive.findFile('project_bundle.json')!.content as List<int>,
              ),
            )
            as Map<String, Object?>;
    expect(payload['projectBootstrapContext'], isA<Map<String, Object?>>());
    final manifest =
        jsonDecode(
              utf8.decode(
                archive.findFile('manifest/export_manifest.json')!.content
                    as List<int>,
              ),
            )
            as Map<String, Object?>;
    final manifestContents = manifest['contents'] as Map<String, Object?>;
    expect(
      manifestContents['bootstrapContext'],
      'bootstrap/project_bootstrap_context.json',
    );
    expect(
      manifestContents['bootstrapContextMarkdown'],
      'bootstrap/project_bootstrap_context.md',
    );
  });

  test(
    'project bundle clean git export uses a clean linked child registry repo',
    () async {
      const projectId = 'bundle-local-git-project';
      await db.createProject(projectId, 'Bundle Local Git', DateTime.now());
      final outer = Directory(p.join(tempDir.path, 'outer_project'))
        ..createSync(recursive: true);
      final child = Directory(p.join(outer.path, 'public_repo'))
        ..createSync(recursive: true);
      await _initCleanGitRepo(child);
      final now = DateTime.now().millisecondsSinceEpoch;
      await _insertProjectRegistry(
        db,
        id: 'outer_registry',
        projectId: projectId,
        displayName: 'Outer Project',
        localPath: outer.path,
        gitRoot: null,
        updatedAtMillis: now + 1000,
      );
      await _insertProjectRegistry(
        db,
        id: 'child_registry',
        projectId: projectId,
        displayName: 'Public Repo',
        localPath: child.path,
        gitRoot: child.path,
        updatedAtMillis: now,
      );

      final preview = await state.previewProjectBundleExport(
        projectId,
        includeFiles: false,
        includeCleanGitArchive: true,
      );
      expect(preview.cleanGitArchiveReady, isTrue);

      final zipPath = p.join(tempDir.path, 'bundle_local_git.zip');
      await state.exportProjectBundleToZip(
        projectId,
        zipPath,
        includeFiles: false,
        includeCleanGitArchive: true,
      );

      final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      expect(archive.findFile('git/clean_HEAD.zip'), isNotNull);
      final payload =
          jsonDecode(
                utf8.decode(
                  archive.findFile('project_bundle.json')!.content as List<int>,
                ),
              )
              as Map<String, Object?>;
      final cleanGit = payload['cleanGitArchive'] as Map<String, Object?>;
      expect(cleanGit['source'], 'local');
      expect(cleanGit['registryId'], 'child_registry');
      expect(cleanGit['gitRoot'], _isSameExistingPathAs(child.path));
    },
  );

  test(
    'project bundle clean git export falls back to cached public GitHub archive',
    () async {
      const projectId = 'bundle-github-project';
      await db.createProject(projectId, 'Bundle GitHub', DateTime.now());
      final outer = Directory(p.join(tempDir.path, 'outer_project'))
        ..createSync(recursive: true);
      await _insertProjectRegistry(
        db,
        id: 'outer_registry',
        projectId: projectId,
        displayName: 'Outer Project',
        localPath: outer.path,
        gitRoot: null,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await db.upsertProjectGitRemoteStatus(
        projectId: projectId,
        registryId: 'outer_registry',
        provider: 'github',
        owner: 'ppeck1',
        repo: 'dev-launchpad',
        remoteUrl: 'https://github.com/ppeck1/dev-launchpad.git',
        htmlUrl: 'https://github.com/ppeck1/dev-launchpad',
        visibility: 'public',
        defaultBranch: 'main',
        onlineHeadSha: 'abc123',
        isPrivate: false,
        isFork: false,
        isArchived: false,
        checkedAt: DateTime.now(),
      );
      state.dispose();
      state = AppState(
        db,
        enableBackgroundSummaryRefresh: false,
        githubArchiveFetcher: (identity, ref) async {
          expect(identity.fullName, 'ppeck1/dev-launchpad');
          expect(ref, 'abc123');
          return [80, 75, 3, 4, 0, 0];
        },
      );

      final preview = await state.previewProjectBundleExport(
        projectId,
        includeFiles: false,
        includeCleanGitArchive: true,
      );
      expect(preview.cleanGitArchiveReady, isTrue);
      expect(preview.warnings, isEmpty);

      final zipPath = p.join(tempDir.path, 'bundle_github.zip');
      await state.exportProjectBundleToZip(
        projectId,
        zipPath,
        includeFiles: false,
        includeCleanGitArchive: true,
      );

      final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      expect(
        archive.findFile('git/github_ppeck1_dev-launchpad_abc123.zip'),
        isNotNull,
      );
      final payload =
          jsonDecode(
                utf8.decode(
                  archive.findFile('project_bundle.json')!.content as List<int>,
                ),
              )
              as Map<String, Object?>;
      final cleanGit = payload['cleanGitArchive'] as Map<String, Object?>;
      expect(cleanGit['source'], 'github');
      expect(cleanGit['owner'], 'ppeck1');
      expect(cleanGit['repo'], 'dev-launchpad');
      expect(cleanGit['ref'], 'abc123');
    },
  );
}

void _makeCandidate(Directory tempDir, String name) {
  final dir = Directory(p.join(tempDir.path, name))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'README.md')).writeAsStringSync('# $name');
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: $name');
}

Directory _makeSourceCandidate(
  Directory tempDir,
  String name,
  String sourceFileName,
) {
  final dir = Directory(p.join(tempDir.path, name))
    ..createSync(recursive: true);
  final libDir = Directory(p.join(dir.path, 'lib'))..createSync();
  File(p.join(dir.path, 'README.md')).writeAsStringSync('# $name');
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: $name');
  File(
    p.join(libDir.path, sourceFileName),
  ).writeAsStringSync('void main() {}\n');
  return dir;
}

Directory _makeBohCandidate(Directory tempDir) {
  final dir = Directory(p.join(tempDir.path, 'Bag.of.holding'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'README.md')).writeAsStringSync('# Bag of Holding');
  File(p.join(dir.path, 'ACTIVE_TASK.md')).writeAsStringSync('''
# ACTIVE_TASK.md

## IDLE - no active work order

Last completed: `boh_fold_domain_cluster_visuals_v0_1` on 2026-06-23.
''');
  File(p.join(dir.path, 'CURRENT_STATE.md')).writeAsStringSync('''
# CURRENT_STATE.md

## Project Purpose

Bag of Holding is a local-first knowledge workbench for governed document storage.

Open operational item: `boh_runtime_launch_origin_audit_v0_1`.
''');
  File(p.join(dir.path, 'DECISIONS.md')).writeAsStringSync('''
# DECISIONS.md

## DEC-0001 - Use Governed Patch Execution

Decision: Future coding-agent work must follow governed patch execution.

Reason: Bounded authority reduces drift.

Consequence: Agents must keep patches small.
''');
  File(p.join(dir.path, 'ROADMAP.md')).writeAsStringSync('''
# ROADMAP.md

## Next

1. First next step.

## Proposed next work orders - drafted, NOT authorized

- **WO-3** proposed importer.
''');
  File(p.join(dir.path, 'ACCEPTANCE.md')).writeAsStringSync('''
# ACCEPTANCE.md

## Documentation Truthfulness

Docs must distinguish implemented and future work.
''');
  File(
    p.join(dir.path, 'CHANGELOG_AGENT.md'),
  ).writeAsStringSync('# CHANGELOG_AGENT.md\n');
  Directory(p.join(dir.path, 'assets')).createSync();
  File(p.join(dir.path, 'assets', 'cover.png')).writeAsBytesSync([0, 1, 2, 3]);
  return dir;
}

Directory _makeHtml2mdCandidate(Directory tempDir) {
  final dir = Directory(p.join(tempDir.path, 'html2md'))
    ..createSync(recursive: true);
  Directory(p.join(dir.path, '.project')).createSync();
  Directory(p.join(dir.path, 'docs')).createSync();
  Directory(p.join(dir.path, 'release')).createSync();
  Directory(p.join(dir.path, 'archive')).createSync();
  Directory(p.join(dir.path, 'codex_reanimator')).createSync();
  Directory(p.join(dir.path, 'tests', 'fixtures')).createSync(recursive: true);

  File(p.join(dir.path, '.project', 'launchpad.json')).writeAsStringSync(
    jsonEncode({
      'name': 'HTML2MD Reanimator',
      'type': 'desktop',
      'group': 'Local AI Stack',
      'tags': ['python', 'tkinter', 'html', 'markdown'],
      'commands': {
        'start': 'python -m codex_reanimator',
        'build': 'python -m PyInstaller --clean CodexReanimator.spec',
        'test': 'pytest',
      },
      'docs': {
        'CURRENT_STATE': 'docs/CURRENT_STATE.md',
        'HANDOFF': 'docs/HANDOFF.md',
        'VARIABLE_MATRIX': 'docs/VARIABLE_MATRIX.md',
        'OPERATIONS': 'docs/OPERATIONS.md',
      },
      'notes':
          'Windows-first HTML-to-Markdown recovery workstation with GUI and CLI.',
      'validation': {'launch': 'NOT-CHECKED', 'build': 'NOT-CHECKED'},
    }),
  );
  File(p.join(dir.path, 'README.md')).writeAsStringSync('''
# CODEX REANIMATOR

CODEX REANIMATOR is a Windows-first HTML-to-Markdown recovery workstation. It converts messy HTML artifacts into reviewable Markdown while preserving provenance.

## Repository Layout

```text
codex_reanimator/   application source
docs/               screenshots and design notes
release/            latest packaged executable
archive/            legacy builds
tests/              fixtures and future tests
```
''');
  File(p.join(dir.path, 'pyproject.toml')).writeAsStringSync('''
[project]
name = "codex-reanimator"
''');
  File(p.join(dir.path, 'docs', 'CURRENT_STATE.md')).writeAsStringSync('''
# Current State

Project: HTML2MD Reanimator

Status: Metadata scaffolded for Dev Launchpad.

## What This Project Is

Windows-first HTML-to-Markdown recovery workstation with GUI and CLI.

## Existing References

- `README.md`
- `pyproject.toml`
- `requirements.txt`

## Maintenance Rule

Project documentation and operating decisions stay in this project folder.
''');
  File(p.join(dir.path, 'docs', 'HANDOFF.md')).writeAsStringSync('''
# Handoff

## Operator Summary

Seeded from .project/launchpad.json.

## Next Verification

1. Run the manifest test command if present.
2. Run the manifest build command if present.
- Launch the project from Dev Launchpad.
- Run health checks when URLs are declared.

## Boundary

Dev Launchpad owns execution/status display only.
''');
  File(
    p.join(dir.path, 'docs', 'VARIABLE_MATRIX.md'),
  ).writeAsStringSync('# Variable Matrix\n');
  File(
    p.join(dir.path, 'docs', 'OPERATIONS.md'),
  ).writeAsStringSync('# Operations\n');
  File(
    p.join(dir.path, 'codex_reanimator', 'app.py'),
  ).writeAsStringSync('def main():\n    return "ok"\n');
  File(
    p.join(dir.path, 'tests', 'fixtures', 'simple.html'),
  ).writeAsStringSync('<html><body>fixture</body></html>');
  File(
    p.join(dir.path, 'release', 'CodexReanimator.exe'),
  ).writeAsBytesSync(List.filled(128, 0));
  File(
    p.join(dir.path, 'archive', 'html2md.v1.rar'),
  ).writeAsBytesSync(List.filled(64, 1));
  return dir;
}

Future<void> _insertProjectRegistry(
  AppDb db, {
  required String id,
  required String projectId,
  required String displayName,
  required String localPath,
  required String? gitRoot,
  required int updatedAtMillis,
}) async {
  await db.customStatement(
    '''INSERT INTO project_registry (
       id, atlas_project_id, display_name, local_path, git_root,
       classification, review_state, notes, created_at, updated_at,
       last_reviewed_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      id,
      projectId,
      displayName,
      localPath,
      gitRoot,
      'software',
      'linked',
      null,
      updatedAtMillis,
      updatedAtMillis,
      updatedAtMillis,
    ],
  );
}

Future<void> _initCleanGitRepo(Directory dir) async {
  File(p.join(dir.path, 'README.md')).writeAsStringSync('# Clean Repo\n');
  await _runGit(dir, ['init']);
  await _runGit(dir, ['config', 'user.email', 'atlas@example.test']);
  await _runGit(dir, ['config', 'user.name', 'Project Atlas']);
  await _runGit(dir, ['add', 'README.md']);
  await _runGit(dir, ['commit', '-m', 'Initial commit']);
}

Future<void> _runGit(Directory dir, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: dir.path,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(
    result.exitCode,
    0,
    reason:
        'git ${args.join(' ')} failed\nstdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
}

Matcher _isSameExistingPathAs(String expectedPath) {
  return predicate<Object?>((actual) {
    if (actual is! String) {
      return false;
    }
    try {
      if (FileSystemEntity.identicalSync(actual, expectedPath)) {
        return true;
      }
    } on FileSystemException {
      // Fall back to normalized text comparison if the path cannot be resolved.
    }
    return _canonicalPathForComparison(actual) ==
        _canonicalPathForComparison(expectedPath);
  }, 'path equivalent to $expectedPath');
}

String _canonicalPathForComparison(String path) {
  String canonical;
  try {
    canonical = Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    canonical = p.normalize(p.absolute(path));
  }
  return Platform.isWindows
      ? canonical.replaceAll('/', r'\').toLowerCase()
      : canonical;
}

Future<ProjectObservation> _scanOne(
  AppState state,
  AppDb db,
  Directory tempDir,
) async {
  final runId = await state.runLocalOperationsScan(
    scanner: LocalOperationsScanner(roots: [tempDir.path], maxDepth: 2),
  );
  final observations = await db.getProjectObservationsForScanRun(runId);
  expect(observations, hasLength(1));
  return observations.single;
}

Future<String> _createWarningRun(AppDb db, Directory tempDir) async {
  final startedAt = DateTime(2026, 6, 27, 12);
  final runId = await db.startProjectScanRun(
    rootsJson: jsonEncode([tempDir.path]),
    startedAt: startedAt,
  );
  await db.addProjectObservation(
    id: 'obs_warning_$runId',
    scanRunId: runId,
    observedPath: p.join(tempDir.path, 'warned_project'),
    classificationGuess: 'needs_review',
    confidence: 55,
    markerFilesJson: jsonEncode(['README.md']),
    warningsJson: jsonEncode(['git remote get-url origin failed']),
    rawJson: jsonEncode({'displayName': 'warned_project'}),
    observedAt: startedAt,
  );
  await db.finishProjectScanRun(
    id: runId,
    completedAt: startedAt.add(const Duration(seconds: 1)),
    status: 'completed',
    totalSeen: 1,
    candidates: 1,
    ignored: 0,
    warningsJson: jsonEncode(['run warning']),
  );
  return runId;
}
