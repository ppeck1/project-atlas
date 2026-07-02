import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('smoke tests', () {
    late AppDb db;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'AppState basic initialization: watchProjects emits created project',
      () async {
        await db.createProject('proj-1', 'My Project', DateTime(2026, 1, 1));

        final projects = await db.watchProjects().first;
        expect(projects, isNotEmpty);
        expect(projects.any((p) => p.id == 'proj-1'), isTrue);
        expect(
          projects.firstWhere((p) => p.id == 'proj-1').title,
          'My Project',
        );
      },
    );

    test(
      'project listings are alphabetical and hide general tasks project',
      () async {
        await db.createProject('bravo', 'Bravo', DateTime(2026, 1, 1));
        await db.createProject('alpha', 'Alpha', DateTime(2026, 1, 2));
        await db.createProject('charlie', 'Charlie', DateTime(2026, 1, 3));
        await db.createProject(
          'legacy-general-tasks',
          'General Tasks',
          DateTime(2026, 1, 4),
        );
        await db.updateProjectMeta('legacy-general-tasks', {
          'description': AppDb.kGeneralTasksProjectDescription,
        });
        await db.ensureGeneralTaskStage();

        final watched = await db.watchProjects().first;
        final full = await db.getProjectsFull();

        expect(watched.map((project) => project.title), [
          'Alpha',
          'Bravo',
          'Charlie',
        ]);
        expect(full.map((project) => project.title), [
          'Alpha',
          'Bravo',
          'Charlie',
        ]);
        expect(
          watched.map((project) => project.id),
          isNot(contains(AppDb.kGeneralTasksProjectId)),
        );
        expect(
          watched.map((project) => project.id),
          isNot(contains('legacy-general-tasks')),
        );
      },
    );

    test('general task has no visible project association', () async {
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(state.dispose);

      final workItemId = await state.addGeneralWorkItem('General follow-up');
      final project = await state.getProjectForWorkItem(workItemId);
      final activeItems = await db.getAllActiveWorkItems();
      final projects = await db.getProjectsFull();

      expect(project, isNull);
      expect(activeItems.map((item) => item.id), contains(workItemId));
      expect(projects, isEmpty);
    });

    test(
      'project AI summary settings persist and update cached gates',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        expect(state.projectAiSummariesEnabled, isFalse);
        expect(state.projectAiSummaryIncludeLibrary, isTrue);
        expect(state.projectAiSummaryAllowBulkRefresh, isFalse);

        await state.saveProjectAiSummarySettings(
          const ProjectAiSummarySettings(
            enabled: true,
            includeLibrary: true,
            allowBulkRefresh: true,
            model: 'mistral-small3.2:24b',
          ),
        );

        expect(state.projectAiSummariesEnabled, isTrue);
        expect(state.projectAiSummaryIncludeLibrary, isTrue);
        expect(state.projectAiSummaryAllowBulkRefresh, isTrue);
        expect(state.projectAiSummaryModel, 'mistral-small3.2:24b');

        final loaded = await state.loadProjectAiSummarySettings();
        expect(loaded.enabled, isTrue);
        expect(loaded.includeLibrary, isTrue);
        expect(loaded.allowBulkRefresh, isTrue);
        expect(loaded.model, 'mistral-small3.2:24b');
      },
    );

    test(
      'project summary evidence packet ranks and gates Library docs',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        await db.createProject(
          'summary-proj',
          'Summary Project',
          DateTime(2026, 1, 1),
        );
        await db.importGeneratedDocument(
          title: 'notes.txt',
          originalFilename: 'notes.txt',
          body: 'Loose notes.',
          projectId: 'summary-proj',
          extension: 'txt',
        );
        await db.importGeneratedDocument(
          title: 'README.md',
          originalFilename: 'README.md',
          body: List.filled(500, 'README evidence').join(' '),
          projectId: 'summary-proj',
          extension: 'md',
        );

        final packet = await state.buildProjectSummaryEvidencePacket(
          'summary-proj',
          includeLibrary: true,
        );
        expect(packet.suppliedDocumentCount, 2);
        expect(packet.includedDocumentCount, 2);
        expect(packet.documents.first.title, 'README.md');
        expect(packet.documents.first.selectionReason, 'project readme');
        expect(packet.documents.first.excerptChars, lessThanOrEqualTo(3000));
        expect(packet.totalExcerptChars, lessThanOrEqualTo(16000));

        final gated = await state.buildProjectSummaryEvidencePacket(
          'summary-proj',
          includeLibrary: false,
        );
        expect(gated.suppliedDocumentCount, 2);
        expect(gated.includedDocumentCount, 0);
        expect(gated.warnings.single, contains('Library evidence disabled'));
      },
    );

    test('event log persists correlation id', () async {
      await db.logEvent(
        area: 'ai',
        action: 'project_summary_started',
        correlationId: 'summary-run-1',
      );

      final events = await db.getRecentEvents();
      expect(events.first.correlationId, 'summary-run-1');
    });

    test('Today items stream: work item with status doing appears', () async {
      await db.createProject('proj-2', 'Today Project', DateTime(2026, 1, 1));

      // createProject auto-creates a default stage; get it
      final stages = await db.getStagesForProject('proj-2');
      expect(stages, isNotEmpty);
      final stageId = stages.first.id;

      await db.addWorkItem(
        stageId: stageId,
        title: 'Urgent Task',
        status: 'doing',
      );

      final todayItems = await db.watchTodayItems().first;
      expect(todayItems, isNotEmpty);
      expect(todayItems.any((w) => w.title == 'Urgent Task'), isTrue);
    });

    test('DailyReviews round-trip: save, retrieve, and upsert', () async {
      await db.saveDailyReview('Test summary');

      final review = await db.getDailyReviewForDate(DateTime.now());
      expect(review, isNotNull);
      expect(review!.summary, 'Test summary');

      // Save again for the same day — should overwrite (upsert)
      await db.saveDailyReview('Updated summary');

      final updated = await db.getDailyReviewForDate(DateTime.now());
      expect(updated, isNotNull);
      expect(updated!.summary, 'Updated summary');
    });

    test('Stage CRUD: add, rename, and delete', () async {
      await db.createProject('proj-3', 'Stage Project', DateTime(2026, 1, 1));

      await db.addStage('proj-3', 'My Stage');

      // Verify the new stage appears (there is also the auto-created default stage)
      final stagesAfterAdd = await db.watchStagesForProject('proj-3').first;
      final myStage = stagesAfterAdd.firstWhere(
        (s) => s.title == 'My Stage',
        orElse: () => throw StateError('My Stage not found'),
      );
      expect(myStage.title, 'My Stage');

      // Rename
      await db.updateStageTitle(myStage.id, 'Renamed Stage');
      final stagesAfterRename = await db.watchStagesForProject('proj-3').first;
      expect(stagesAfterRename.any((s) => s.title == 'Renamed Stage'), isTrue);
      expect(stagesAfterRename.any((s) => s.title == 'My Stage'), isFalse);

      // Delete
      await db.deleteStage(myStage.id);
      final stagesAfterDelete = await db.watchStagesForProject('proj-3').first;
      expect(stagesAfterDelete.any((s) => s.id == myStage.id), isFalse);
    });
  });
}
