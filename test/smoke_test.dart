import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';

void main() {
  group('smoke tests', () {
    late AppDb db;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('AppState basic initialization: watchProjects emits created project',
        () async {
      await db.createProject('proj-1', 'My Project', DateTime(2026, 1, 1));

      final projects = await db.watchProjects().first;
      expect(projects, isNotEmpty);
      expect(projects.any((p) => p.id == 'proj-1'), isTrue);
      expect(projects.firstWhere((p) => p.id == 'proj-1').title, 'My Project');
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
      final stagesAfterRename =
          await db.watchStagesForProject('proj-3').first;
      expect(
        stagesAfterRename.any((s) => s.title == 'Renamed Stage'),
        isTrue,
      );
      expect(stagesAfterRename.any((s) => s.title == 'My Stage'), isFalse);

      // Delete
      await db.deleteStage(myStage.id);
      final stagesAfterDelete =
          await db.watchStagesForProject('proj-3').first;
      expect(
        stagesAfterDelete.any((s) => s.id == myStage.id),
        isFalse,
      );
    });
  });
}
