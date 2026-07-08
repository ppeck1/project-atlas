import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/workload_planning_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('workload planning', () {
    late AppDb db;
    late AppState state;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test('work item and LLM queue planning metadata default safely', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final stage = (await db.getStagesForProject('atlas')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Default planning task',
      );
      final queueId = await db.enqueueLlmTask(
        projectId: 'atlas',
        title: 'Default queue task',
        objective: 'Check defaults.',
        contextJson: '{}',
      );

      final item = await db.getWorkItem(workItemId);
      final task = await db.getLlmTask(queueId);

      expect(item!.readiness, 'ready');
      expect(item.size, 'medium');
      expect(item.risk, 'low_code');
      expect(item.suggestedActor, 'user');
      expect(item.verificationNeeded, 'none');
      expect(item.nextAction, isNull);
      expect(item.planningNotes, isNull);
      expect(item.lastReviewedAt, isNull);

      expect(task!.readiness, 'ready');
      expect(task.size, 'medium');
      expect(task.risk, 'low_code');
      expect(task.suggestedActor, 'user');
      expect(task.verificationNeeded, 'none');
      expect(task.nextAction, isNull);
      expect(task.blockerReason, isNull);
      expect(task.planningNotes, isNull);
      expect(task.lastReviewedAt, isNull);
    });

    test('filters and scores ready-only deterministic next work', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final stage = (await db.getStagesForProject('atlas')).single;
      final readyId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Ship docs patch',
        priority: 'high',
      );
      await db.updateWorkItem(
        id: readyId,
        readiness: 'ready',
        size: 'tiny',
        risk: 'docs_only',
        suggestedActor: 'codex',
        verificationNeeded: 'tests',
        nextAction: 'Run focused workload tests.',
      );
      final blockedId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Blocked schema change',
        priority: 'urgent',
        blockedReason: 'Needs owner decision.',
      );
      await db.updateWorkItem(
        id: blockedId,
        readiness: 'blocked',
        size: 'tiny',
        risk: 'db_schema',
        suggestedActor: 'user',
      );
      final decisionId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Pick release owner',
        priority: 'urgent',
      );
      await db.updateWorkItem(
        id: decisionId,
        readiness: 'needs_decision',
        size: 'tiny',
        risk: 'docs_only',
        suggestedActor: 'user',
      );
      final reviewId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Review generated handoff',
        priority: 'normal',
      );
      await db.updateWorkItem(id: reviewId, readiness: 'review_needed');
      final queueId = await db.enqueueLlmTask(
        projectId: 'atlas',
        workItemId: readyId,
        title: 'Queue context draft',
        objective: 'Prepare review notes.',
        contextJson: '{}',
        readiness: 'needs_context',
        size: 'small',
        risk: 'medium_code',
        suggestedActor: 'local_llm',
      );

      final now = DateTime(2026, 7, 4);
      final snapshot = await state.getWorkloadSnapshot(now: now);
      final codexOnly = await state.getWorkloadSnapshot(
        filters: const WorkloadFilters(actor: 'codex'),
        now: now,
      );
      final blockedOnly = await state.getWorkloadSnapshot(
        filters: const WorkloadFilters(blockedOnly: true),
        now: now,
      );

      expect(snapshot.readyTasks, 1);
      expect(snapshot.blockedTasks, 1);
      expect(snapshot.reviewNeededTasks, 1);
      expect(snapshot.staleTasks, 5);
      expect(codexOnly.cards.map((card) => card.id), [readyId]);
      expect(blockedOnly.cards.map((card) => card.id), [blockedId]);
      expect(snapshot.suggestedNextItems.first.id, readyId);
      expect(snapshot.suggestedNextItems.map((card) => card.id), [readyId]);
      expect(
        snapshot.planningCandidateItems.map((card) => card.id),
        containsAll([decisionId, queueId]),
      );
      final json = snapshot.toJson();
      expect(
        ((json['executionCandidates'] as List).first as Map)['id'],
        readyId,
      );
      expect(
        (json['planningCandidateItems'] as List).map(
          (item) => (item as Map)['id'],
        ),
        containsAll([decisionId, queueId]),
      );
      expect(
        snapshot.suggestedNextItems.map((card) => card.id),
        isNot(contains(reviewId)),
      );
      expect(
        snapshot.suggestedNextItems.map((card) => card.id),
        isNot(contains(blockedId)),
      );
      expect(
        snapshot.suggestedNextItems.map((card) => card.id),
        isNot(contains(decisionId)),
      );
    });

    test(
      'classifies stale reasons and demotes imported checklist rows globally',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        final stage = (await db.getStagesForProject('atlas')).single;
        final importedId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Run manifest test command',
          source: 'Dev Launchpad imported checklist',
        );
        final importedRefreshId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Run the manifest test command if present.',
          source: 'local_refresh',
        );
        final manualId = await db.addWorkItem(
          stageId: stage.id,
          title: 'Operator selected work',
          priority: 'high',
        );

        final global = await state.getWorkloadSnapshot(
          now: DateTime(2026, 7, 8),
        );
        final project = await state.getWorkloadSnapshot(
          filters: const WorkloadFilters(projectId: 'atlas'),
          now: DateTime(2026, 7, 8),
        );

        final imported = global.cards.singleWhere(
          (card) => card.id == importedId,
        );
        final importedRefresh = global.cards.singleWhere(
          (card) => card.id == importedRefreshId,
        );
        final manual = global.cards.singleWhere((card) => card.id == manualId);
        expect(imported.originKind, 'imported_checklist');
        expect(importedRefresh.originKind, 'imported_checklist');
        expect(imported.showInMainWorkboard, isFalse);
        expect(importedRefresh.showInMainWorkboard, isFalse);
        expect(
          imported.staleReasons(DateTime(2026, 7, 8)),
          contains('imported_template_unreviewed'),
        );
        expect(
          importedRefresh.staleReasons(DateTime(2026, 7, 8)),
          contains('imported_template_unreviewed'),
        );
        expect(manual.originKind, 'manual');
        expect(global.suggestedNextItems.map((card) => card.id), [manualId]);
        expect(
          project.suggestedNextItems.map((card) => card.id),
          contains(importedId),
        );
        expect(
          (global.toJson()['counts'] as Map)['demotedImportedChecklist'],
          2,
        );
        expect(
          ((global.toJson()['counts'] as Map)['byOrigin']
              as Map)['imported_checklist'],
          2,
        );
      },
    );

    test('bulk planning updates and creates linked queue items', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final stage = (await db.getStagesForProject('atlas')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Implement board filter',
        priority: 'high',
      );

      await state.updateWorkloadPlanning(
        items: [
          WorkloadItemRef(kind: WorkloadCard.workItemKind, id: workItemId),
        ],
        readiness: 'needs_decision',
        size: 'small',
        risk: 'medium_code',
        suggestedActor: 'claude',
        verificationNeeded: 'smoke',
        nextAction: 'Decide UI copy.',
        planningNotes: 'Keep proposal-first.',
        lastReviewedAt: DateTime(2026, 7, 4),
      );
      final queueId = await state.createLlmTaskFromWorkItem(workItemId);

      final item = await db.getWorkItem(workItemId);
      final task = await db.getLlmTask(queueId);

      expect(item!.readiness, 'needs_decision');
      expect(item.size, 'small');
      expect(item.risk, 'medium_code');
      expect(item.suggestedActor, 'claude');
      expect(item.verificationNeeded, 'smoke');
      expect(item.nextAction, 'Decide UI copy.');
      expect(item.planningNotes, 'Keep proposal-first.');
      expect(item.lastReviewedAt, DateTime(2026, 7, 4));
      expect(task!.workItemId, workItemId);
      expect(task.readiness, 'needs_decision');
      expect(task.size, 'small');
      expect(task.risk, 'medium_code');
      expect(task.suggestedActor, 'claude');
      expect(task.verificationNeeded, 'smoke');
    });
  });
}
