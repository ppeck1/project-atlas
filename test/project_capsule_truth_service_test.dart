import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
import 'package:project_atlas/shared/models/project_capsule_truth.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  Future<void> disableLedgerGuards(AppDb db) async {
    await db.customStatement(
      'DROP TRIGGER guard_project_capsule_revisions_update',
    );
    await db.customStatement(
      'DROP TRIGGER guard_project_capsule_revisions_delete',
    );
  }

  group('ProjectCapsuleTruth', () {
    test('normalizes authored text before canonical hashing', () {
      final first = ProjectCapsuleTruth.fromJson({
        'title': ' Atlas ',
        'status': 'active',
        'description': 'Line one\r\nLine two\r\n',
      });
      final second = ProjectCapsuleTruth.fromJson({
        'description': 'Line one\nLine two',
        'status': 'active',
        'title': 'Atlas',
      });

      expect(first.toJson(), second.toJson());
      expect(first.contentHash, second.contentHash);
      expect(first.contentHash, hasLength(64));
    });

    test('keeps registry filesystem paths out of authored truth', () {
      final truth = ProjectCapsuleTruth.fromProjectMap({
        'title': 'Atlas',
        'status': 'active',
        'description':
            'Imported from the Local Operations Registry.\n'
            'Local path: C:\\private\\atlas\n'
            'Classification: software\n'
            'Git root: C:\\private\\atlas',
        'scopeIncluded': 'Local project root: C:\\private\\atlas',
      });

      expect(truth.description, contains('Classification: software'));
      expect(truth.description, isNot(contains('C:\\private\\atlas')));
      expect(truth.scopeIncluded, isNull);
    });
  });

  group('ProjectCapsuleTruthService', () {
    late AppDb db;
    late ProjectCapsuleTruthService service;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      service = ProjectCapsuleTruthService(
        db,
        now: () => DateTime.utc(2026, 7, 18, 12),
      );
    });

    tearDown(() => db.close());

    test('new projects begin with one matching accepted revision', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));

      final state = (await service.load('atlas'))!;
      final revisions = await service.listRevisions('atlas');

      expect(state.headMatchesCurrent, isTrue);
      expect(state.revisionNumber, 1);
      expect(state.revisionCount, 1);
      expect(state.revisionId, revisions.single.id);
      expect(revisions.single.sourceKind, 'project_created');
      expect(revisions.single.truth.title, 'Project Atlas');
    });

    test(
      'accepted edit updates current truth and appends one revision',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final before = (await service.load('atlas'))!;

        final result = await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: before.revisionId,
          actorLabel: 'Paul',
          sourceKind: 'capsule_editor',
          reason: 'Clarify the project outcome.',
          fields: const {
            'desiredOutcome': 'Resume and delegate without reconstruction.',
            'phase': 'build',
            'priority': 'high',
          },
        );
        final project = await db.getProjectFull('atlas');
        final revisions = await service.listRevisions('atlas');

        expect(result.changed, isTrue);
        expect(result.revision!.revisionNumber, 2);
        expect(result.revision!.parentRevisionId, before.revisionId);
        expect(result.revision!.actorLabel, 'Paul');
        expect(result.changedFields.keys, {
          'phase',
          'priority',
          'desiredOutcome',
        });
        expect(
          project!.desiredOutcome,
          'Resume and delegate without reconstruction.',
        );
        expect(revisions, hasLength(2));
        expect(revisions.first.contentHash, result.state.truth.contentHash);
      },
    );

    test('no-op accepted saves do not create revisions', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final before = (await service.load('atlas'))!;

      final result = await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: before.revisionId,
        fields: const {'title': '  Project Atlas  '},
      );

      expect(result.changed, isFalse);
      expect(await service.listRevisions('atlas'), hasLength(1));
    });

    test('history pages disclose their bounded window and ordering', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      var revisionId = (await service.load('atlas'))!.revisionId;
      for (var index = 1; index <= 75; index++) {
        final accepted = await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: revisionId,
          fields: {'description': 'Accepted change $index.'},
        );
        revisionId = accepted.state.revisionId;
      }

      final firstPage = await service.listRevisions('atlas');
      final secondPage = await service.listRevisions('atlas', offset: 50);

      expect(firstPage, hasLength(50));
      expect(firstPage.first.revisionNumber, 76);
      expect(firstPage.last.revisionNumber, 27);
      expect(secondPage, hasLength(26));
      expect(secondPage.first.revisionNumber, 26);
      expect(secondPage.last.revisionNumber, 1);
    });

    test('stale edits cannot overwrite newer accepted truth', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final staleBase = (await service.load('atlas'))!.revisionId;
      await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: staleBase,
        fields: const {'desiredOutcome': 'Newer accepted outcome.'},
      );

      await expectLater(
        service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: staleBase,
          fields: const {'desiredOutcome': 'Stale overwrite.'},
        ),
        throwsA(isA<ProjectCapsuleTruthConflict>()),
      );
      final project = await db.getProjectFull('atlas');

      expect(project!.desiredOutcome, 'Newer accepted outcome.');
      expect(await service.listRevisions('atlas'), hasLength(2));
    });

    test('invalid authored values leave truth unchanged', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final before = (await service.load('atlas'))!;

      await expectLater(
        service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: before.revisionId,
          fields: const {'title': '   '},
        ),
        throwsA(isA<ProjectCapsuleTruthValidationException>()),
      );

      expect((await db.getProjectFull('atlas'))!.title, 'Project Atlas');
      expect(await service.listRevisions('atlas'), hasLength(1));
    });

    test(
      'non-truth, unknown, and mixed patches are rejected atomically',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final before = (await service.load('atlas'))!;
        final rejectedPatches = <Map<String, Object?>>[
          const {'lessonsLearned': 'Supplemental metadata only.'},
          const {'desiredOutcomeTypo': 'Unknown fields must fail closed.'},
          const {
            'description': 'This truth change must roll back.',
            'lessonsLearned': 'Mixed writes must not partially commit.',
          },
        ];

        for (final patch in rejectedPatches) {
          await expectLater(
            service.acceptPatch(
              projectId: 'atlas',
              expectedRevisionId: before.revisionId,
              fields: patch,
              recordProjectMetadataAudit: true,
            ),
            throwsA(isA<ProjectCapsuleTruthValidationException>()),
          );

          final project = (await db.getProjectFull('atlas'))!;
          final state = (await service.load('atlas'))!;
          expect(project.description, isNull);
          expect(project.lessonsLearned, isNull);
          expect(state.revisionId, before.revisionId);
          expect(await service.listRevisions('atlas'), hasLength(1));
        }
      },
    );

    test(
      'unknown status values fail closed instead of becoming active',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final initial = (await service.load('atlas'))!;
        await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: initial.revisionId,
          fields: const {'status': 'blocked'},
        );
        final blocked = (await service.load('atlas'))!;

        await expectLater(
          service.acceptPatch(
            projectId: 'atlas',
            expectedRevisionId: blocked.revisionId,
            fields: const {'status': 'erase_everything'},
          ),
          throwsA(isA<ProjectCapsuleTruthValidationException>()),
        );

        expect((await db.getProjectFull('atlas'))!.status, 'blocked');
        expect(await service.listRevisions('atlas'), hasLength(2));
      },
    );

    test(
      'legacy phase values require explicit normalization before saving',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        await db.updateProjectMeta('atlas', {'phase': 'reference'});
        final before = (await service.load('atlas'))!;

        await expectLater(
          service.acceptPatch(
            projectId: 'atlas',
            expectedRevisionId: before.revisionId,
            fields: const {'desiredOutcome': 'Clarify the project outcome.'},
          ),
          throwsA(isA<ProjectCapsuleTruthValidationException>()),
        );

        final project = await db.getProjectFull('atlas');
        expect(project!.phase, 'reference');
        expect(project.desiredOutcome, isNull);
      },
    );

    test('accepted source IDs recover a partially reviewed proposal', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final base = (await service.load('atlas'))!;
      final first = await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: base.revisionId,
        fields: const {'status': 'blocked'},
        actorLabel: 'Atlas Agent',
        sourceKind: 'agent_proposal',
        sourceId: 'draft-1',
      );

      final recovered = await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: base.revisionId,
        fields: const {'status': 'blocked'},
        actorLabel: 'Atlas Agent',
        sourceKind: 'agent_proposal',
        sourceId: 'draft-1',
      );

      expect(recovered.changed, isFalse);
      expect(recovered.revision?.id, first.revision?.id);
      expect(await service.listRevisions('atlas'), hasLength(2));
    });

    test(
      'source lookup returns null when the verified chain has no match',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));

        final found = await service.findAcceptedRevisionBySource(
          projectId: 'atlas',
          sourceKind: 'agent_proposal',
          sourceId: 'missing-proposal',
        );

        expect(found, isNull);
        expect(await service.listRevisions('atlas'), hasLength(1));
      },
    );

    test(
      'source lookup rejects corruption in a nonmatching ancestor',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final initial = (await service.load('atlas'))!;
        final middle = await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: initial.revisionId,
          fields: const {'description': 'Accepted middle revision.'},
          sourceKind: 'manual_edit',
          sourceId: 'unrelated-source',
        );
        await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: middle.state.revisionId,
          fields: const {'desiredOutcome': 'Accepted target revision.'},
          sourceKind: 'agent_proposal',
          sourceId: 'target-proposal',
        );
        await disableLedgerGuards(db);
        await db.customStatement(
          "UPDATE project_capsule_revisions SET changed_fields_json = "
          "'{\"description\":{\"before\":null,\"after\":\"Forged\"}}' "
          "WHERE project_id = 'atlas' AND revision_number = 2",
        );
        await db.customStatement(
          "UPDATE project_capsule_ledger_checkpoints SET dirty = 0 "
          "WHERE project_id = 'atlas'",
        );

        await expectLater(
          service.findAcceptedRevisionBySource(
            projectId: 'atlas',
            sourceKind: 'agent_proposal',
            sourceId: 'target-proposal',
          ),
          throwsA(isA<ProjectCapsuleTruthLedgerException>()),
        );
      },
    );

    test('accepted writes atomically advance the durable checkpoint', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final initial = (await service.load('atlas'))!;
      final accepted = await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: initial.revisionId,
        fields: const {'description': 'Checkpointed change.'},
      );

      final checkpoint = await (db.select(
        db.projectCapsuleLedgerCheckpoints,
      )..where((table) => table.projectId.equals('atlas'))).getSingle();
      expect(checkpoint.dirty, isFalse);
      expect(checkpoint.headRevisionId, accepted.state.revisionId);
      expect(checkpoint.headRevisionNumber, 2);
      expect(checkpoint.revisionCount, 2);
      expect(await service.auditLedger('atlas'), 2);
    });

    test(
      'revision corruption dirties the checkpoint and fails closed',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        await disableLedgerGuards(db);
        await db.customStatement(
          "UPDATE project_capsule_revisions SET actor_label = 'Forged' "
          "WHERE project_id = 'atlas'",
        );

        for (final read in <Future<Object?> Function()>[
          () => service.load('atlas'),
          () => service.listRevisions('atlas'),
          () => service.findAcceptedRevisionBySource(
            projectId: 'atlas',
            sourceKind: 'agent_proposal',
            sourceId: 'missing',
          ),
          () => service.auditLedger('atlas'),
        ]) {
          await expectLater(
            read(),
            throwsA(isA<ProjectCapsuleTruthLedgerException>()),
          );
        }
      },
    );

    test('a valid raw append cannot become accepted source evidence', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final baseline = (await db
          .select(db.projectCapsuleRevisions)
          .getSingle());
      await db
          .into(db.projectCapsuleRevisions)
          .insert(
            ProjectCapsuleRevisionRow(
              id: 'forged-source-revision',
              projectId: 'atlas',
              revisionNumber: 2,
              parentRevisionId: baseline.id,
              contentHash: baseline.contentHash,
              truthJson: baseline.truthJson,
              changedFieldsJson: '{}',
              actorType: 'ai_model',
              actorLabel: 'Forged agent',
              sourceKind: 'agent_proposal',
              sourceId: 'forged-proposal',
              reason: null,
              acceptedAt: DateTime.utc(2026, 1, 2),
            ),
          );

      await expectLater(
        service.findAcceptedRevisionBySource(
          projectId: 'atlas',
          sourceKind: 'agent_proposal',
          sourceId: 'forged-proposal',
        ),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );
    });

    test('explicit audit detects a forged clean checkpoint digest', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      await db.customStatement(
        "UPDATE project_capsule_ledger_checkpoints SET ledger_digest = "
        "'forged' WHERE project_id = 'atlas'",
      );

      expect((await service.load('atlas'))!.revisionNumber, 1);
      await expectLater(
        service.auditLedger('atlas'),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );
    });

    test('loads and history pages materialize bounded revision rows', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      var revisionId = (await service.load('atlas'))!.revisionId;
      for (var index = 1; index <= 80; index++) {
        revisionId = (await service.acceptPatch(
          projectId: 'atlas',
          expectedRevisionId: revisionId,
          fields: {'description': 'Bounded read revision $index.'},
        )).state.revisionId;
      }
      final reads = <(String, int)>[];
      final observed = ProjectCapsuleTruthService(
        db,
        revisionReadObserverForTesting: (operation, rows) {
          reads.add((operation, rows));
        },
      );

      for (var index = 0; index < 12; index++) {
        expect((await observed.load('atlas'))!.revisionNumber, 81);
      }
      expect(reads, List.filled(12, ('checkpoint_head', 1)));

      reads.clear();
      final page = await observed.listRevisions('atlas', limit: 7, offset: 40);
      expect(page.map((revision) => revision.revisionNumber), [
        41,
        40,
        39,
        38,
        37,
        36,
        35,
      ]);
      expect(reads, [('checkpoint_head', 1), ('history_page', 8)]);
    });

    test('full audit scans once before rejecting checkpoint defects', () async {
      final reads = <(String, int)>[];
      final observed = ProjectCapsuleTruthService(
        db,
        revisionReadObserverForTesting: (operation, rows) {
          reads.add((operation, rows));
        },
      );
      for (final projectId in ['dirty', 'missing', 'mismatch']) {
        await db.createProject(projectId, projectId, DateTime.utc(2026));
      }
      await db.customStatement(
        "UPDATE project_capsule_ledger_checkpoints SET dirty = 1 "
        "WHERE project_id = 'dirty'",
      );
      await db.customStatement(
        "DELETE FROM project_capsule_ledger_checkpoints "
        "WHERE project_id = 'missing'",
      );
      await db.customStatement(
        "UPDATE project_capsule_ledger_checkpoints SET head_revision_id = "
        "'wrong' WHERE project_id = 'mismatch'",
      );

      for (final projectId in ['dirty', 'missing', 'mismatch']) {
        reads.clear();
        await expectLater(
          observed.auditLedger(projectId),
          throwsA(isA<ProjectCapsuleTruthLedgerException>()),
        );
        expect(reads, [('full_chain', 1)], reason: projectId);
      }
    });

    test(
      'checkpoint and latest revision mismatch fails bounded reads',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        await db.customStatement(
          "UPDATE project_capsule_ledger_checkpoints SET head_revision_id = "
          "'wrong' WHERE project_id = 'atlas'",
        );

        await expectLater(
          service.load('atlas'),
          throwsA(isA<ProjectCapsuleTruthLedgerException>()),
        );
        await expectLater(
          service.listRevisions('atlas'),
          throwsA(isA<ProjectCapsuleTruthLedgerException>()),
        );
      },
    );

    test(
      'failed checkpoint advancement rolls back project and append',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final initial = (await service.load('atlas'))!;
        await db.customStatement(
          'DROP TRIGGER dirty_project_capsule_checkpoint_insert',
        );

        await expectLater(
          service.acceptPatch(
            projectId: 'atlas',
            expectedRevisionId: initial.revisionId,
            fields: const {'description': 'Must roll back.'},
          ),
          throwsA(isA<ProjectCapsuleTruthLedgerException>()),
        );
        expect((await db.getProjectFull('atlas'))!.description, isNull);
        expect(await db.select(db.projectCapsuleRevisions).get(), hasLength(1));
        final checkpoint = await db
            .select(db.projectCapsuleLedgerCheckpoints)
            .getSingle();
        expect(checkpoint.headRevisionId, initial.revisionId);
        expect(checkpoint.revisionCount, 1);
        expect(checkpoint.dirty, isFalse);
      },
    );

    test('database rejects ordinary revision mutation and deletion', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));

      await expectLater(
        db.customStatement(
          "UPDATE project_capsule_revisions SET actor_label = 'Changed' "
          "WHERE project_id = 'atlas'",
        ),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('capsule_revision_immutable:update'),
          ),
        ),
      );
      await expectLater(
        db.customStatement(
          "DELETE FROM project_capsule_revisions WHERE project_id = 'atlas'",
        ),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('capsule_revision_immutable:delete'),
          ),
        ),
      );
      expect(await service.listRevisions('atlas'), hasLength(1));
    });

    test('revision reads verify stored content hashes', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      await disableLedgerGuards(db);
      final corruptHash = List.filled(64, '0').join();
      await db.customStatement(
        "UPDATE project_capsule_revisions SET content_hash = '$corruptHash' "
        "WHERE project_id = 'atlas'",
      );

      await expectLater(
        service.listRevisions('atlas'),
        throwsA(isA<FormatException>()),
      );
    });

    test('ledger rejects malformed changed-fields JSON', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final state = (await service.load('atlas'))!;
      await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: state.revisionId,
        fields: const {'description': 'Recorded change.'},
      );
      await disableLedgerGuards(db);
      await db.customStatement(
        "UPDATE project_capsule_revisions SET changed_fields_json = '[]' "
        'WHERE project_id = \'atlas\' AND revision_number = 2',
      );

      await expectLater(
        service.listRevisions('atlas'),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );
    });

    test('ledger rejects broken parent links, numbers, and diffs', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final initial = (await service.load('atlas'))!;
      await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: initial.revisionId,
        fields: const {'description': 'Recorded change.'},
      );
      await disableLedgerGuards(db);
      await db.customStatement(
        "UPDATE project_capsule_revisions SET parent_revision_id = 'wrong' "
        'WHERE project_id = \'atlas\' AND revision_number = 2',
      );
      await expectLater(
        service.listRevisions('atlas'),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );

      await db.customStatement(
        "UPDATE project_capsule_revisions SET parent_revision_id = "
        "(SELECT id FROM project_capsule_revisions "
        "WHERE project_id = 'atlas' AND revision_number = 1) "
        'WHERE project_id = \'atlas\' AND revision_number = 2',
      );
      await db.customStatement(
        'UPDATE project_capsule_revisions SET revision_number = 3 '
        'WHERE project_id = \'atlas\' AND revision_number = 2',
      );
      await expectLater(
        service.listRevisions('atlas'),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );

      await db.customStatement(
        'UPDATE project_capsule_revisions SET revision_number = 2 '
        'WHERE project_id = \'atlas\' AND revision_number = 3',
      );
      await db.customStatement(
        "UPDATE project_capsule_revisions SET changed_fields_json = "
        "'{\"description\":{\"before\":null,\"after\":\"Wrong\"}}' "
        'WHERE project_id = \'atlas\' AND revision_number = 2',
      );
      await expectLater(
        service.listRevisions('atlas'),
        throwsA(isA<ProjectCapsuleTruthLedgerException>()),
      );
    });

    test(
      'existing project metadata edits use the same revision ledger',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        try {
          await state.updateProjectMeta('atlas', {
            'scopeIncluded': 'Shared accepted-truth service.',
          });
        } finally {
          state.dispose();
        }

        final revisions = await service.listRevisions('atlas');
        expect(revisions, hasLength(2));
        expect(revisions.first.sourceKind, 'project_detail');
        expect(revisions.first.changedFields.keys, contains('scopeIncluded'));
      },
    );

    test(
      'AppState routes mixed truth and supplemental metadata atomically',
      () async {
        await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
        final initial = (await service.load('atlas'))!;
        final state = AppState(db, enableBackgroundSummaryRefresh: false);
        try {
          await state.updateProjectMeta('atlas', const {
            'desiredOutcome': 'Accepted truth outcome.',
            'lessonsLearned': 'Supplemental operational note.',
          }, expectedTruthRevisionId: initial.revisionId);
        } finally {
          state.dispose();
        }

        final project = (await db.getProjectFull('atlas'))!;
        final revisions = await service.listRevisions('atlas');
        expect(project.desiredOutcome, 'Accepted truth outcome.');
        expect(project.lessonsLearned, 'Supplemental operational note.');
        expect(revisions, hasLength(2));
        expect(revisions.first.changedFields.keys, {'desiredOutcome'});
        expect(
          revisions.first.truth.toJson(),
          isNot(contains('lessonsLearned')),
        );
      },
    );

    test('AppState rolls back supplemental metadata on stale truth', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final staleBase = (await service.load('atlas'))!;
      await service.acceptPatch(
        projectId: 'atlas',
        expectedRevisionId: staleBase.revisionId,
        fields: const {'description': 'Newer accepted truth.'},
      );
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      try {
        await expectLater(
          state.updateProjectMeta('atlas', const {
            'desiredOutcome': 'Stale truth must not commit.',
            'lessonsLearned': 'Supplemental write must roll back.',
          }, expectedTruthRevisionId: staleBase.revisionId),
          throwsA(isA<ProjectCapsuleTruthConflict>()),
        );
      } finally {
        state.dispose();
      }

      final project = (await db.getProjectFull('atlas'))!;
      expect(project.description, 'Newer accepted truth.');
      expect(project.desiredOutcome, isNull);
      expect(project.lessonsLearned, isNull);
      expect(await service.listRevisions('atlas'), hasLength(2));
    });

    test('General Tasks repair records an accepted truth revision', () async {
      await db.createProject(
        AppDb.kGeneralTasksProjectId,
        'General Tasks',
        DateTime.utc(2026),
      );
      await db.updateProjectMeta(AppDb.kGeneralTasksProjectId, {
        'description': 'Legacy hidden project description.',
      });
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      try {
        await state.addGeneralWorkItem('Repair the General Tasks marker');
      } finally {
        state.dispose();
      }

      final truth = (await service.load(AppDb.kGeneralTasksProjectId))!;
      final revisions = await service.listRevisions(
        AppDb.kGeneralTasksProjectId,
      );
      expect(truth.headMatchesCurrent, isTrue);
      expect(revisions, hasLength(2));
      expect(revisions.first.sourceKind, 'general_tasks_repair');
      expect(
        revisions.first.changedFields['description']!.after,
        AppDb.kGeneralTasksProjectDescription,
      );
      expect(
        revisions.first.truth.description,
        AppDb.kGeneralTasksProjectDescription,
      );
    });

    test('operator deletion records the accepted lifecycle revision', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      try {
        await state.softDeleteProject('atlas', 'No longer in scope.');
      } finally {
        state.dispose();
      }

      final revisions = await service.listRevisions('atlas');
      expect((await db.getProjectFull('atlas'))!.status, 'deleted');
      expect(revisions, hasLength(2));
      expect(revisions.first.truth.status, 'deleted');
      expect(revisions.first.sourceKind, 'project_delete');
      expect(revisions.first.reason, 'No longer in scope.');
    });
  });

  group('ProjectCapsuleTruthService contention', () {
    setUpAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });
    tearDownAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
    });

    test(
      'two connections produce one same-base CAS winner',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'atlas_capsule_cas_',
        );
        final file = File(p.join(temp.path, 'capsule.sqlite'));
        final initializer = _openCapsuleDb(file);
        await initializer.customSelect('SELECT 1').get();
        await initializer.createProject(
          'atlas',
          'Project Atlas',
          DateTime.utc(2026),
        );
        await initializer.close();

        final dbA = _openCapsuleDb(file);
        final dbB = _openCapsuleDb(file);
        try {
          await Future.wait([
            dbA.customSelect('SELECT 1').get(),
            dbB.customSelect('SELECT 1').get(),
          ]);
          final serviceA = ProjectCapsuleTruthService(dbA);
          final serviceB = ProjectCapsuleTruthService(dbB);
          final base = (await serviceA.load('atlas'))!.revisionId;
          final start = Completer<void>();

          Future<Object> accept(
            ProjectCapsuleTruthService candidate,
            String description,
          ) async {
            await start.future;
            try {
              return await candidate.acceptPatch(
                projectId: 'atlas',
                expectedRevisionId: base,
                fields: {'description': description},
              );
            } catch (error) {
              return error;
            }
          }

          final attempts = [
            accept(serviceA, 'Connection A accepted.'),
            accept(serviceB, 'Connection B accepted.'),
          ];
          start.complete();
          final outcomes = await Future.wait(attempts);

          expect(
            outcomes.whereType<ProjectCapsuleTruthAcceptance>(),
            hasLength(1),
          );
          expect(
            outcomes.whereType<ProjectCapsuleTruthConflict>(),
            hasLength(1),
          );
          expect(await serviceA.listRevisions('atlas'), hasLength(2));
          expect(await serviceA.auditLedger('atlas'), 2);
        } finally {
          await Future.wait([dbA.close(), dbB.close()]);
          await temp.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

AppDb _openCapsuleDb(File file) => AppDb.withExecutor(
  NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      rawDb.execute('PRAGMA busy_timeout = 30000;');
      rawDb.execute('PRAGMA foreign_keys = ON;');
    },
  ),
);
