import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/local_project_refresh_service.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
import 'package:project_atlas/services/project_identity_enrichment_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('project metadata boundary', () {
    late AppDb db;
    late AppState state;

    setUp(() async {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      await db.createProject('atlas', 'Atlas', DateTime.utc(2026));
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test(
      'mixed closure edit records truth and supplemental metadata atomically',
      () async {
        final before = (await state.getProjectCapsuleTruth('atlas'))!;

        await state.updateProjectMeta('atlas', const {
          'outcomeSummary': 'Queue integrity shipped.',
          'lessonsLearned': 'Storage invariants belong in SQLite.',
        }, expectedTruthRevisionId: before.revisionId);

        final project = (await db.getProjectFull('atlas'))!;
        final revisions = await state.getProjectCapsuleRevisions('atlas');
        expect(project.outcomeSummary, 'Queue integrity shipped.');
        expect(project.lessonsLearned, 'Storage invariants belong in SQLite.');
        expect(revisions, hasLength(2));
        expect(revisions.first.changedFields.keys, ['outcomeSummary']);
      },
    );

    test('supplemental-only edit still enforces the truth revision', () async {
      final stale = (await state.getProjectCapsuleTruth('atlas'))!.revisionId;
      await state.updateProjectMeta('atlas', const {'phase': 'build'});

      await expectLater(
        state.updateProjectMeta('atlas', const {
          'lessonsLearned': 'This must not commit.',
        }, expectedTruthRevisionId: stale),
        throwsA(isA<ProjectCapsuleTruthConflict>()),
      );

      expect((await db.getProjectFull('atlas'))!.lessonsLearned, isNull);
      expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(2));
    });

    test(
      'unknown facade fields fail before project or ledger mutation',
      () async {
        await expectLater(
          state.updateProjectMeta('atlas', const {
            'desiredOutcome': 'Changed',
            'desired_outcome': 'Typo',
          }),
          throwsA(isA<ProjectCapsuleTruthValidationException>()),
        );

        final project = (await db.getProjectFull('atlas'))!;
        expect(project.desiredOutcome, isNull);
        expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
      },
    );

    test(
      'identity enrichment commits truth lessons and derived tags together',
      () async {
        final changed = await ProjectIdentityEnrichmentService(db).applyAction(
          projectId: 'atlas',
          entry: _registryEntry(),
          action: _identityAction(const {
            'desiredOutcome': 'Deterministic resume.',
            'lessonsLearned': 'Verify the whole boundary.',
            'manifestTags': ['flutter'],
          }),
          planProfile: 'desktop',
        );

        final project = (await db.getProjectFull('atlas'))!;
        final revisions = await state.getProjectCapsuleRevisions('atlas');
        final tags = await db.getTagsForProject('atlas');
        expect(changed, isTrue);
        expect(project.desiredOutcome, 'Deterministic resume.');
        expect(project.lessonsLearned, 'Verify the whole boundary.');
        expect(revisions, hasLength(2));
        expect(revisions.first.changedFields.keys, ['desiredOutcome']);
        expect(
          tags.map((tag) => tag.name),
          containsAll(['flutter', 'desktop']),
        );
      },
    );

    test(
      'invalid enrichment truth rolls back lessons and derived tags',
      () async {
        await expectLater(
          ProjectIdentityEnrichmentService(db).applyAction(
            projectId: 'atlas',
            entry: _registryEntry(),
            action: _identityAction(const {
              'phase': 'impossible',
              'lessonsLearned': 'This must roll back.',
              'manifestTags': ['orphan'],
            }),
            planProfile: 'desktop',
          ),
          throwsA(isA<ProjectCapsuleTruthValidationException>()),
        );

        final project = (await db.getProjectFull('atlas'))!;
        expect(project.phase, isNull);
        expect(project.lessonsLearned, isNull);
        expect(await db.getTagsForProject('atlas'), isEmpty);
        expect(await state.getProjectCapsuleRevisions('atlas'), hasLength(1));
      },
    );
  });
}

ProjectRegistryEntry _registryEntry() => ProjectRegistryEntry(
  id: 'registry-atlas',
  atlasProjectId: 'atlas',
  displayName: 'Atlas',
  localPath: 'B:\\not-present\\atlas',
  classification: 'software',
  reviewState: 'accepted',
  sourceRole: 'primary',
  sourceType: 'manual',
  lifecycleState: 'active',
  authorityLevel: 'local',
  precedence: 1,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

LocalProjectRefreshAction _identityAction(Map<String, Object?> payload) =>
    LocalProjectRefreshAction(
      sourceKind: 'project_manifest',
      sourceKey: 'manifest',
      targetType: 'project_metadata',
      title: 'Refresh identity',
      detail: 'Apply deterministic identity fields.',
      fingerprint: 'identity-fingerprint',
      payload: payload,
    );
