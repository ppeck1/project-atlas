import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
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
        await db.createProject('paused', 'Paused', DateTime(2026, 1, 1));
        await db.createProject('completed', 'Completed', DateTime(2026, 1, 1));
        await db.createProject(
          'status-deleted',
          'Status Deleted',
          DateTime(2026, 1, 1),
        );
        await db.createProject(
          'timestamp-deleted',
          'Timestamp Deleted',
          DateTime(2026, 1, 1),
        );
        await db.createProject(
          'legacy-marker',
          'Legacy Marker',
          DateTime(2026, 1, 1),
        );
        await db.createProject(
          'general-tasks-title',
          'General Tasks',
          DateTime(2026, 1, 1),
        );
        await db.updateProjectMeta('bravo', {'status': 'stale'});
        await db.updateProjectMeta('charlie', {'status': 'archived'});
        await db.updateProjectMeta('paused', {'status': 'paused'});
        await db.updateProjectMeta('completed', {'status': 'completed'});
        await db.customStatement(
          'UPDATE projects SET status = ? WHERE id = ?',
          ['deleted', 'status-deleted'],
        );
        await db.softDeleteProject('timestamp-deleted', 'fixture');
        await db.updateProjectMeta('timestamp-deleted', {'status': 'active'});
        await db.updateProjectMeta('legacy-marker', {
          'description': AppDb.kGeneralTasksProjectDescription,
        });
        await db.ensureGeneralTaskStage();

        final rows = await service.listProjects();
        final withoutArchived = await service.listProjects(
          includeArchived: false,
        );
        final attention = await service.getStaleProjects();

        expect(rows.map((project) => project.title), [
          'Alpha',
          'Bravo',
          'Charlie',
          'Completed',
          'General Tasks',
          'Paused',
        ]);
        expect(
          rows.map((project) => project.id),
          isNot(contains(AppDb.kGeneralTasksProjectId)),
        );
        expect(rows.map((project) => project.id), contains('charlie'));
        expect(
          withoutArchived.map((project) => project.id),
          isNot(contains('charlie')),
        );
        expect(
          withoutArchived.map((project) => project.id),
          containsAll(['paused', 'completed', 'general-tasks-title']),
        );
        for (final excluded in [
          'status-deleted',
          'timestamp-deleted',
          'legacy-marker',
        ]) {
          expect(rows.map((project) => project.id), isNot(contains(excluded)));
        }
        expect(await service.getProjectStatus('status-deleted'), isNull);
        expect(await service.getProjectStatus('timestamp-deleted'), isNull);
        expect(await service.getProjectStatus('legacy-marker'), isNull);
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
        readiness: 'review_needed',
      );
      final brief = await service.getProjectBrief('atlas');

      expect(brief, isNotNull);
      expect(brief!.status.status, 'needs_update');
      expect(brief.status.blockedWorkItems, 1);
      expect(brief.status.blocksProgressWorkItems, 1);
      expect(brief.status.needsAttention, isTrue);
      expect((brief.status.toJson())['blocksProgressWorkItems'], 1);
      expect(brief.tags.single['name'], 'desktop');
      expect(brief.people.single['name'], 'Pat');
      expect(brief.risks.single['title'], 'Index drift');
      expect(brief.decisions.single['title'], 'Use proposals');
      expect(brief.openWorkItems.single['title'], 'Review local docs');
      expect(brief.toJson()['status'], isA<Map<String, Object?>>());
    });

    test('reports missing capsule linkage without throwing', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final identity = await service.getProjectIdentity('atlas');
      final capsule = await service.getProjectCapsuleStatus('atlas');
      final bootstrap = await service.getProjectBootstrapContext('atlas');

      expect(identity, isNotNull);
      expect(identity!.localPath, isNull);
      expect(
        identity.issues,
        contains('Project is not linked to a local registry entry.'),
      );
      expect(capsule, isNotNull);
      expect(capsule!.evidenceAvailability, 'not_linked');
      expect(bootstrap, isNotNull);
      expect(bootstrap!.schema, 'atlas.project_bootstrap_context.v1');
      expect(bootstrap.confidence, 'medium');
      expect(bootstrap.gaps, contains('Project has no linked local registry.'));
    });

    test(
      'builds capsule status and bootstrap context from linked repo',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'atlas_capsule_status_test_',
        );
        try {
          final projectDir = Directory(p.join(root.path, '.project'));
          Directory(
            p.join(projectDir.path, 'runs'),
          ).createSync(recursive: true);
          Directory(
            p.join(projectDir.path, 'atlas_outbox'),
          ).createSync(recursive: true);
          Directory(
            p.join(projectDir.path, 'secondary_outbox'),
          ).createSync(recursive: true);
          File(
            p.join(projectDir.path, 'project_manifest.json'),
          ).writeAsStringSync(
            jsonEncode({
              'schema_version': '0.2',
              'project_id': 'atlas',
              'display_name': 'Atlas',
              'root': '.',
              'repo_kind': 'software',
              'visibility': 'public',
              'profiles': ['public_repo', 'software_project'],
              'canonical_docs': {
                'readme': 'README.md',
                'handoff': 'docs/HANDOFF.md',
                'variable_matrix': 'docs/VARIABLE_MATRIX.md',
              },
              'validation': {
                'required': ['flutter analyze', 'flutter test'],
                'focused': <String>[],
                'smoke': <String>[],
                'manual': <String>[],
              },
              'protected_paths': ['README.md'],
              'generated_paths': ['build/'],
              'secrets_policy': 'names-only',
              'atlas_sync': {
                'enabled': true,
                'mode': 'outbox',
                'project_key': 'atlas',
              },
              'secondary_sync': {
                'enabled': true,
                'mode': 'outbox',
                'authority': 'evidence-only',
                'project_key': 'atlas',
              },
              'git_policy': {
                'require_git': true,
                'commit_after_signable_run': true,
                'push_policy': 'manual',
                'allow_dirty_unrelated': false,
              },
            }),
          );
          File(p.join(projectDir.path, 'ops_capsule.json')).writeAsStringSync(
            jsonEncode({
              'schema_version': '0.2',
              'capsule_version': '0.2',
              'installed_from': 'test',
              'installed_at': '2026-01-01T00:00:00Z',
              'run_ledger_required': true,
              'repair_iteration_limit': 2,
              'readme_update_mode': 'audit-every-run',
              'variable_matrix_update_mode': 'audit-every-run',
              'handoff_update_mode': 'non-read-only',
              'subagent_policy': 'token-saving-default',
              'profiles': ['public_repo', 'software_project'],
            }),
          );
          File(
            p.join(projectDir.path, 'runs', 'latest.md'),
          ).writeAsStringSync('# Run\n');
          File(
            p.join(projectDir.path, 'atlas_outbox', 'latest.json'),
          ).writeAsStringSync('{}');

          await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
          await _insertProjectRegistry(
            db,
            id: 'registry-atlas',
            projectId: 'atlas',
            displayName: 'Atlas Repo',
            localPath: root.path,
            gitRoot: root.path,
          );
          await service.enqueueLlmTask(
            projectId: 'atlas',
            title: 'Implement bootstrap',
            objective: 'Create the bootstrap context read model.',
            priority: 'high',
            context: {'source': 'test'},
          );

          final identity = await service.getProjectIdentity('atlas');
          final capsule = await service.getProjectCapsuleStatus('atlas');
          final bootstrap = await service.getProjectBootstrapContext('atlas');

          expect(identity, isNotNull);
          expect(identity!.capsuleProjectId, 'atlas');
          expect(identity.capsuleProfiles, contains('software_project'));
          expect(capsule, isNotNull);
          expect(capsule!.evidenceAvailability, 'local_evidence_present');
          expect(capsule.counts['runLedgers'], 1);
          expect(capsule.counts['atlasOutboxPending'], 1);
          expect(capsule.toJson()['validation'], isA<Map<String, Object?>>());
          expect(bootstrap, isNotNull);
          expect(bootstrap!.identity.projectId, 'atlas');
          expect(
            bootstrap.pendingLlmTasks.single['title'],
            'Implement bootstrap',
          );
          expect(
            bootstrap.recommendedNextAction,
            'Claim next pending LLM task: Implement bootstrap.',
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
    );

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
      expect((envelope['payload'] as Map)['baseTruthRevisionId'], isNotEmpty);
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

    test('rejects invalid closeout proposals without saving drafts', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));

      final proposal = await service.proposeCloseout(
        projectId: 'atlas',
        summary: ' ',
      );
      final drafts = await service.listRecentAgentProposals();

      expect(proposal.acceptedForReview, isFalse);
      expect(proposal.draftId, isNull);
      expect(
        proposal.validationErrors,
        contains('Closeout summary is required.'),
      );
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
      expect(
        await ProjectCapsuleTruthService(db).listRevisions('atlas'),
        hasLength(2),
      );
    });

    test(
      'recovers review after accepted truth applied before draft approval',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        final proposed = await service.proposeStatusChange(
          projectId: 'atlas',
          status: 'blocked',
        );
        final draft = await state.getDraft(proposed.draftId!);
        final proposal = AtlasProposalDraft.fromDraft(draft!);
        final baseRevisionId =
            proposal.payload['baseTruthRevisionId']! as String;
        await ProjectCapsuleTruthService(db).acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: baseRevisionId,
          fields: const {'status': 'blocked'},
          actorLabel: 'Atlas Agent',
          sourceKind: 'agent_proposal',
          sourceId: draft.id,
        );

        await expectLater(
          service.rejectAgentProposal(draft.id),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('already changed accepted project truth'),
            ),
          ),
        );
        expect(
          (await service.getAgentProposalReview(draft.id))!.isPending,
          isTrue,
        );

        final recovered = await service.approveAgentProposal(draft.id);
        expect(recovered.reviewStatus, AtlasAgentService.reviewStatusApproved);
        expect(
          (await service.getAgentProposalReview(draft.id))!.isApproved,
          isTrue,
        );
        expect(
          await ProjectCapsuleTruthService(db).listRevisions('atlas'),
          hasLength(2),
        );
      },
    );

    test('stale truth proposals remain pending and change nothing', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final proposal = await service.proposeStatusChange(
        projectId: 'atlas',
        status: 'blocked',
      );
      await state.updateProjectMeta('atlas', {
        'desiredOutcome': 'A newer accepted outcome.',
      });

      await expectLater(
        service.approveAgentProposal(proposal.draftId!),
        throwsA(isA<ProjectCapsuleTruthConflict>()),
      );
      final project = await db.getProjectFull('atlas');
      final review = await service.getAgentProposalReview(proposal.draftId!);

      expect(project!.status, 'active');
      expect(project.desiredOutcome, 'A newer accepted outcome.');
      expect(review!.isPending, isTrue);
    });

    test(
      'legacy truth proposals without a base revision fail closed',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
        final proposal = await service.proposeStatusChange(
          projectId: 'atlas',
          status: 'blocked',
        );
        final draft = await state.getDraft(proposal.draftId!);
        final envelope = jsonDecode(draft!.inputJson!) as Map<String, Object?>;
        final payload = Map<String, Object?>.from(envelope['payload']! as Map)
          ..remove('baseTruthRevisionId');
        envelope['payload'] = payload;
        await state.updateDraftReview(
          id: draft.id,
          accepted: false,
          inputJson: jsonEncode(envelope),
        );

        await expectLater(
          service.approveAgentProposal(draft.id),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('must be recreated'),
            ),
          ),
        );
        expect((await db.getProjectFull('atlas'))!.status, 'active');
        expect(
          (await service.getAgentProposalReview(draft.id))!.isPending,
          isTrue,
        );
      },
    );

    test('approves closeout proposals as handoff drafts', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final proposal = await service.proposeCloseout(
        projectId: 'atlas',
        runId: 'example-run',
        runState: 'signable',
        summary: 'Example stdio smoke is green.',
        scope: {
          'workOrders': ['sample-task-1', 'sample-task-2'],
        },
        changedFiles: const ['lib/mcp/atlas_mcp_stdio.dart'],
        validation: const [
          {'command': 'flutter test', 'passed': true},
        ],
        capsuleDoctor: const {'status': 'healthy'},
        packetPaths: const ['.local/example-closeout.md'],
        gitState: const {'dirty': true, 'branch': 'main'},
        commitRecommendation: 'Review locally before commit.',
        risks: const ['Manual UI verification remains pending.'],
        nextAction: 'Human review.',
      );

      final result = await service.approveAgentProposal(proposal.draftId!);
      final project = await db.getProjectFull('atlas');
      final handoff = await state.getDraft(result.entityId!);
      final review = await service.getAgentProposalReview(proposal.draftId!);

      expect(proposal.acceptedForReview, isTrue);
      expect(proposal.warnings, isEmpty);
      expect(result.type, 'closeout_record');
      expect(result.reviewStatus, AtlasAgentService.reviewStatusApproved);
      expect(project!.status, 'active');
      expect(handoff, isNotNull);
      expect(handoff!.kind, AtlasAgentService.handoffDraftKind);
      expect(handoff.title, contains('Example stdio smoke is green.'));
      expect(handoff.body, contains('example-run'));
      expect(handoff.body, contains('flutter test'));
      expect(handoff.body, contains('Manual UI verification remains pending.'));
      expect(review!.isApproved, isTrue);
      expect(review.reviewMessage, contains('Closeout handoff draft created'));
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
          workerId: 'sample-worker',
        );
        final completed = await service.completeLlmTask(
          taskId: queued.id,
          workerId: 'sample-worker',
          result: {'summary': 'Ready for review'},
          proposalTitle: 'Harness handoff',
          proposalBody: 'Reviewable handoff body.',
        );
        final reviews = await service.listRecentAgentProposalReviews();
        final tasks = await service.listLlmTasks(projectId: 'atlas');

        expect(queued.status, 'pending');
        expect((detail!['media'] as List).single['id'], mediaId);
        expect(claimed!.status, 'leased');
        expect(claimed.leasedBy, 'sample-worker');
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
      await db.createProject('sample', 'Sample Project', DateTime(2026, 1, 1));
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
          projectId: 'sample',
          workItemId: workItemId,
          title: 'Draft sample handoff',
          objective: 'Summarize the sample project.',
        ),
        throwsStateError,
      );

      final moved = await service.updateLlmTask(
        taskId: queued.id,
        projectId: 'sample',
        title: 'Draft sample handoff',
        objective: 'Summarize the sample project.',
        priority: 'urgent',
        context: {'source': 'operator-edit'},
      );
      final atlasTasks = await service.listLlmTasks(projectId: 'atlas');
      final sampleTasks = await service.listLlmTasks(projectId: 'sample');

      expect(moved.projectId, 'sample');
      expect(moved.workItemId, isNull);
      expect(moved.title, 'Draft sample handoff');
      expect(moved.priority, 'urgent');
      expect(moved.context['source'], 'operator-edit');
      expect(atlasTasks, isEmpty);
      expect(sampleTasks.single.id, queued.id);
    });

    test('editing a leased LLM task revokes the lease', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      final queued = await service.enqueueLlmTask(
        projectId: 'atlas',
        title: 'Draft next action',
        objective: 'Prepare a proposed next action for review.',
      );
      await service.claimLlmTask(taskId: queued.id, workerId: 'sample-worker');

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
          workerId: 'sample-worker',
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
          workerId: 'sample-worker',
        );

        final cancelled = await service.cancelLlmTask(
          taskId: queued.id,
          reason: 'Wrong project.',
        );
        final claimCancelled = await service.claimLlmTask(
          taskId: queued.id,
          workerId: 'sample-worker',
        );

        expect(cancelled.status, 'cancelled');
        expect(cancelled.leasedBy, isNull);
        expect(cancelled.error, 'Wrong project.');
        expect(claimCancelled, isNull);
        await expectLater(
          service.completeLlmTask(
            taskId: queued.id,
            workerId: 'sample-worker',
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

    test('builds queue-bound bootstrap context for active LLM tasks', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
      await db.createProject('sample', 'Sample Project', DateTime(2026, 1, 1));
      final queued = await service.enqueueLlmTask(
        projectId: 'atlas',
        title: 'Draft startup packet',
        objective: 'Use the task-specific bootstrap before implementation.',
        context: {'workOrder': 'sample-task-4'},
      );
      final mediaId = await state.saveProjectMedia(
        projectId: 'atlas',
        title: 'Scope screenshot',
        originalFilename: 'scope.png',
        storedPath: r'B:\tmp\scope.png',
        mediaType: 'image',
        mimeType: 'image/png',
        extension: 'png',
        byteSize: 42,
      );
      await state.attachProjectMediaToLlmTask(queued.id, mediaId);

      final pendingBootstrap = await service.getLlmTaskBootstrap(queued.id);
      final claimed = await service.claimLlmTask(
        taskId: queued.id,
        workerId: 'worker-1',
      );
      final leasedBootstrap = await service.getLlmTaskBootstrap(
        queued.id,
        projectId: 'atlas',
      );

      expect(pendingBootstrap.schema, 'atlas.llm_task_bootstrap_context.v1');
      expect(pendingBootstrap.task['id'], queued.id);
      expect((pendingBootstrap.task['media'] as List).single['id'], mediaId);
      expect(pendingBootstrap.projectBootstrap.identity.projectId, 'atlas');
      expect(claimed!.status, 'leased');
      expect(leasedBootstrap.task['status'], 'leased');

      await expectLater(
        service.getLlmTaskBootstrap(queued.id, projectId: 'sample'),
        throwsStateError,
      );
      await service.completeLlmTask(
        taskId: queued.id,
        workerId: 'worker-1',
        result: {'summary': 'done'},
      );
      await expectLater(
        service.getLlmTaskBootstrap(queued.id),
        throwsStateError,
      );
    });

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

Future<void> _insertProjectRegistry(
  AppDb db, {
  required String id,
  required String projectId,
  required String displayName,
  required String localPath,
  required String gitRoot,
}) async {
  final now =
      DateTime(2026, 1, 1).millisecondsSinceEpoch ~/
      Duration.millisecondsPerSecond;
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
      now,
      now,
      now,
    ],
  );
}
