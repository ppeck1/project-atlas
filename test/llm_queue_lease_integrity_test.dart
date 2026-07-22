import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/db/app_db.dart';

void main() {
  setUpAll(() {
    // This suite intentionally opens independent connections to one file to
    // prove SQLite-level contention behavior.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
  });

  group('LLM queue lease integrity', () {
    late Directory tempDir;
    late File databaseFile;
    late AppDb dbA;
    late AppDb dbB;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('atlas_queue_lease_');
      databaseFile = File(p.join(tempDir.path, 'queue.sqlite'));

      // Initialize the schema before opening the two connections used by the
      // contention proofs. This keeps migration DDL out of the race itself.
      final initializer = _openQueueDb(databaseFile);
      await initializer.customSelect('SELECT 1').get();
      await initializer.close();

      dbA = _openQueueDb(databaseFile);
      dbB = _openQueueDb(databaseFile);
      await Future.wait([
        dbA.customSelect('SELECT 1').get(),
        dbB.customSelect('SELECT 1').get(),
      ]);
      await dbA.createProject(
        'queue-integrity-project',
        'Queue integrity',
        DateTime.utc(2026, 7, 21),
      );
    });

    tearDown(() async {
      await Future.wait([dbA.close(), dbB.close()]);
      await tempDir.delete(recursive: true);
    });

    test('two SQLite connections produce exactly one claim winner', () async {
      for (var round = 0; round < 20; round++) {
        final taskId = await _enqueue(dbA, suffix: 'contention-$round');
        final now = DateTime.utc(2026, 7, 21, 12, 0, round);
        final start = Completer<void>();

        Future<LlmTaskQueueItem?> claim(AppDb db, String workerId) async {
          await start.future;
          return db.claimLlmTask(taskId: taskId, leasedBy: workerId, now: now);
        }

        final claims = [claim(dbA, 'worker-a'), claim(dbB, 'worker-b')];
        start.complete();
        final results = await Future.wait(claims);
        final winners = results.whereType<LlmTaskQueueItem>().toList();

        expect(winners, hasLength(1), reason: 'contention round $round');
        final stored = await dbA.getLlmTask(taskId);
        expect(stored!.status, 'leased');
        expect(stored.leasedBy, winners.single.leasedBy);
        expect(stored.attempts, 1);
      }
    });

    test(
      'two SQLite connections produce one claim-next winner',
      () async {
        for (var round = 0; round < 10; round++) {
          final taskId = await _enqueue(dbA, suffix: 'claim-next-$round');
          final now = DateTime.utc(2026, 7, 21, 12, 30, round);
          final start = Completer<void>();

          Future<LlmTaskQueueItem?> claimNext(AppDb db, String workerId) async {
            await start.future;
            return db.claimLlmTask(leasedBy: workerId, now: now);
          }

          final claims = [
            claimNext(dbA, 'worker-a'),
            claimNext(dbB, 'worker-b'),
          ];
          start.complete();
          final results = await Future.wait(claims);
          final winners = results.whereType<LlmTaskQueueItem>().toList();

          expect(winners, hasLength(1), reason: 'claim-next round $round');
          expect(winners.single.id, taskId);
          final stored = await dbA.getLlmTask(taskId);
          expect(stored!.leasedBy, winners.single.leasedBy);
          expect(stored.attempts, 1);
        }
      },
      // Background SQLite contention can exceed Flutter's default 30-second
      // per-test limit when the complete Windows suite is CPU-saturated.
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'blank worker identities are rejected before queue mutation',
      () async {
        final taskId = await _enqueue(dbA, suffix: 'blank-worker');
        final now = DateTime.utc(2026, 7, 21, 12, 45);

        await expectLater(
          dbA.claimLlmTask(taskId: taskId, leasedBy: '   ', now: now),
          throwsArgumentError,
        );
        expect((await dbA.getLlmTask(taskId))!.status, 'pending');

        final claimed = await dbA.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: now,
        );
        await expectLater(
          dbA.completeLlmTask(
            id: taskId,
            workerId: '   ',
            leaseAttempt: claimed!.attempts,
            resultJson: '{}',
            now: now.add(const Duration(minutes: 1)),
          ),
          throwsArgumentError,
        );
        await expectLater(
          dbA.failLlmTask(
            id: taskId,
            workerId: '',
            leaseAttempt: claimed.attempts,
            error: 'must not apply',
            now: now.add(const Duration(minutes: 1)),
          ),
          throwsArgumentError,
        );
        expect((await dbA.getLlmTask(taskId))!.status, 'leased');
      },
    );

    test('wrong owner cannot complete or fail a live lease', () async {
      final taskId = await _enqueue(dbA, suffix: 'wrong-owner');
      final leasedAt = DateTime.utc(2026, 7, 21, 13);
      final claimed = await dbA.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-a',
        now: leasedAt,
        leaseDuration: const Duration(minutes: 5),
      );

      final complete = await dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-b',
        leaseAttempt: claimed!.attempts,
        resultJson: '{"summary":"not mine"}',
        now: leasedAt.add(const Duration(minutes: 1)),
      );
      final fail = await dbA.failLlmTask(
        id: taskId,
        workerId: 'worker-b',
        leaseAttempt: claimed.attempts,
        error: 'not mine',
        now: leasedAt.add(const Duration(minutes: 1)),
      );

      _expectConflict(complete, LlmTaskLeaseConflictReason.wrongOwner);
      _expectConflict(fail, LlmTaskLeaseConflictReason.wrongOwner);
      final stored = await dbA.getLlmTask(taskId);
      expect(stored!.status, 'leased');
      expect(stored.resultJson, isNull);
      expect(stored.error, isNull);
      expect(stored.reviewDraftId, isNull);
    });

    test('lease is expired at the exact expiry instant', () async {
      final taskId = await _enqueue(dbA, suffix: 'exact-expiry');
      final leasedAt = DateTime.utc(2026, 7, 21, 14);
      final claimed = await dbA.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-a',
        now: leasedAt,
        leaseDuration: const Duration(minutes: 5),
      );
      final expiresAt = leasedAt.add(const Duration(minutes: 5));

      final complete = await dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed!.attempts,
        resultJson: '{"summary":"late"}',
        now: expiresAt,
      );
      final fail = await dbA.failLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed.attempts,
        error: 'late',
        now: expiresAt,
      );

      _expectConflict(complete, LlmTaskLeaseConflictReason.expiredLease);
      _expectConflict(fail, LlmTaskLeaseConflictReason.expiredLease);

      final reclaimed = await dbB.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-b',
        now: expiresAt,
      );
      expect(reclaimed, isNotNull);
      expect(reclaimed!.attempts, 2);
      expect(reclaimed.leasedBy, 'worker-b');
    });

    test(
      'lease attempt prevents same-worker ABA completion and failure',
      () async {
        final taskId = await _enqueue(dbA, suffix: 'same-worker-aba');
        final firstLeaseAt = DateTime.utc(2026, 7, 21, 15);
        final first = await dbA.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: firstLeaseAt,
          leaseDuration: const Duration(minutes: 1),
        );
        final second = await dbB.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: firstLeaseAt.add(const Duration(minutes: 1)),
        );
        expect(second!.attempts, first!.attempts + 1);

        final staleComplete = await dbA.completeLlmTask(
          id: taskId,
          workerId: 'worker-a',
          leaseAttempt: first.attempts,
          resultJson: '{"summary":"attempt one"}',
          now: firstLeaseAt.add(const Duration(minutes: 2)),
        );
        final staleFail = await dbA.failLlmTask(
          id: taskId,
          workerId: 'worker-a',
          leaseAttempt: first.attempts,
          error: 'attempt one failed late',
          now: firstLeaseAt.add(const Duration(minutes: 2)),
        );

        _expectConflict(staleComplete, LlmTaskLeaseConflictReason.staleAttempt);
        _expectConflict(staleFail, LlmTaskLeaseConflictReason.staleAttempt);
        final stored = await dbA.getLlmTask(taskId);
        expect(stored!.status, 'leased');
        expect(stored.attempts, second.attempts);
        expect(stored.resultJson, isNull);
        expect(stored.error, isNull);
      },
    );

    test('completion replay returns the original terminal result', () async {
      final taskId = await _enqueue(dbA, suffix: 'complete-replay');
      final now = DateTime.utc(2026, 7, 21, 16);
      final claimed = await dbA.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-a',
        now: now,
      );

      Future<LlmTaskTerminalResult> complete() => dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed!.attempts,
        resultJson: '{"summary":"done"}',
        now: now.add(const Duration(minutes: 1)),
      );

      final first = await complete();
      final replay = await complete();

      expect(first.outcome, LlmTaskTerminalOutcome.applied);
      expect(replay.outcome, LlmTaskTerminalOutcome.idempotentReplay);
      expect(replay.task!.id, first.task!.id);
      expect(replay.task!.resultJson, first.task!.resultJson);
    });

    test('failure replay returns the original terminal result', () async {
      final taskId = await _enqueue(dbA, suffix: 'failure-replay');
      final now = DateTime.utc(2026, 7, 21, 17);
      final claimed = await dbA.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-a',
        now: now,
      );

      Future<LlmTaskTerminalResult> fail() => dbA.failLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed!.attempts,
        error: 'provider unavailable',
        resultJson: '{"retryable":true}',
        now: now.add(const Duration(minutes: 1)),
      );

      final first = await fail();
      final replay = await fail();

      expect(first.outcome, LlmTaskTerminalOutcome.applied);
      expect(replay.outcome, LlmTaskTerminalOutcome.idempotentReplay);
      expect(replay.task!.error, 'provider unavailable');
      expect(replay.task!.resultJson, '{"retryable":true}');
    });

    test('reordered JSON object keys are semantic terminal replays', () async {
      final completeId = await _enqueue(dbA, suffix: 'semantic-complete');
      final failId = await _enqueue(dbA, suffix: 'semantic-fail');
      final now = DateTime.utc(2026, 7, 21, 17, 30);
      final completeClaim = await dbA.claimLlmTask(
        taskId: completeId,
        leasedBy: 'worker-a',
        now: now,
      );
      final failClaim = await dbA.claimLlmTask(
        taskId: failId,
        leasedBy: 'worker-b',
        now: now,
      );

      await dbA.completeLlmTask(
        id: completeId,
        workerId: 'worker-a',
        leaseAttempt: completeClaim!.attempts,
        resultJson: '{"alpha":1,"nested":{"x":2,"y":3}}',
        now: now.add(const Duration(minutes: 1)),
      );
      final completeReplay = await dbA.completeLlmTask(
        id: completeId,
        workerId: 'worker-a',
        leaseAttempt: completeClaim.attempts,
        resultJson: '{"nested":{"y":3,"x":2},"alpha":1}',
        now: now.add(const Duration(minutes: 2)),
      );

      await dbA.failLlmTask(
        id: failId,
        workerId: 'worker-b',
        leaseAttempt: failClaim!.attempts,
        error: 'provider unavailable',
        resultJson: '{"retryable":true,"detail":{"code":503,"host":"x"}}',
        now: now.add(const Duration(minutes: 1)),
      );
      final failReplay = await dbA.failLlmTask(
        id: failId,
        workerId: 'worker-b',
        leaseAttempt: failClaim.attempts,
        error: 'provider unavailable',
        resultJson: '{"detail":{"host":"x","code":503},"retryable":true}',
        now: now.add(const Duration(minutes: 2)),
      );

      expect(completeReplay.outcome, LlmTaskTerminalOutcome.idempotentReplay);
      expect(failReplay.outcome, LlmTaskTerminalOutcome.idempotentReplay);
    });

    test(
      'response-loss retry reuses one deterministic completion draft',
      () async {
        final taskId = await _enqueue(dbA, suffix: 'draft-replay');
        final now = DateTime.utc(2026, 7, 21, 18);
        final claimed = await dbA.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: now,
        );
        final draft = _completionDraft(taskId, claimed!.attempts);

        Future<LlmTaskTerminalResult> complete() => dbA.completeLlmTask(
          id: taskId,
          workerId: 'worker-a',
          leaseAttempt: claimed.attempts,
          resultJson: '{"summary":"review me"}',
          handoffDraft: draft,
          now: now.add(const Duration(minutes: 1)),
        );

        // Treat the first successful call as a lost response, then issue the
        // exact same request again.
        await complete();
        final replay = await complete();

        expect(replay.outcome, LlmTaskTerminalOutcome.idempotentReplay);
        expect(replay.task!.reviewDraftId, draft.id);
        final storedDraft = await dbA.getDraft(draft.id);
        expect(storedDraft, isNotNull);
        expect(storedDraft!.body, draft.body);
        final rows = await dbA
            .customSelect(
              'SELECT COUNT(*) AS count FROM drafts WHERE id = ?',
              variables: [Variable<String>(draft.id)],
            )
            .getSingle();
        expect(rows.read<int>('count'), 1);
      },
    );

    test(
      'concurrent completion replay creates one deterministic draft',
      () async {
        final taskId = await _enqueue(dbA, suffix: 'concurrent-completion');
        final now = DateTime.utc(2026, 7, 21, 18, 30);
        final claimed = await dbA.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: now,
        );
        final draft = _completionDraft(taskId, claimed!.attempts);
        final start = Completer<void>();

        Future<LlmTaskTerminalResult> complete(AppDb db) async {
          await start.future;
          return db.completeLlmTask(
            id: taskId,
            workerId: 'worker-a',
            leaseAttempt: claimed.attempts,
            resultJson: '{"summary":"one result"}',
            handoffDraft: draft,
            now: now.add(const Duration(minutes: 1)),
          );
        }

        final completions = [complete(dbA), complete(dbB)];
        start.complete();
        final results = await Future.wait(completions);

        expect(
          results.map((result) => result.outcome),
          containsAll([
            LlmTaskTerminalOutcome.applied,
            LlmTaskTerminalOutcome.idempotentReplay,
          ]),
        );
        expect(
          results.map((result) => result.task!.reviewDraftId),
          everyElement(draft.id),
        );
        final rows = await dbA
            .customSelect(
              'SELECT COUNT(*) AS count FROM drafts WHERE id = ?',
              variables: [Variable<String>(draft.id)],
            )
            .getSingle();
        expect(rows.read<int>('count'), 1);
      },
    );

    test('completion replay rejects result or draft mismatches', () async {
      final taskId = await _enqueue(dbA, suffix: 'mismatch');
      final now = DateTime.utc(2026, 7, 21, 19);
      final claimed = await dbA.claimLlmTask(
        taskId: taskId,
        leasedBy: 'worker-a',
        now: now,
      );
      final draft = _completionDraft(taskId, claimed!.attempts);
      await dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed.attempts,
        resultJson: '{"summary":"original"}',
        handoffDraft: draft,
        now: now.add(const Duration(minutes: 1)),
      );

      final changedResult = await dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed.attempts,
        resultJson: '{"summary":"changed"}',
        handoffDraft: draft,
        now: now.add(const Duration(minutes: 2)),
      );
      final changedDraft = await dbA.completeLlmTask(
        id: taskId,
        workerId: 'worker-a',
        leaseAttempt: claimed.attempts,
        resultJson: '{"summary":"original"}',
        handoffDraft: LlmTaskCompletionDraftPayload(
          id: draft.id,
          kind: draft.kind,
          title: draft.title,
          body: '${draft.body} changed',
          inputJson: draft.inputJson,
          projectId: draft.projectId,
          workItemId: draft.workItemId,
        ),
        now: now.add(const Duration(minutes: 2)),
      );

      _expectConflict(
        changedResult,
        LlmTaskLeaseConflictReason.idempotencyMismatch,
      );
      _expectConflict(
        changedDraft,
        LlmTaskLeaseConflictReason.idempotencyMismatch,
      );
      expect((await dbA.getDraft(draft.id))!.body, draft.body);
    });

    test(
      'failure after draft insert rolls back draft and queue transition',
      () async {
        final taskId = await _enqueue(dbA, suffix: 'rollback');
        final now = DateTime.utc(2026, 7, 21, 20);
        final claimed = await dbA.claimLlmTask(
          taskId: taskId,
          leasedBy: 'worker-a',
          now: now,
        );
        final draft = _completionDraft(taskId, claimed!.attempts);

        await expectLater(
          dbA.completeLlmTask(
            id: taskId,
            workerId: 'worker-a',
            leaseAttempt: claimed.attempts,
            resultJson: '{"summary":"will roll back"}',
            handoffDraft: draft,
            now: now.add(const Duration(minutes: 1)),
            afterDraftInsertForTesting: () async {
              throw StateError('injected completion crash');
            },
          ),
          throwsStateError,
        );

        final afterCrash = await dbA.getLlmTask(taskId);
        expect(afterCrash!.status, 'leased');
        expect(afterCrash.resultJson, isNull);
        expect(afterCrash.reviewDraftId, isNull);
        expect(await dbA.getDraft(draft.id), isNull);

        final retry = await dbA.completeLlmTask(
          id: taskId,
          workerId: 'worker-a',
          leaseAttempt: claimed.attempts,
          resultJson: '{"summary":"will roll back"}',
          handoffDraft: draft,
          now: now.add(const Duration(minutes: 1)),
        );
        expect(retry.outcome, LlmTaskTerminalOutcome.applied);
        expect(retry.task!.reviewDraftId, draft.id);
        expect(await dbA.getDraft(draft.id), isNotNull);
      },
    );
  });
}

AppDb _openQueueDb(File file) => AppDb.withExecutor(
  NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      rawDb.execute('PRAGMA busy_timeout = 30000;');
      rawDb.execute('PRAGMA foreign_keys = ON;');
    },
  ),
);

Future<String> _enqueue(AppDb db, {required String suffix}) =>
    db.enqueueLlmTask(
      projectId: 'queue-integrity-project',
      title: 'Queue integrity $suffix',
      objective: 'Prove lease and retry integrity for $suffix.',
      contextJson: '{}',
      createdAt: DateTime.utc(2026, 7, 21),
    );

LlmTaskCompletionDraftPayload _completionDraft(String taskId, int attempt) =>
    LlmTaskCompletionDraftPayload(
      id: 'llm_handoff_${taskId}_$attempt',
      kind: 'agent_proposal',
      title: 'Review queue result',
      body: 'Review the deterministic result for $taskId attempt $attempt.',
      inputJson: '{"taskId":"$taskId","attempt":$attempt}',
      projectId: null,
      workItemId: null,
    );

void _expectConflict(
  LlmTaskTerminalResult result,
  LlmTaskLeaseConflictReason reason,
) {
  expect(result.outcome, LlmTaskTerminalOutcome.conflict);
  expect(result.conflictReason, reason);
}
