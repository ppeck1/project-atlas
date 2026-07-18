import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/services/project_capsule_service.dart';
import 'package:project_atlas/services/project_capsule_truth_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('ProjectCapsuleService', () {
    late AppDb db;
    late AppState state;
    late ProjectCapsuleService service;

    setUp(() {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      service = ProjectCapsuleService(
        AtlasAgentProjectCapsuleSource(AtlasAgentService(state)),
        truthService: ProjectCapsuleTruthService(db),
        now: () => DateTime.utc(2026, 7, 17, 12),
      );
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test(
      'shares one revision across compact views and preserves boundaries',
      () async {
        await _seed(state, db);
        final snapshot = (await service.buildSnapshot('atlas'))!;

        expect(snapshot.schema, ProjectCapsuleSnapshot.schemaName);
        expect(snapshot.revisionId, startsWith('derived-'));
        expect(snapshot.contentHash, hasLength(64));
        expect(snapshot.truthRevisionId, isNotEmpty);
        expect(snapshot.truthRevisionCount, 1);
        expect(
          snapshot.intent['desiredOutcome'],
          'Resume without reconstruction.',
        );
        expect(
          snapshot.readyItems.single.title,
          'Build capsule resume surface',
        );
        expect(snapshot.readyItems.single.owner, 'operator');
        expect(snapshot.readyItems.single.suggestedActor, 'codex');
        expect(snapshot.decisionItems.single.title, 'Choose navigation label');
        expect(snapshot.blockedItems.single.title, 'Publish screenshots');
        expect(snapshot.decisions.single['title'], 'Keep human acceptance');
        expect(snapshot.risks.single['title'], 'Context drift');
        expect(snapshot.acceptedState['currentActiveTask'], isNull);

        final act = snapshot.toJson(view: ProjectCapsuleView.act);
        final understand = snapshot.toJson(view: ProjectCapsuleView.understand);
        final audit = snapshot.toJson(view: ProjectCapsuleView.audit);
        final full = snapshot.toJson();
        for (final view in [act, understand, audit, full]) {
          expect(view['revisionId'], snapshot.revisionId);
          expect(view['contentHash'], snapshot.contentHash);
          expect(view, contains('acceptanceBoundary'));
          expect(view, contains('truthRevision'));
        }
        expect(act, contains('readyItems'));
        expect(act, isNot(contains('intent')));
        expect(understand, contains('intent'));
        expect(understand, isNot(contains('readyItems')));
        expect(audit, contains('verification'));
        expect(audit, isNot(contains('decisions')));
        expect(jsonEncode(act).length, lessThan(jsonEncode(full).length));

        final serialized = jsonEncode(full);
        for (final excluded in [
          'localPath',
          'repoRoot',
          'projectManifest',
          'opsCapsule',
          'contextJson',
          'resultJson',
          'payload',
        ]) {
          expect(serialized, isNot(contains(excluded)));
        }
        expect(serialized, contains('humanAcceptanceRequired'));
      },
    );

    test('only in-progress work becomes the accepted active task', () async {
      await _seed(state, db);
      await state.addWorkItemToProject(
        'atlas',
        'Execute accepted work',
        owner: 'operator',
        status: 'doing',
        readiness: 'ready',
      );

      final snapshot = (await service.buildSnapshot('atlas'))!;
      expect(
        snapshot.acceptedState['currentActiveTask'],
        'Execute accepted work',
      );
    });

    test('deeply freezes projected state behind the revision hash', () async {
      await _seed(state, db);
      final snapshot = (await service.buildSnapshot('atlas'))!;
      final originalHash = snapshot.contentHash;
      final freshness = snapshot.audit['freshness']! as Map<String, Object?>;
      final timestamps = freshness['timestamps']! as Map<String, Object?>;

      expect(() => freshness['status'] = 'changed', throwsUnsupportedError);
      expect(() => timestamps['createdAt'] = 'changed', throwsUnsupportedError);
      expect(
        () => snapshot.decisions.single['title'] = 'changed',
        throwsUnsupportedError,
      );
      expect(snapshot.contentHash, originalHash);
    });

    test('revision changes only when projected content changes', () async {
      await _seed(state, db);
      final first = (await service.buildSnapshot('atlas'))!;
      final second = (await service.buildSnapshot('atlas'))!;
      expect(second.revisionId, first.revisionId);

      await db.updateProjectMeta('atlas', {
        'desiredOutcome': 'Resume and delegate without reconstruction.',
      });
      final changed = (await service.buildSnapshot('atlas'))!;
      expect(changed.revisionId, isNot(first.revisionId));
    });

    test(
      'work changes snapshot revision without changing truth revision',
      () async {
        await _seed(state, db);
        final first = (await service.buildSnapshot('atlas'))!;

        await state.addWorkItemToProject(
          'atlas',
          'A new derived work item',
          readiness: 'needs_decision',
        );
        final second = (await service.buildSnapshot('atlas'))!;

        expect(second.revisionId, isNot(first.revisionId));
        expect(second.truthRevisionId, first.truthRevisionId);
        expect(
          second.authoredTruth.contentHash,
          first.authoredTruth.contentHash,
        );
      },
    );

    test('freshness preflight takes precedence over execution', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      await state.addWorkItemToProject(
        'atlas',
        'Implement next slice',
        readiness: 'ready',
        suggestedActor: 'codex',
      );
      await state.addWorkItemToProject(
        'atlas',
        'Review agent result',
        readiness: 'review_needed',
        suggestedActor: 'manual_review',
        verificationNeeded: 'tests',
      );

      final snapshot = (await service.buildSnapshot('atlas'))!;
      expect(
        snapshot.recommendation.action,
        'Link or classify the project local registry before planning.',
      );
      expect(snapshot.recommendation.owner, 'human');
    });

    test('review-ready work wins once evidence is current', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'atlas_capsule_source_',
      );
      addTearDown(() => sourceDirectory.delete(recursive: true));
      final metadataDirectory = Directory(
        p.join(sourceDirectory.path, '.project'),
      );
      await metadataDirectory.create();
      await File(
        p.join(metadataDirectory.path, 'project_manifest.json'),
      ).writeAsString('{"accepted_version":"v1","validation":{}}');
      await File(
        p.join(metadataDirectory.path, 'ops_capsule.json'),
      ).writeAsString('{}');
      await _linkObservedPath(db, 'atlas', sourceDirectory.path);
      await state.addWorkItemToProject(
        'atlas',
        'Implement next slice',
        owner: 'operator',
        readiness: 'ready',
        suggestedActor: 'codex',
      );
      await state.addWorkItemToProject(
        'atlas',
        'Review agent result',
        owner: 'operator',
        readiness: 'review_needed',
        suggestedActor: 'manual_review',
        verificationNeeded: 'tests',
      );

      final snapshot = (await service.buildSnapshot('atlas'))!;
      expect(snapshot.recommendation.action, 'Review agent result.');
      expect(snapshot.recommendation.owner, 'human');
      expect(snapshot.recommendation.transition, contains('accept'));
    });

    test('redacts local paths from diagnostics and blocks on errors', () async {
      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      await _linkObservedPath(db, 'atlas', r'B:\private\AtlasCapsuleSecret');
      await state.addWorkItemToProject(
        'atlas',
        'Unsafe execution candidate',
        owner: 'operator',
        readiness: 'ready',
      );

      final snapshot = (await service.buildSnapshot('atlas'))!;
      final serialized = jsonEncode(snapshot.toJson());
      expect(serialized, isNot(contains(r'B:\private')));
      expect(serialized, isNot(contains('AtlasCapsuleSecret')));
      expect(serialized, contains('[local path]'));
      expect(
        snapshot.recommendation.action,
        'Resolve protocol evidence errors before selecting work.',
      );
    });

    test('returns null outside the visible-project boundary', () async {
      await db.createProject('deleted', 'Deleted', DateTime.utc(2026));
      await db.softDeleteProject('deleted', 'fixture');
      expect(await service.buildSnapshot('deleted'), isNull);
    });
  });
}

Future<void> _linkObservedPath(
  AppDb db,
  String projectId,
  String observedPath,
) async {
  final observedAt = DateTime.utc(2026, 7, 17, 11);
  final scanRunId = await db.startProjectScanRun(
    rootsJson: '[]',
    startedAt: observedAt,
  );
  final observationId = 'observation-$projectId';
  await db.addProjectObservation(
    id: observationId,
    scanRunId: scanRunId,
    observedPath: observedPath,
    classificationGuess: 'software',
    confidence: 100,
    markerFilesJson: '[]',
    warningsJson: '[]',
    rawJson: '{"displayName":"Project Atlas"}',
    observedAt: observedAt,
  );
  await db.reviewProjectObservation(
    observationId: observationId,
    reviewState: 'accepted',
    atlasProjectId: projectId,
  );
}

Future<void> _seed(AppState state, AppDb db) async {
  await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
  await db.updateProjectMeta('atlas', {
    'description': 'A governed local project command center.',
    'desiredOutcome': 'Resume without reconstruction.',
    'successCriteria': 'Choose one justified action in under two minutes.',
    'scopeIncluded': 'Capsule projection and resume UI.',
    'scopeExcluded': 'Workflow engine and remote MCP changes.',
    'phase': 'build',
    'priority': 'high',
  });
  await state.addProjectDecision(
    'atlas',
    'Keep human acceptance',
    'Agent output remains proposed until reviewed.',
    'Paul',
  );
  await state.addProjectRisk(
    'atlas',
    'Context drift',
    'Multiple packet builders can disagree.',
    'high',
  );
  await state.addWorkItemToProject(
    'atlas',
    'Build capsule resume surface',
    owner: 'operator',
    readiness: 'ready',
    priority: 'high',
    suggestedActor: 'codex',
    verificationNeeded: 'tests',
    nextAction: 'Implement the read-only vertical slice.',
  );
  await state.addWorkItemToProject(
    'atlas',
    'Choose navigation label',
    readiness: 'needs_decision',
  );
  await state.addWorkItemToProject(
    'atlas',
    'Publish screenshots',
    readiness: 'blocked',
    blockedReason: 'Wait for the UI contract to stabilize.',
  );
}
