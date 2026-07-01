import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('AtlasAgentService', () {
    late AppDb db;
    late AppState state;
    late AtlasAgentService service;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      service = AtlasAgentService(state);
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test(
      'lists visible projects alphabetically with attention status',
      () async {
        await db.createProject('bravo', 'Bravo', DateTime(2026, 1, 1));
        await db.createProject('alpha', 'Alpha', DateTime(2026, 1, 1));
        await db.createProject('charlie', 'Charlie', DateTime(2026, 1, 1));
        await db.updateProjectMeta('bravo', {'status': 'stale'});
        await db.updateProjectMeta('charlie', {'status': 'archived'});
        await db.ensureGeneralTaskStage();

        final rows = await service.listProjects();
        final attention = await service.getStaleProjects();

        expect(rows.map((project) => project.title), [
          'Alpha',
          'Bravo',
          'Charlie',
        ]);
        expect(
          rows.map((project) => project.id),
          isNot(contains(AppDb.kGeneralTasksProjectId)),
        );
        expect(rows.map((project) => project.id), contains('charlie'));
        expect(attention.map((project) => project.id), contains('bravo'));
        expect(
          attention.map((project) => project.id),
          isNot(contains('alpha')),
        );
      },
    );

    test('builds a project brief for harness and MCP reads', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      await db.updateProjectMeta('atlas', {
        'description': 'Operational dashboard',
        'status': 'needs_update',
        'phase': 'build',
        'priority': 'high',
      });
      final tagId = await state.saveTag(name: 'desktop', color: '#79A7FF');
      await state.assignTagToProject('atlas', tagId);
      await state.addProjectPerson('atlas', 'Pat', 'Owner', 'Approves scope');
      await state.addProjectRisk(
        'atlas',
        'Index drift',
        'Docs may lag',
        'high',
      );
      await state.addProjectDecision(
        'atlas',
        'Use proposals',
        'Agents should not mutate directly',
        'Pat',
      );
      await state.addWorkItemToProject(
        'atlas',
        'Review local docs',
        status: 'doing',
        priority: 'urgent',
        blockedReason: 'Waiting on scan',
      );
      await state.saveDraft(
        kind: 'project_summary',
        title: 'Atlas summary',
        body: 'Current operational summary',
        projectId: 'atlas',
      );

      final brief = await service.getProjectBrief('atlas');

      expect(brief, isNotNull);
      expect(brief!.status.status, 'needs_update');
      expect(brief.status.blockedWorkItems, 1);
      expect(brief.tags.single['name'], 'desktop');
      expect(brief.people.single['name'], 'Pat');
      expect(brief.risks.single['title'], 'Index drift');
      expect(brief.decisions.single['title'], 'Use proposals');
      expect(brief.openWorkItems.single['title'], 'Review local docs');
      expect(brief.cachedSummary, 'Current operational summary');
      expect(brief.toJson()['status'], isA<Map<String, Object?>>());
    });

    test('saves valid agent proposals as review drafts', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final proposal = await service.proposeStatusChange(
        projectId: 'atlas',
        status: 'needs_review',
        reason: 'Fresh local docs were imported.',
      );
      final drafts = await service.listRecentAgentProposals();

      expect(proposal.acceptedForReview, isTrue);
      expect(proposal.draftId, isNotNull);
      expect(drafts, hasLength(1));
      expect(drafts.single.kind, AtlasAgentService.proposalDraftKind);
      expect(drafts.single.projectId, 'atlas');
      final envelope = jsonDecode(drafts.single.inputJson!) as Map;
      expect(envelope['schema'], 'atlas.agent.proposal.v1');
      expect(envelope['type'], 'status_change');
      expect((envelope['payload'] as Map)['status'], 'needs_review');
    });

    test('rejects invalid proposals without saving drafts', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final proposal = await service.proposeStatusChange(
        projectId: 'atlas',
        status: 'erase_everything',
      );
      final drafts = await service.listRecentAgentProposals();

      expect(proposal.acceptedForReview, isFalse);
      expect(proposal.draftId, isNull);
      expect(proposal.validationErrors, isNotEmpty);
      expect(drafts, isEmpty);
    });

    test('approves status change proposals', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final proposal = await service.proposeStatusChange(
        projectId: 'atlas',
        status: 'blocked',
        reason: 'Waiting on owner review.',
      );

      final result = await service.approveAgentProposal(proposal.draftId!);
      final project = await db.getProjectFull('atlas');
      final review = await service.getAgentProposalReview(proposal.draftId!);

      expect(result.reviewStatus, AtlasAgentService.reviewStatusApproved);
      expect(project!.status, 'blocked');
      expect(review!.isApproved, isTrue);
      expect(review.reviewMessage, 'Project status updated.');
    });

    test('approves task proposals and creates requested tags', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final proposal = await service.proposeTaskUpdate(
        projectId: 'atlas',
        title: 'Review proposal queue',
        status: 'doing',
        priority: 'high',
        tagNames: const ['agent', 'review'],
      );

      final result = await service.approveAgentProposal(proposal.draftId!);
      final item = await db.getWorkItem(result.entityId!);
      final tags = await db.getTagsForWorkItem(result.entityId!);

      expect(item, isNotNull);
      expect(item!.title, 'Review proposal queue');
      expect(item.status, 'doing');
      expect(tags.map((tag) => tag.name), ['agent', 'review']);
    });

    test(
      'queues, claims, and completes LLM tasks through review drafts',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Prepare handoff',
        );

        final queued = await service.enqueueLlmTask(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Draft handoff',
          objective: 'Summarize the current project state.',
          priority: 'high',
          context: {'source': 'test'},
        );
        final mediaId = await state.saveProjectMedia(
          projectId: 'atlas',
          title: 'Scope sketch',
          originalFilename: 'scope.png',
          storedPath: r'B:\tmp\scope.png',
          mediaType: 'image',
        );
        await state.attachProjectMediaToLlmTask(queued.id, mediaId);
        final detail = await service.getLlmTaskDetail(queued.id);
        final claimed = await service.claimLlmTask(
          taskId: queued.id,
          workerId: 'llm-harness-test',
        );
        final completed = await service.completeLlmTask(
          taskId: queued.id,
          workerId: 'llm-harness-test',
          result: {'summary': 'Ready for review'},
          proposalTitle: 'Harness handoff',
          proposalBody: 'Reviewable handoff body.',
        );
        final reviews = await service.listRecentAgentProposalReviews();
        final tasks = await service.listLlmTasks(projectId: 'atlas');

        expect(queued.status, 'pending');
        expect((detail!['media'] as List).single['id'], mediaId);
        expect(claimed!.status, 'leased');
        expect(claimed.leasedBy, 'llm-harness-test');
        expect(completed.status, 'completed');
        expect(completed.reviewDraftId, isNotNull);
        expect(completed.result['summary'], 'Ready for review');
        expect(tasks.single.id, queued.id);
        expect(reviews.single.type, 'handoff_record');
        expect(reviews.single.isPending, isTrue);
      },
    );

    test('updates and moves queued LLM tasks between projects', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      await db.createProject('boh', 'BOH', DateTime(2026, 1, 1));
      final workItemId = await state.addWorkItemToProject(
        'atlas',
        'Prepare handoff',
      );
      final queued = await service.enqueueLlmTask(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Draft handoff',
        objective: 'Summarize Atlas.',
      );

      await expectLater(
        service.updateLlmTask(
          taskId: queued.id,
          projectId: 'boh',
          workItemId: workItemId,
          title: 'Draft BOH handoff',
          objective: 'Summarize BOH.',
        ),
        throwsStateError,
      );

      final moved = await service.updateLlmTask(
        taskId: queued.id,
        projectId: 'boh',
        title: 'Draft BOH handoff',
        objective: 'Summarize BOH.',
        priority: 'urgent',
        context: {'source': 'operator-edit'},
      );
      final atlasTasks = await service.listLlmTasks(projectId: 'atlas');
      final bohTasks = await service.listLlmTasks(projectId: 'boh');

      expect(moved.projectId, 'boh');
      expect(moved.workItemId, isNull);
      expect(moved.title, 'Draft BOH handoff');
      expect(moved.priority, 'urgent');
      expect(moved.context['source'], 'operator-edit');
      expect(atlasTasks, isEmpty);
      expect(bohTasks.single.id, queued.id);
    });

    test('editing a leased LLM task revokes the lease', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final queued = await service.enqueueLlmTask(
        projectId: 'atlas',
        title: 'Draft next action',
        objective: 'Prepare a proposed next action for review.',
      );
      await service.claimLlmTask(
        taskId: queued.id,
        workerId: 'llm-harness-test',
      );

      final edited = await service.updateLlmTask(
        taskId: queued.id,
        projectId: 'atlas',
        title: 'Draft corrected next action',
        objective: 'Prepare the corrected action for review.',
      );

      expect(edited.status, 'pending');
      expect(edited.leasedBy, isNull);
      expect(edited.leasedAt, isNull);
      expect(edited.leaseExpiresAt, isNull);
      await expectLater(
        service.completeLlmTask(
          taskId: queued.id,
          workerId: 'llm-harness-test',
          result: {'summary': 'stale result'},
        ),
        throwsStateError,
      );
    });

    test(
      'cancelled LLM tasks can be requeued but not completed late',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        final queued = await service.enqueueLlmTask(
          projectId: 'atlas',
          title: 'Draft next action',
          objective: 'Prepare a proposed next action for review.',
        );
        await service.claimLlmTask(
          taskId: queued.id,
          workerId: 'llm-harness-test',
        );

        final cancelled = await service.cancelLlmTask(
          taskId: queued.id,
          reason: 'Wrong project.',
        );
        final claimCancelled = await service.claimLlmTask(
          taskId: queued.id,
          workerId: 'llm-harness-test',
        );

        expect(cancelled.status, 'cancelled');
        expect(cancelled.leasedBy, isNull);
        expect(cancelled.error, 'Wrong project.');
        expect(claimCancelled, isNull);
        await expectLater(
          service.completeLlmTask(
            taskId: queued.id,
            workerId: 'llm-harness-test',
            result: {'summary': 'stale result'},
          ),
          throwsStateError,
        );

        final requeued = await service.requeueLlmTask(taskId: queued.id);

        expect(requeued.status, 'pending');
        expect(requeued.error, isNull);
        expect(requeued.completedAt, isNull);
      },
    );

    test('rejects pending proposals without applying them', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final proposal = await service.proposeStatusChange(
        projectId: 'atlas',
        status: 'archived',
      );

      final result = await service.rejectAgentProposal(
        proposal.draftId!,
        reason: 'Not ready.',
      );
      final project = await db.getProjectFull('atlas');
      final review = await service.getAgentProposalReview(proposal.draftId!);

      expect(result.reviewStatus, AtlasAgentService.reviewStatusRejected);
      expect(project!.status, 'active');
      expect(review!.isRejected, isTrue);
      expect(review.reviewMessage, 'Not ready.');
    });
  });
}
