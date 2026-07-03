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
        expect((await db.getGeneralTasksProject())?.id, 'legacy-general-tasks');
      },
    );

    test('general task has no visible project association', () async {
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(state.dispose);

      final workItemId = await state.addGeneralWorkItem('General follow-up');
      final project = await state.getProjectForWorkItem(workItemId);
      final activeItems = await db.getAllActiveWorkItems();
      final projects = await db.getProjectsFull();
      final generalProject = await db.getGeneralTasksProject();

      expect(project, isNull);
      expect(activeItems.map((item) => item.id), contains(workItemId));
      expect(projects, isEmpty);
      expect(generalProject, isNotNull);
      expect(
        generalProject!.description,
        AppDb.kGeneralTasksProjectDescription,
      );
    });

    test(
      'manual project creation activates and returns the new project',
      () async {
        await db.createProject('old-project', 'Old Project', DateTime(2026));
        await db.setActiveProjectId('old-project');
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        final newProjectId = await state.createProject('New Project');
        final saved = await db.getProjectFull(newProjectId!);

        expect(saved?.title, 'New Project');
        expect(await db.getMetaString(AppDb.kActiveProjectId), newProjectId);
      },
    );

    test(
      'contact continuity seeds actors and assigns owner to visible projects',
      () async {
        await db.createProject('alpha', 'Alpha', DateTime(2026, 1, 1));
        await db.createProject('beta', 'Beta', DateTime(2026, 1, 2));
        await db.createProject(
          'legacy-general-tasks',
          'General Tasks',
          DateTime(2026, 1, 3),
        );
        await db.updateProjectMeta('legacy-general-tasks', {
          'description': AppDb.kGeneralTasksProjectDescription,
        });
        await db.saveContact(
          id: 'duplicate-paul-1',
          name: 'Paul Peck',
          notes: 'Existing duplicate A',
        );
        await db.saveContact(
          id: 'duplicate-paul-2',
          name: 'Paul Peck',
          notes: 'Existing duplicate B',
        );
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);
        await state.saveProjectAiSummarySettings(
          const ProjectAiSummarySettings(model: 'mistral-small3.2:24b'),
        );

        final result = await state.ensureContactContinuity();

        final alpha = await db.getProjectFull('alpha');
        final beta = await db.getProjectFull('beta');
        final hidden = await db.getProjectFull('legacy-general-tasks');
        final alphaPeople = await db.getProjectPeople('alpha');
        final betaPeople = await db.getProjectPeople('beta');
        final contacts = await db.getContacts();
        final events = await db.getRecentEvents();

        expect(result.projectsConsidered, 2);
        expect(result.projectOwnersUpdated, 2);
        expect(result.projectPeopleAdded, 2);
        expect(result.duplicateContactsRemoved, 1);
        expect(alpha!.owner, 'Paul Peck');
        expect(beta!.owner, 'Paul Peck');
        expect(hidden!.owner, isNull);
        expect(
          alphaPeople.map((person) => '${person.name}:${person.role}'),
          contains('Paul Peck:Owner'),
        );
        expect(
          betaPeople.map((person) => '${person.name}:${person.authority}'),
          contains('Paul Peck:Accountable'),
        );
        expect(contacts.map((contact) => contact.name), contains('Paul Peck'));
        expect(
          contacts.where((contact) => contact.name == 'Paul Peck'),
          hasLength(1),
        );
        expect(contacts.map((contact) => contact.name), contains('Atlas'));
        expect(
          contacts.map((contact) => contact.name),
          contains('Atlas Agent'),
        );
        expect(contacts.map((contact) => contact.name), contains('Codex'));
        expect(
          contacts.map((contact) => contact.name),
          contains('Model: mistral-small3.2:24b'),
        );
        expect(
          events.map((event) => event.action),
          contains('contact_continuity_seeded'),
        );

        final rerun = await state.ensureContactContinuity();
        expect(rerun.projectOwnersUpdated, 0);
        expect(rerun.projectPeopleAdded, 0);
      },
    );

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
          title: 'lib/main.dart',
          originalFilename: 'lib/main.dart',
          body: 'void main() {}',
          projectId: 'summary-proj',
          extension: 'dart',
        );
        await db.importGeneratedDocument(
          title: 'README.md',
          originalFilename: 'README.md',
          body: List.filled(500, 'README evidence').join(' '),
          projectId: 'summary-proj',
          extension: 'md',
        );
        await db.importGeneratedDocument(
          title: 'HANDOFF.md',
          originalFilename: 'HANDOFF.md',
          body: 'Handoff evidence.',
          projectId: 'summary-proj',
          extension: 'md',
        );
        await db.importGeneratedDocument(
          title: 'CURRENT_STATE.md',
          originalFilename: 'CURRENT_STATE.md',
          body: 'Current state evidence.',
          projectId: 'summary-proj',
          extension: 'md',
        );
        await db.importGeneratedDocument(
          title: 'ACTIVE_TASK.md',
          originalFilename: 'ACTIVE_TASK.md',
          body: 'Active task evidence.',
          projectId: 'summary-proj',
          extension: 'md',
        );

        final packet = await state.buildProjectSummaryEvidencePacket(
          'summary-proj',
          includeLibrary: true,
        );
        expect(packet.suppliedDocumentCount, 6);
        expect(packet.includedDocumentCount, 6);
        expect(
          packet.documents.take(4).map((doc) => doc.evidenceCategory).toList(),
          ['active_task', 'current_state', 'handoff', 'readme'],
        );
        expect(packet.documents.first.title, 'ACTIVE_TASK.md');
        expect(packet.documents.first.selectionReason, 'active task');
        expect(packet.documents.first.excerptChars, lessThanOrEqualTo(3000));
        expect(packet.totalExcerptChars, lessThanOrEqualTo(16000));
        expect(packet.categoryCounts['source'], 1);

        final logJson = packet.toLogJson(model: 'mistral', trigger: 'test');
        expect(logJson['categoryCounts'], containsPair('readme', 1));

        final evalJson = packet.toEvaluationJson(label: 'ranking-fixture');
        expect(evalJson['schema'], 'project_summary_evidence_evaluation_v1');
        expect(evalJson['label'], 'ranking-fixture');
        final evalDocs = evalJson['documents']! as List<Object?>;
        expect(evalDocs.first, containsPair('evidenceCategory', 'active_task'));

        final gated = await state.buildProjectSummaryEvidencePacket(
          'summary-proj',
          includeLibrary: false,
        );
        expect(gated.suppliedDocumentCount, 6);
        expect(gated.includedDocumentCount, 0);
        expect(gated.warnings.single, contains('Library evidence disabled'));
      },
    );

    test(
      'project summary evidence packet warns on weak source packets',
      () async {
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        addTearDown(state.dispose);

        await db.createProject(
          'summary-warnings',
          'Summary Warnings',
          DateTime(2026, 1, 1),
        );
        await db.importGeneratedDocument(
          title: 'manual.pdf',
          originalFilename: 'manual.pdf',
          body: '',
          projectId: 'summary-warnings',
          extension: 'pdf',
        );

        final unreadablePacket = await state.buildProjectSummaryEvidencePacket(
          'summary-warnings',
          includeLibrary: true,
        );
        expect(unreadablePacket.documents.single.hasExcerpt, isFalse);
        expect(
          unreadablePacket.warnings,
          contains(
            'No readable excerpts available from linked Library documents.',
          ),
        );

        await db.createProject(
          'summary-caps',
          'Summary Caps',
          DateTime(2026, 1, 1),
        );
        for (var index = 0; index < 7; index++) {
          await db.importGeneratedDocument(
            title: 'notes-$index.md',
            originalFilename: 'notes-$index.md',
            body: List.filled(500, 'long evidence').join(' '),
            projectId: 'summary-caps',
            extension: 'md',
          );
        }

        final cappedPacket = await state.buildProjectSummaryEvidencePacket(
          'summary-caps',
          includeLibrary: true,
        );
        expect(cappedPacket.totalExcerptChars, 16000);
        expect(cappedPacket.excerptedDocumentCount, 6);
        expect(
          cappedPacket.warnings,
          contains(contains('truncated at 3000 chars')),
        );
        expect(
          cappedPacket.warnings,
          contains(contains('Excerpt budget reached at 16000 chars')),
        );
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
