import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/mcp/atlas_mcp_server.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
  });

  group('proposal acceptance integrity', () {
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

    test('every proposal type rolls side effects back before review', () async {
      Future<void> proveRollback({
        required String projectId,
        required Future<AtlasProposalResult> Function() create,
        required Future<void> Function() verifyRolledBack,
      }) async {
        await db.createProject(projectId, projectId, DateTime(2026, 7, 21));
        final proposal = await create();
        final crashing = AtlasAgentService(
          state,
          proposalApprovalStepHook: (step) async {
            if (step == 'after-proposal-side-effect') {
              throw StateError('injected proposal crash');
            }
          },
        );

        await expectLater(
          crashing.approveAgentProposal(proposal.draftId!),
          throwsA(isA<StateError>()),
        );
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          isTrue,
        );
        expect(
          (await db.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          isEmpty,
        );
        await verifyRolledBack();

        final applied = await service.approveAgentProposal(proposal.draftId!);
        final replay = await service.approveAgentProposal(proposal.draftId!);
        expect(replay.entityId, applied.entityId);
        expect(replay.message, applied.message);
        expect(
          (await db.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          hasLength(1),
        );
      }

      await proveRollback(
        projectId: 'status-project',
        create: () => service.proposeStatusChange(
          projectId: 'status-project',
          status: 'blocked',
        ),
        verifyRolledBack: () async {
          expect((await db.getProjectFull('status-project'))!.status, 'active');
          expect(
            await state.getProjectCapsuleRevisions('status-project'),
            hasLength(1),
          );
        },
      );
      await db.clearEventLog();

      await proveRollback(
        projectId: 'task-project',
        create: () => service.proposeTaskUpdate(
          projectId: 'task-project',
          title: 'Atomic task',
          tagNames: const ['atomic-tag'],
        ),
        verifyRolledBack: () async {
          expect(await db.getWorkItemsForProject('task-project'), isEmpty);
          expect(await db.findTagByName('atomic-tag'), isNull);
        },
      );
      await db.clearEventLog();

      await proveRollback(
        projectId: 'manifest-project',
        create: () => service.proposeManifestUpdate(
          projectId: 'manifest-project',
          fields: const {'title': 'Changed manifest title'},
        ),
        verifyRolledBack: () async {
          expect(
            (await db.getProjectFull('manifest-project'))!.title,
            'manifest-project',
          );
          expect(
            await state.getProjectCapsuleRevisions('manifest-project'),
            hasLength(1),
          );
        },
      );
      await db.clearEventLog();

      await proveRollback(
        projectId: 'validation-project',
        create: () => service.recordValidationRun(
          projectId: 'validation-project',
          command: 'flutter test',
          passed: true,
        ),
        verifyRolledBack: () async {
          expect(
            (await db.getRecentEvents()).where(
              (event) => event.action == 'validation_run_approved',
            ),
            isEmpty,
          );
        },
      );
      await db.clearEventLog();

      await proveRollback(
        projectId: 'handoff-project',
        create: () => service.recordHandoff(
          projectId: 'handoff-project',
          title: 'Atomic handoff',
          body: 'Must not survive a rolled-back approval.',
        ),
        verifyRolledBack: () async {
          expect(
            (await state.getDrafts()).where(
              (draft) => draft.kind == AtlasAgentService.handoffDraftKind,
            ),
            isEmpty,
          );
        },
      );
      await db.clearEventLog();

      await proveRollback(
        projectId: 'closeout-project',
        create: () => service.proposeCloseout(
          projectId: 'closeout-project',
          summary: 'Atomic closeout',
        ),
        verifyRolledBack: () async {
          expect(
            (await state.getDrafts()).where(
              (draft) => draft.kind == AtlasAgentService.handoffDraftKind,
            ),
            hasLength(1),
            reason: 'only the earlier successfully retried handoff exists',
          );
          expect(
            (await db.getRecentEvents()).where(
              (event) => event.action == 'closeout_record_approved',
            ),
            isEmpty,
          );
        },
      );
    });

    test(
      'failure after review write also rolls the whole approval back',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          title: 'Review boundary task',
        );
        final crashing = AtlasAgentService(
          state,
          proposalApprovalStepHook: (step) async {
            if (step == 'after-proposal-review') {
              throw StateError('crash before commit');
            }
          },
        );

        await expectLater(
          crashing.approveAgentProposal(proposal.draftId!),
          throwsA(isA<StateError>()),
        );
        expect(await db.getWorkItemsForProject('atlas'), isEmpty);
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          isTrue,
        );
        expect(
          (await db.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          isEmpty,
        );
      },
    );

    test(
      'existing task and tag replacement roll back after task write',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final oldTag = await state.saveTag(name: 'old');
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original task',
          tagIds: [oldTag],
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Proposed title',
          tagNames: const ['new'],
        );
        final crashing = AtlasAgentService(
          state,
          proposalApprovalStepHook: (step) async {
            if (step == 'after-task-tags-write') {
              throw StateError('task tag write crash');
            }
          },
        );

        await expectLater(
          crashing.approveAgentProposal(proposal.draftId!),
          throwsA(isA<StateError>()),
        );
        expect((await db.getWorkItem(workItemId))!.title, 'Original task');
        expect(
          (await db.getTagsForWorkItem(workItemId)).map((tag) => tag.name),
          ['old'],
        );
        expect(await db.findTagByName('new'), isNull);
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          true,
        );
      },
    );

    test('manifest truth and tags roll back at their write boundary', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final oldTag = await state.saveTag(name: 'old-project-tag');
      await state.setProjectTags('atlas', [oldTag]);
      final proposal = await service.proposeManifestUpdate(
        projectId: 'atlas',
        fields: const {
          'title': 'Proposed project title',
          'tags': ['new-project-tag'],
        },
      );
      final crashing = AtlasAgentService(
        state,
        proposalApprovalStepHook: (step) async {
          if (step == 'after-manifest-tags-write') {
            throw StateError('manifest tag write crash');
          }
        },
      );

      await expectLater(
        crashing.approveAgentProposal(proposal.draftId!),
        throwsA(isA<StateError>()),
      );
      expect((await db.getProjectFull('atlas'))!.title, 'Atlas');
      expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
      expect((await db.getTagsForProject('atlas')).map((tag) => tag.name), [
        'old-project-tag',
      ]);
      expect(await db.findTagByName('new-project-tag'), isNull);
      expect(
        (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
        true,
      );

      final applied = await service.approveAgentProposal(proposal.draftId!);
      final replay = await service.approveAgentProposal(proposal.draftId!);
      expect(replay.entityId, applied.entityId);
      expect(
        (await db.getProjectFull('atlas'))!.title,
        'Proposed project title',
      );
      expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(2));
      expect((await db.getTagsForProject('atlas')).map((tag) => tag.name), [
        'new-project-tag',
      ]);
      expect(
        (await db.getRecentEvents()).where(
          (event) => event.action == 'proposal_approved',
        ),
        hasLength(1),
      );
    });

    test('manifest snapshots are composite and server-authoritative', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final tagId = await state.saveTag(name: 'Alpha', color: '#112233');
      await state.setProjectTags('atlas', [tagId]);
      final adapter = AtlasMcpAdapter(service);

      final result = await adapter.callTool('propose_manifest_update', {
        'projectId': 'atlas',
        'fields': {
          'title': 'Proposed title',
          'tags': ['beta'],
        },
        'baseManifestSnapshot': {
          'schema': 'forged',
          'truthRevisionId': 'forged',
          'projectTagSetHash': 'forged',
        },
      });
      final proposal = result.data! as Map;
      final payload = proposal['payload'] as Map;
      final base = payload['baseManifestSnapshot'] as Map;

      expect(result.isError, isFalse);
      expect(base, hasLength(4));
      expect(base['schema'], 'atlas.manifest_proposal_base.v1');
      expect(base['projectId'], 'atlas');
      expect(base['truthRevisionId'], isNot('forged'));
      expect(base['projectTagSetHash'], hasLength(64));
      expect(base['projectTagSetHash'], isNot('forged'));
      expect(payload['baseTruthRevisionId'], base['truthRevisionId']);

      final listed = await adapter.callTool('list_agent_proposals');
      final listedBase =
          ((((listed.data! as List).single as Map)['payload']
                  as Map)['baseManifestSnapshot']
              as Map);
      expect(listedBase, equals(base));
    });

    test(
      'manifest approval detects stale assignment, name, and color',
      () async {
        Future<void> expectStale(
          String projectId,
          Future<void> Function(String tagId) mutate,
        ) async {
          await db.createProject(projectId, projectId, DateTime(2026, 7, 21));
          final tagId = await state.saveTag(name: '$projectId-tag');
          await state.setProjectTags(projectId, [tagId]);
          final proposal = await service.proposeManifestUpdate(
            projectId: projectId,
            fields: const {
              'tags': ['replacement'],
            },
          );
          await mutate(tagId);

          await expectLater(
            service.approveAgentProposal(proposal.draftId!),
            throwsA(
              isA<AtlasProposalConflict>().having(
                (error) => error.reason,
                'reason',
                AtlasProposalConflictReason.staleProjectTagSet,
              ),
            ),
          );
          expect(
            (await service.getAgentProposalReview(
              proposal.draftId!,
            ))!.isPending,
            isTrue,
          );
          expect(await db.findTagByName('replacement'), isNull);
        }

        await expectStale('assignment', (tagId) async {
          final added = await state.saveTag(name: 'operator-added');
          await state.setProjectTags('assignment', [tagId, added]);
        });
        await expectStale(
          'rename',
          (tagId) => db.updateTag(tagId, name: 'substantive-rename'),
        );
        await expectStale(
          'color',
          (tagId) => db.updateTag(tagId, color: '#abcdef'),
        );
      },
    );

    test('composite manifest snapshot detects cross-domain races', () async {
      await db.createProject('truth-race', 'Truth race', DateTime(2026, 7, 21));
      final tagsOnly = await service.proposeManifestUpdate(
        projectId: 'truth-race',
        fields: const {
          'tags': ['proposal-tag'],
        },
      );
      await state.updateProjectMeta('truth-race', {
        'description': 'Operator truth change.',
      });
      await expectLater(
        service.approveAgentProposal(tagsOnly.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.staleManifestTruth,
          ),
        ),
      );
      expect(await db.findTagByName('proposal-tag'), isNull);

      await db.createProject('tag-race', 'Tag race', DateTime(2026, 7, 21));
      final metadataOnly = await service.proposeManifestUpdate(
        projectId: 'tag-race',
        fields: const {'description': 'Proposal metadata.'},
      );
      final operatorTag = await state.saveTag(name: 'operator-tag');
      await state.setProjectTags('tag-race', [operatorTag]);
      await expectLater(
        service.approveAgentProposal(metadataOnly.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.staleProjectTagSet,
          ),
        ),
      );
      expect((await db.getProjectFull('tag-race'))!.description, isNull);
    });

    test('manifest tags distinguish absent from explicitly empty', () async {
      await db.createProject('absent', 'Absent', DateTime(2026, 7, 21));
      final absentTag = await state.saveTag(name: 'preserved');
      await state.setProjectTags('absent', [absentTag]);
      final absent = await service.proposeManifestUpdate(
        projectId: 'absent',
        fields: const {'description': 'Metadata only.'},
      );
      await service.approveAgentProposal(absent.draftId!);
      expect((await db.getTagsForProject('absent')).map((tag) => tag.name), [
        'preserved',
      ]);

      await db.createProject('empty', 'Empty', DateTime(2026, 7, 21));
      final emptyTag = await state.saveTag(name: 'to-clear');
      await state.setProjectTags('empty', [emptyTag]);
      final empty = await service.proposeManifestUpdate(
        projectId: 'empty',
        fields: const {'tags': <String>[]},
      );
      expect(
        (empty.payload['fields'] as Map<String, Object?>).containsKey('tags'),
        isTrue,
      );
      await service.approveAgentProposal(empty.draftId!);
      expect(await db.getTagsForProject('empty'), isEmpty);
      expect(await state.getProjectCapsuleRevisions('empty'), hasLength(1));
    });

    test(
      'legacy and malformed manifest tokens fail with typed conflicts',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));

        Future<void> mutateAndExpect(
          void Function(Map<String, Object?> payload) mutate,
          AtlasProposalConflictReason reason,
        ) async {
          final proposed = await service.proposeManifestUpdate(
            projectId: 'atlas',
            fields: const {
              'tags': ['must-not-exist'],
            },
          );
          final draft = await state.getDraft(proposed.draftId!);
          final envelope =
              jsonDecode(draft!.inputJson!) as Map<String, Object?>;
          final payload = Map<String, Object?>.from(
            envelope['payload']! as Map,
          );
          mutate(payload);
          envelope['payload'] = payload;
          await state.updateDraftReview(
            id: draft.id,
            accepted: false,
            inputJson: jsonEncode(envelope),
          );

          await expectLater(
            service.approveAgentProposal(draft.id),
            throwsA(
              isA<AtlasProposalConflict>().having(
                (error) => error.reason,
                'reason',
                reason,
              ),
            ),
          );
          expect(
            (await service.getAgentProposalReview(draft.id))!.isPending,
            true,
          );
          expect(await db.findTagByName('must-not-exist'), isNull);
        }

        await mutateAndExpect(
          (payload) => payload.remove('baseManifestSnapshot'),
          AtlasProposalConflictReason.missingManifestBaseSnapshot,
        );
        await mutateAndExpect((payload) {
          payload['baseManifestSnapshot'] = {
            'schema': 'atlas.manifest_proposal_base.v1',
            'projectId': 'atlas',
            'truthRevisionId': payload['baseTruthRevisionId'],
            'projectTagSetHash': 'not-a-digest',
          };
        }, AtlasProposalConflictReason.missingManifestBaseSnapshot);
        await mutateAndExpect((payload) {
          final fields = Map<String, Object?>.from(payload['fields']! as Map)
            ..['tags'] = 'not-a-list';
          payload['fields'] = fields;
        }, AtlasProposalConflictReason.invalidManifestTagInput);
      },
    );

    test('deleted manifest project fails before tag creation', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final proposal = await service.proposeManifestUpdate(
        projectId: 'atlas',
        fields: const {
          'tags': ['orphan-project-tag'],
        },
      );
      await state.softDeleteProject('atlas', 'Deleted during review.');

      await expectLater(
        service.approveAgentProposal(proposal.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.manifestProjectNotFound,
          ),
        ),
      );
      expect(await db.findTagByName('orphan-project-tag'), isNull);
      expect(
        (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
        isTrue,
      );
    });

    test(
      'ambiguous case-insensitive manifest tag fails typed without writes',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final upperId = await state.saveTag(name: 'Alpha');
        final lowerId = await state.saveTag(name: 'alpha');
        final proposal = await service.proposeManifestUpdate(
          projectId: 'atlas',
          fields: const {
            'description': 'Must not apply.',
            'tags': ['ALPHA'],
          },
        );

        await expectLater(
          service.approveAgentProposal(proposal.draftId!),
          throwsA(
            isA<AtlasProposalConflict>()
                .having(
                  (error) => error.reason,
                  'reason',
                  AtlasProposalConflictReason.ambiguousManifestTag,
                )
                .having(
                  (error) => error.code,
                  'code',
                  'proposal_ambiguous_manifest_tag',
                ),
          ),
        );
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          isTrue,
        );
        expect((await db.getProjectFull('atlas'))!.description, isNull);
        expect(await db.getProjectTagAssignments('atlas'), isEmpty);
        expect((await db.getTags()).map((tag) => tag.id).toSet(), {
          upperId,
          lowerId,
        });
        expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
        expect(
          (await db.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          isEmpty,
        );
      },
    );

    test('dangling project tag at capture fails proposal validation', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      await db.assignTagToProject('atlas', 'missing-tag');

      final proposal = await service.proposeManifestUpdate(
        projectId: 'atlas',
        fields: const {
          'description': 'Must not apply.',
          'tags': ['must-not-exist'],
        },
      );

      expect(
        proposal.validationErrors,
        contains('Accepted project manifest state could not be loaded.'),
      );
      expect(proposal.acceptedForReview, isFalse);
      expect(proposal.draftId, isNull);
      expect(proposal.payload['baseManifestSnapshot'], isNull);
      expect((await db.getProjectFull('atlas'))!.description, isNull);
      expect(
        (await db.getProjectTagAssignments(
          'atlas',
        )).map((assignment) => assignment.tagId),
        ['missing-tag'],
      );
      expect(await db.findTagByName('must-not-exist'), isNull);
      expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
      expect(
        (await db.getRecentEvents()).where(
          (event) => event.action == 'proposal_approved',
        ),
        isEmpty,
      );
    });

    test(
      'dangling project tag after capture fails typed without mutation',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final proposal = await service.proposeManifestUpdate(
          projectId: 'atlas',
          fields: const {
            'description': 'Must not apply.',
            'tags': ['must-not-exist'],
          },
        );
        await db.assignTagToProject('atlas', 'concurrent-missing-tag');

        await expectLater(
          service.approveAgentProposal(proposal.draftId!),
          throwsA(
            isA<AtlasProposalConflict>()
                .having(
                  (error) => error.reason,
                  'reason',
                  AtlasProposalConflictReason.invalidProjectTagSet,
                )
                .having(
                  (error) => error.code,
                  'code',
                  'proposal_invalid_project_tag_set',
                ),
          ),
        );
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          isTrue,
        );
        expect((await db.getProjectFull('atlas'))!.description, isNull);
        expect(
          (await db.getProjectTagAssignments(
            'atlas',
          )).map((assignment) => assignment.tagId),
          ['concurrent-missing-tag'],
        );
        expect(await db.findTagByName('must-not-exist'), isNull);
        expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
        expect(
          (await db.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          isEmpty,
        );
      },
    );

    test('non-pending transaction markers fail closed', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final proposal = await service.proposeTaskUpdate(
        projectId: 'atlas',
        title: 'Must not apply',
      );
      final draft = await state.getDraft(proposal.draftId!);
      final envelope = jsonDecode(draft!.inputJson!) as Map<String, Object?>
        ..['reviewStatus'] = 'applying';
      await state.updateDraftReview(
        id: draft.id,
        accepted: false,
        inputJson: jsonEncode(envelope),
      );

      await expectLater(
        service.approveAgentProposal(draft.id),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.invalidReviewState,
          ),
        ),
      );
      await expectLater(
        service.rejectAgentProposal(draft.id),
        throwsA(isA<AtlasProposalConflict>()),
      );
      expect(await db.getWorkItemsForProject('atlas'), isEmpty);
    });

    test('stale task state fails closed before tag creation', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final workItemId = await state.addWorkItemToProject(
        'atlas',
        'Original task',
      );
      final proposal = await service.proposeTaskUpdate(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Proposal title',
        tagNames: const ['proposal-only-tag'],
      );
      expect(proposal.payload['baseTaskSnapshot'], isA<Map>());
      await state.updateWorkItem(id: workItemId, title: 'Operator title');

      await expectLater(
        service.approveAgentProposal(proposal.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.staleTask,
          ),
        ),
      );
      expect((await db.getWorkItem(workItemId))!.title, 'Operator title');
      expect(await db.findTagByName('proposal-only-tag'), isNull);
      expect(await db.getTagsForWorkItem(workItemId), isEmpty);
      expect(
        (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
        isTrue,
      );
    });

    test('stale exact tag set fails closed without task mutation', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final firstTag = await state.saveTag(name: 'first');
      final secondTag = await state.saveTag(name: 'second');
      final workItemId = await state.addWorkItemToProject(
        'atlas',
        'Original task',
        tagIds: [firstTag],
      );
      final proposal = await service.proposeTaskUpdate(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Proposal title',
        tagNames: const ['proposal-tag'],
      );
      await state.setWorkItemTags(workItemId, [secondTag]);

      await expectLater(
        service.approveAgentProposal(proposal.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.staleTagSet,
          ),
        ),
      );
      expect((await db.getWorkItem(workItemId))!.title, 'Original task');
      expect((await db.getTagsForWorkItem(workItemId)).map((tag) => tag.name), [
        'second',
      ]);
      expect(await db.findTagByName('proposal-tag'), isNull);
    });

    test(
      'current existing-task snapshot applies task and tags together',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final oldTag = await state.saveTag(name: 'old');
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original task',
          tagIds: [oldTag],
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Applied title',
          status: 'doing',
          priority: 'high',
          tagNames: const ['new'],
        );

        final applied = await service.approveAgentProposal(proposal.draftId!);

        expect(applied.entityId, workItemId);
        expect((await db.getWorkItem(workItemId))!.title, 'Applied title');
        expect((await db.getWorkItem(workItemId))!.status, 'doing');
        expect(
          (await db.getTagsForWorkItem(workItemId)).map((tag) => tag.name),
          ['new'],
        );
      },
    );

    test('task tags distinguish omitted from explicitly empty', () async {
      await db.createProject('omitted', 'Omitted', DateTime(2026, 7, 21));
      final preservedTag = await state.saveTag(name: 'preserved');
      final omittedTask = await state.addWorkItemToProject(
        'omitted',
        'Original omitted task',
        tagIds: [preservedTag],
      );
      final omitted = await service.proposeTaskUpdate(
        projectId: 'omitted',
        workItemId: omittedTask,
        title: 'Updated omitted task',
      );
      expect(omitted.payload['tagNamesSpecified'], isFalse);
      expect(omitted.payload.containsKey('tagNames'), isFalse);

      await service.approveAgentProposal(omitted.draftId!);

      expect(
        (await db.getTagsForWorkItem(omittedTask)).map((tag) => tag.name),
        ['preserved'],
      );

      await db.createProject('empty', 'Empty', DateTime(2026, 7, 21));
      final clearedTag = await state.saveTag(name: 'to-clear');
      final emptyTask = await state.addWorkItemToProject(
        'empty',
        'Original empty task',
        tagIds: [clearedTag],
      );
      final empty = await service.proposeTaskUpdate(
        projectId: 'empty',
        workItemId: emptyTask,
        title: 'Updated empty task',
        tagNames: const [],
      );
      expect(empty.payload['tagNamesSpecified'], isTrue);
      expect(empty.payload['tagNames'], isEmpty);

      await service.approveAgentProposal(empty.draftId!);

      expect(await db.getTagsForWorkItem(emptyTask), isEmpty);
    });

    test(
      'empty task tag replacement rolls back and retries atomically',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final oldTag = await state.saveTag(name: 'old');
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original task',
          tagIds: [oldTag],
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Cleared task',
          tagNames: const [],
        );
        final crashing = AtlasAgentService(
          state,
          proposalApprovalStepHook: (step) async {
            if (step == 'after-task-tags-write') {
              throw StateError('empty task tag write crash');
            }
          },
        );

        await expectLater(
          crashing.approveAgentProposal(proposal.draftId!),
          throwsA(isA<StateError>()),
        );
        expect((await db.getWorkItem(workItemId))!.title, 'Original task');
        expect(
          (await db.getTagsForWorkItem(workItemId)).map((tag) => tag.name),
          ['old'],
        );
        expect(
          (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
          isTrue,
        );

        await service.approveAgentProposal(proposal.draftId!);
        expect((await db.getWorkItem(workItemId))!.title, 'Cleared task');
        expect(await db.getTagsForWorkItem(workItemId), isEmpty);
      },
    );

    test(
      'legacy marker-absent task tag payloads retain old semantics',
      () async {
        Future<void> removeIntentMarker(String draftId) async {
          final draft = await state.getDraft(draftId);
          final envelope =
              jsonDecode(draft!.inputJson!) as Map<String, Object?>;
          final payload = Map<String, Object?>.from(envelope['payload']! as Map)
            ..remove('tagNamesSpecified');
          envelope['payload'] = payload;
          await state.updateDraftReview(
            id: draft.id,
            accepted: false,
            inputJson: jsonEncode(envelope),
          );
        }

        await db.createProject(
          'legacy-empty',
          'Legacy empty',
          DateTime(2026, 7, 21),
        );
        final preservedTag = await state.saveTag(name: 'legacy-preserved');
        final emptyTask = await state.addWorkItemToProject(
          'legacy-empty',
          'Legacy empty task',
          tagIds: [preservedTag],
        );
        final empty = await service.proposeTaskUpdate(
          projectId: 'legacy-empty',
          workItemId: emptyTask,
          title: 'Legacy empty updated',
          tagNames: const [],
        );
        await removeIntentMarker(empty.draftId!);
        await service.approveAgentProposal(empty.draftId!);
        expect(
          (await db.getTagsForWorkItem(emptyTask)).map((tag) => tag.name),
          ['legacy-preserved'],
        );

        await db.createProject(
          'legacy-nonempty',
          'Legacy nonempty',
          DateTime(2026, 7, 21),
        );
        final replacedTag = await state.saveTag(name: 'legacy-old');
        final nonemptyTask = await state.addWorkItemToProject(
          'legacy-nonempty',
          'Legacy nonempty task',
          tagIds: [replacedTag],
        );
        final nonempty = await service.proposeTaskUpdate(
          projectId: 'legacy-nonempty',
          workItemId: nonemptyTask,
          title: 'Legacy nonempty updated',
          tagNames: const ['legacy-new'],
        );
        await removeIntentMarker(nonempty.draftId!);
        await service.approveAgentProposal(nonempty.draftId!);
        expect(
          (await db.getTagsForWorkItem(nonemptyTask)).map((tag) => tag.name),
          ['legacy-new'],
        );
      },
    );

    test('tampered task tag intent fails closed and remains pending', () async {
      final cases = <String, void Function(Map<String, Object?>)>{
        'null-marker': (payload) => payload['tagNamesSpecified'] = null,
        'scalar-marker': (payload) => payload['tagNamesSpecified'] = 'true',
        'false-with-tags': (payload) => payload['tagNamesSpecified'] = false,
        'true-without-tags': (payload) => payload.remove('tagNames'),
        'scalar-tags': (payload) => payload['tagNames'] = 'tampered-tag',
        'legacy-null-tags': (payload) {
          payload.remove('tagNamesSpecified');
          payload['tagNames'] = null;
        },
        'legacy-scalar-tags': (payload) {
          payload.remove('tagNamesSpecified');
          payload['tagNames'] = 'tampered-tag';
        },
        'legacy-mixed-tags': (payload) {
          payload.remove('tagNamesSpecified');
          payload['tagNames'] = <Object?>['tampered-tag', 7];
        },
        'legacy-blank-tags': (payload) {
          payload.remove('tagNamesSpecified');
          payload['tagNames'] = <String>[''];
        },
      };

      for (final entry in cases.entries) {
        final projectId = 'tamper-${entry.key}';
        await db.createProject(projectId, projectId, DateTime(2026, 7, 21));
        final oldTag = await state.saveTag(name: 'old-${entry.key}');
        final workItemId = await state.addWorkItemToProject(
          projectId,
          'Original ${entry.key}',
          tagIds: [oldTag],
        );
        final proposed = await service.proposeTaskUpdate(
          projectId: projectId,
          workItemId: workItemId,
          title: 'Must not apply ${entry.key}',
          tagNames: const ['tampered-tag'],
        );
        final draft = await state.getDraft(proposed.draftId!);
        final envelope = jsonDecode(draft!.inputJson!) as Map<String, Object?>;
        final payload = Map<String, Object?>.from(envelope['payload']! as Map);
        entry.value(payload);
        envelope['payload'] = payload;
        await state.updateDraftReview(
          id: draft.id,
          accepted: false,
          inputJson: jsonEncode(envelope),
        );

        await expectLater(
          service.approveAgentProposal(draft.id),
          throwsA(isA<StateError>()),
          reason: entry.key,
        );
        expect(
          (await service.getAgentProposalReview(draft.id))!.isPending,
          isTrue,
          reason: entry.key,
        );
        expect(
          (await db.getWorkItem(workItemId))!.title,
          'Original ${entry.key}',
          reason: entry.key,
        );
        expect(
          (await db.getTagsForWorkItem(workItemId)).map((tag) => tag.name),
          ['old-${entry.key}'],
          reason: entry.key,
        );
        expect(await db.findTagByName('tampered-tag'), isNull);
      }
    });

    test('deleted task fails closed before creating proposal tags', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final workItemId = await state.addWorkItemToProject('atlas', 'Original');
      final proposal = await service.proposeTaskUpdate(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Must not apply',
        tagNames: const ['orphan-risk'],
      );
      await db.customStatement('DELETE FROM work_items WHERE id = ?', [
        workItemId,
      ]);

      await expectLater(
        service.approveAgentProposal(proposal.draftId!),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.taskNotFound,
          ),
        ),
      );
      expect(await db.findTagByName('orphan-risk'), isNull);
      expect(await db.getTagsForWorkItem(workItemId), isEmpty);
      expect(
        (await service.getAgentProposalReview(proposal.draftId!))!.isPending,
        true,
      );
    });

    test(
      'task moved to another project fails with typed ownership conflict',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        await db.createProject('other', 'Other', DateTime(2026, 7, 21));
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original',
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Must not cross projects',
        );
        final otherStage = (await db.getStagesForProject('other')).first;
        await db.customStatement(
          'UPDATE work_items SET stage_id = ? WHERE id = ?',
          [otherStage.id, workItemId],
        );

        await expectLater(
          service.approveAgentProposal(proposal.draftId!),
          throwsA(
            isA<AtlasProposalConflict>().having(
              (error) => error.reason,
              'reason',
              AtlasProposalConflictReason.wrongProject,
            ),
          ),
        );
        expect((await db.getWorkItem(workItemId))!.title, 'Original');
      },
    );

    test('legacy task proposal without a base snapshot fails closed', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final workItemId = await state.addWorkItemToProject('atlas', 'Original');
      final proposed = await service.proposeTaskUpdate(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Legacy update',
      );
      final draft = await state.getDraft(proposed.draftId!);
      final envelope = jsonDecode(draft!.inputJson!) as Map<String, Object?>;
      final payload = Map<String, Object?>.from(envelope['payload']! as Map)
        ..remove('baseTaskSnapshot');
      envelope['payload'] = payload;
      await state.updateDraftReview(
        id: draft.id,
        accepted: false,
        inputJson: jsonEncode(envelope),
      );

      await expectLater(
        service.approveAgentProposal(draft.id),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.missingBaseSnapshot,
          ),
        ),
      );
      expect((await db.getWorkItem(workItemId))!.title, 'Original');
      expect((await service.getAgentProposalReview(draft.id))!.isPending, true);
    });

    test('malformed task snapshot digests fail closed', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final workItemId = await state.addWorkItemToProject('atlas', 'Original');
      final proposed = await service.proposeTaskUpdate(
        projectId: 'atlas',
        workItemId: workItemId,
        title: 'Malformed update',
      );
      final draft = await state.getDraft(proposed.draftId!);
      final envelope = jsonDecode(draft!.inputJson!) as Map<String, Object?>;
      final payload = Map<String, Object?>.from(envelope['payload']! as Map);
      final base = Map<String, Object?>.from(
        payload['baseTaskSnapshot']! as Map,
      )..['taskHash'] = 'not-a-sha256';
      payload['baseTaskSnapshot'] = base;
      envelope['payload'] = payload;
      await state.updateDraftReview(
        id: draft.id,
        accepted: false,
        inputJson: jsonEncode(envelope),
      );

      await expectLater(
        service.approveAgentProposal(draft.id),
        throwsA(
          isA<AtlasProposalConflict>().having(
            (error) => error.reason,
            'reason',
            AtlasProposalConflictReason.missingBaseSnapshot,
          ),
        ),
      );
      expect((await db.getWorkItem(workItemId))!.title, 'Original');
    });

    test(
      'tag order and case normalization keep the base snapshot current',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final tagA = await state.saveTag(name: 'Alpha');
        final tagB = await state.saveTag(name: 'Beta');
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original',
          tagIds: [tagA, tagB],
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Applied',
        );
        await state.setWorkItemTags(workItemId, [tagB, tagA]);
        await db.updateTag(tagA, name: 'ALPHA');

        final result = await service.approveAgentProposal(proposal.draftId!);

        expect(result.entityId, workItemId);
        expect((await db.getWorkItem(workItemId))!.title, 'Applied');
      },
    );

    test(
      'assigned tag metadata changes stale the exact tag snapshot',
      () async {
        await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
        final tag = await state.saveTag(name: 'Alpha', color: '#111111');
        final workItemId = await state.addWorkItemToProject(
          'atlas',
          'Original',
          tagIds: [tag],
        );
        final proposal = await service.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Must not apply',
        );
        await db.updateTag(tag, color: '#222222');

        await expectLater(
          service.approveAgentProposal(proposal.draftId!),
          throwsA(
            isA<AtlasProposalConflict>().having(
              (error) => error.reason,
              'reason',
              AtlasProposalConflictReason.staleTagSet,
            ),
          ),
        );
        expect((await db.getWorkItem(workItemId))!.title, 'Original');
      },
    );

    test('MCP captures the existing-task base snapshot server-side', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final workItemId = await state.addWorkItemToProject('atlas', 'Original');
      final adapter = AtlasMcpAdapter(service);

      final result = await adapter.callTool('propose_task_update', {
        'projectId': 'atlas',
        'workItemId': workItemId,
        'title': 'Proposed',
        'baseTaskSnapshot': {'taskHash': 'forged'},
      });
      final proposal = result.data! as Map;
      final base = (proposal['payload'] as Map)['baseTaskSnapshot'] as Map;

      expect(result.isError, isFalse);
      expect(base['schema'], 'atlas.task_proposal_base.v1');
      expect(base['taskHash'], isNot('forged'));
      expect(base['tagSetHash'], hasLength(64));
      final listed = await adapter.callTool('list_agent_proposals');
      final listedBase =
          ((((listed.data! as List).single as Map)['payload']
                  as Map)['baseTaskSnapshot']
              as Map);
      expect(listedBase, equals(base));
    });

    test('MCP preserves absent versus explicitly empty task tags', () async {
      final adapter = AtlasMcpAdapter(service);

      await db.createProject('mcp-absent', 'MCP absent', DateTime(2026, 7, 21));
      final preservedTag = await state.saveTag(name: 'mcp-preserved');
      final absentTask = await state.addWorkItemToProject(
        'mcp-absent',
        'Absent task',
        tagIds: [preservedTag],
      );
      final absentResult = await adapter.callTool('propose_task_update', {
        'projectId': 'mcp-absent',
        'workItemId': absentTask,
        'title': 'Absent updated',
      });
      final absent = absentResult.data! as Map;
      final absentPayload = absent['payload'] as Map;
      expect(absentPayload['tagNamesSpecified'], isFalse);
      expect(absentPayload.containsKey('tagNames'), isFalse);
      await service.approveAgentProposal(absent['draftId']! as String);
      expect((await db.getTagsForWorkItem(absentTask)).map((tag) => tag.name), [
        'mcp-preserved',
      ]);

      await db.createProject('mcp-empty', 'MCP empty', DateTime(2026, 7, 21));
      final clearedTag = await state.saveTag(name: 'mcp-cleared');
      final emptyTask = await state.addWorkItemToProject(
        'mcp-empty',
        'Empty task',
        tagIds: [clearedTag],
      );
      final emptyResult = await adapter.callTool('propose_task_update', {
        'projectId': 'mcp-empty',
        'workItemId': emptyTask,
        'title': 'Empty updated',
        'tagNames': <String>[],
      });
      final empty = emptyResult.data! as Map;
      final emptyPayload = empty['payload'] as Map;
      expect(emptyPayload['tagNamesSpecified'], isTrue);
      expect(emptyPayload['tagNames'], isEmpty);
      await service.approveAgentProposal(empty['draftId']! as String);
      expect(await db.getTagsForWorkItem(emptyTask), isEmpty);
    });

    test('MCP rejects malformed present task tags without a draft', () async {
      await db.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
      final adapter = AtlasMcpAdapter(service);
      final invalidValues = <Object?>[
        null,
        'single-tag',
        <Object?>['valid', 7],
        <String>[''],
      ];

      for (final value in invalidValues) {
        final result = await adapter.callTool('propose_task_update', {
          'projectId': 'atlas',
          'title': 'Must not create a draft',
          'tagNames': value,
        });
        expect(result.isError, isTrue, reason: '$value');
        expect(result.data, isA<Map>(), reason: '$value');
        expect((result.data! as Map)['error'], contains('tagNames'));
      }

      final listed = await adapter.callTool('list_agent_proposals');
      expect(listed.isError, isFalse);
      expect(listed.data, isEmpty);
    });
  });

  _contentionTest(
    'two database connections apply one proposal exactly once',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'atlas_proposal_integrity_',
      );
      final file = File(p.join(tempDir.path, 'proposal.sqlite'));
      await _initializeProposalDb(file);
      final dbA = _openProposalDb(file);
      final dbB = _openProposalDb(file);
      final stateA = AppState(dbA, enableBackgroundSummaryRefresh: false);
      final stateB = AppState(dbB, enableBackgroundSummaryRefresh: false);
      try {
        final serviceA = AtlasAgentService(stateA);
        final serviceB = AtlasAgentService(stateB);
        final proposal = await serviceA.proposeTaskUpdate(
          projectId: 'atlas',
          title: 'Contended proposal task',
        );
        final start = Completer<void>();

        Future<AtlasProposalApplyResult> approve(
          AtlasAgentService service,
        ) async {
          await start.future;
          return service.approveAgentProposal(proposal.draftId!);
        }

        final approvals = [approve(serviceA), approve(serviceB)];
        start.complete();
        final results = await Future.wait(approvals);

        expect(results.map((result) => result.entityId).toSet(), hasLength(1));
        expect(await dbA.getWorkItemsForProject('atlas'), hasLength(1));
        expect(
          (await dbA.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          hasLength(1),
        );
      } finally {
        stateA.dispose();
        stateB.dispose();
        await Future.wait([dbA.close(), dbB.close()]);
        await tempDir.delete(recursive: true);
      }
    },
  );

  _contentionTest(
    'same-base task proposals have one concurrent CAS winner',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'atlas_task_proposal_cas_',
      );
      final file = File(p.join(tempDir.path, 'proposal.sqlite'));
      await _initializeProposalDb(file);
      final dbA = _openProposalDb(file);
      final dbB = _openProposalDb(file);
      final stateA = AppState(dbA, enableBackgroundSummaryRefresh: false);
      final stateB = AppState(dbB, enableBackgroundSummaryRefresh: false);
      try {
        final serviceA = AtlasAgentService(stateA);
        final serviceB = AtlasAgentService(stateB);
        final workItemId = await stateA.addWorkItemToProject(
          'atlas',
          'Shared base task',
        );
        final proposalA = await serviceA.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Winner A',
          tagNames: const ['tag-a'],
        );
        final proposalB = await serviceB.proposeTaskUpdate(
          projectId: 'atlas',
          workItemId: workItemId,
          title: 'Winner B',
          tagNames: const ['tag-b'],
        );
        final start = Completer<void>();

        Future<Object> capture(
          AtlasAgentService service,
          String draftId,
        ) async {
          await start.future;
          try {
            return await service.approveAgentProposal(draftId);
          } catch (error) {
            return error;
          }
        }

        final attempts = [
          capture(serviceA, proposalA.draftId!),
          capture(serviceB, proposalB.draftId!),
        ];
        start.complete();
        final outcomes = await Future.wait(attempts);
        final winners = outcomes.whereType<AtlasProposalApplyResult>().toList();
        final conflicts = outcomes.whereType<AtlasProposalConflict>().toList();

        expect(winners, hasLength(1));
        expect(conflicts, hasLength(1));
        expect(conflicts.single.reason, AtlasProposalConflictReason.staleTask);
        final item = await dbA.getWorkItem(workItemId);
        final winningA = item!.title == 'Winner A';
        expect(item.title, anyOf('Winner A', 'Winner B'));
        expect(
          (await dbA.getTagsForWorkItem(workItemId)).map((tag) => tag.name),
          [winningA ? 'tag-a' : 'tag-b'],
        );
        final losingDraftId = winningA
            ? proposalB.draftId!
            : proposalA.draftId!;
        expect(
          (await serviceA.getAgentProposalReview(losingDraftId))!.isPending,
          true,
        );
        expect(
          (await dbA.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          hasLength(1),
        );
      } finally {
        stateA.dispose();
        stateB.dispose();
        await Future.wait([dbA.close(), dbB.close()]);
        await tempDir.delete(recursive: true);
      }
    },
  );

  _contentionTest(
    'same-base manifest tag proposals have one concurrent winner',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'atlas_manifest_proposal_cas_',
      );
      final file = File(p.join(tempDir.path, 'proposal.sqlite'));
      await _initializeProposalDb(file);

      final dbA = _openProposalDb(file);
      final dbB = _openProposalDb(file);
      final stateA = AppState(dbA, enableBackgroundSummaryRefresh: false);
      final stateB = AppState(dbB, enableBackgroundSummaryRefresh: false);
      try {
        final serviceA = AtlasAgentService(stateA);
        final serviceB = AtlasAgentService(stateB);
        final proposalA = await serviceA.proposeManifestUpdate(
          projectId: 'atlas',
          fields: const {
            'tags': ['winner-a'],
          },
        );
        final proposalB = await serviceB.proposeManifestUpdate(
          projectId: 'atlas',
          fields: const {
            'tags': ['winner-b'],
          },
        );
        final start = Completer<void>();

        Future<Object> capture(
          AtlasAgentService service,
          String draftId,
        ) async {
          await start.future;
          try {
            return await service.approveAgentProposal(draftId);
          } catch (error) {
            return error;
          }
        }

        final attempts = [
          capture(serviceA, proposalA.draftId!),
          capture(serviceB, proposalB.draftId!),
        ];
        start.complete();
        final outcomes = await Future.wait(attempts);
        final winners = outcomes.whereType<AtlasProposalApplyResult>().toList();
        final conflicts = outcomes.whereType<AtlasProposalConflict>().toList();

        expect(winners, hasLength(1));
        expect(conflicts, hasLength(1));
        expect(
          conflicts.single.reason,
          AtlasProposalConflictReason.staleProjectTagSet,
        );
        final winningA = winners.single.draftId == proposalA.draftId;
        expect((await dbA.getTagsForProject('atlas')).map((tag) => tag.name), [
          winningA ? 'winner-a' : 'winner-b',
        ]);
        expect(
          await dbA.findTagByName(winningA ? 'winner-b' : 'winner-a'),
          isNull,
        );
        final losingDraft = winningA ? proposalB.draftId! : proposalA.draftId!;
        expect(
          (await serviceA.getAgentProposalReview(losingDraft))!.isPending,
          isTrue,
        );
        expect(await stateA.getProjectCapsuleRevisions('atlas'), hasLength(1));
        expect(
          (await dbA.getRecentEvents()).where(
            (event) => event.action == 'proposal_approved',
          ),
          hasLength(1),
        );
      } finally {
        stateA.dispose();
        stateB.dispose();
        await Future.wait([dbA.close(), dbB.close()]);
        await tempDir.delete(recursive: true);
      }
    },
  );

  _contentionTest(
    'approve and reject race has one handoff terminal winner',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'atlas_proposal_review_race_',
      );
      final file = File(p.join(tempDir.path, 'proposal.sqlite'));
      await _initializeProposalDb(file);
      final dbA = _openProposalDb(file);
      final dbB = _openProposalDb(file);
      final stateA = AppState(dbA, enableBackgroundSummaryRefresh: false);
      final stateB = AppState(dbB, enableBackgroundSummaryRefresh: false);
      try {
        final serviceA = AtlasAgentService(stateA);
        final serviceB = AtlasAgentService(stateB);
        final proposal = await serviceA.recordHandoff(
          projectId: 'atlas',
          title: 'Contended handoff',
          body: 'Only one review transition may win.',
        );
        final start = Completer<void>();

        Future<Object> capture(
          Future<AtlasProposalApplyResult> Function() run,
        ) async {
          await start.future;
          try {
            return await run();
          } catch (error) {
            return error;
          }
        }

        final attempts = [
          capture(() => serviceA.approveAgentProposal(proposal.draftId!)),
          capture(() => serviceB.rejectAgentProposal(proposal.draftId!)),
        ];
        start.complete();
        final outcomes = await Future.wait(attempts);
        final winners = outcomes.whereType<AtlasProposalApplyResult>().toList();

        expect(winners, hasLength(1));
        expect(outcomes.whereType<AtlasProposalConflict>(), hasLength(1));
        final review = await serviceA.getAgentProposalReview(proposal.draftId!);
        expect(review!.isApproved || review.isRejected, true);
        expect(review.reviewStatus, winners.single.reviewStatus);
        final handoffs = (await stateA.getDrafts())
            .where((draft) => draft.kind == AtlasAgentService.handoffDraftKind)
            .toList();
        expect(handoffs, hasLength(review.isApproved ? 1 : 0));
        expect(
          (await dbA.getRecentEvents()).where(
            (event) =>
                event.action == 'proposal_approved' ||
                event.action == 'proposal_rejected',
          ),
          hasLength(1),
        );
        expect(review.reviewStatus, isNot('applying'));
      } finally {
        stateA.dispose();
        stateB.dispose();
        await Future.wait([dbA.close(), dbB.close()]);
        await tempDir.delete(recursive: true);
      }
    },
  );
}

void _contentionTest(String description, Future<void> Function() body) {
  // Two background SQLite connections may legitimately serialize near their
  // 30-second busy timeout when the full Windows suite is saturated.
  test(description, body, timeout: const Timeout(Duration(minutes: 2)));
}

Future<void> _initializeProposalDb(File file) async {
  final initializer = _openProposalDb(file);
  try {
    await initializer.customSelect('SELECT 1').get();
    await initializer.createProject('atlas', 'Atlas', DateTime(2026, 7, 21));
  } finally {
    await initializer.close();
  }
}

AppDb _openProposalDb(File file) => AppDb.withExecutor(
  NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      rawDb.execute('PRAGMA busy_timeout = 30000;');
      rawDb.execute('PRAGMA foreign_keys = ON;');
    },
  ),
);
