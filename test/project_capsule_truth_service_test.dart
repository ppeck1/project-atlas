import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
import 'package:project_atlas/shared/models/project_capsule_truth.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
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

    test('revision reads verify stored content hashes', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
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
}
