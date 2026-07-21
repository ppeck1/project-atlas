// Regression test for the LLM-queue stream conversion: `llm_task_queue` is a
// hand-managed table (raw DDL, no generated Drift class), so plain .watch()
// cannot invalidate on it. Every mutating queue method in AppDb must emit
// notifyUpdates('llm_task_queue') and watchLlmTasksForProject must re-run its
// query on that signal — with no AppState.notifyListeners involved (the LLM
// queue methods no longer notify).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';

void main() {
  late AppDb db;

  setUp(() {
    db = AppDb.withExecutor(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('queue mutations propagate through watchLlmTasksForProject '
      'without notifyListeners', () async {
    final emissions = <List<LlmTaskQueueItem>>[];
    final sub = db.watchLlmTasksForProject('proj_a').listen(emissions.add);
    addTearDown(sub.cancel);

    // Initial snapshot before any mutation.
    await pumpEventQueue();
    expect(emissions, hasLength(1));
    expect(emissions.last, isEmpty);

    // Enqueue: the insert must re-emit with the new pending task.
    final id = await db.enqueueLlmTask(
      projectId: 'proj_a',
      title: 'Stream check',
      objective: 'Prove the watcher re-runs on queue mutations.',
      contextJson: '{}',
    );
    await pumpEventQueue();
    expect(emissions.last.map((task) => task.id), [id]);
    expect(emissions.last.single.status, 'pending');

    // Claim (lease): status transition must propagate.
    final claimedAt = DateTime.utc(2026, 7, 21, 12);
    final claimed = await db.claimLlmTask(
      leasedBy: 'test_agent',
      now: claimedAt,
    );
    expect(claimed?.id, id);
    await pumpEventQueue();
    expect(emissions.last.single.status, 'leased');

    // Fail, then requeue, then cancel: each mutation re-emits.
    await db.failLlmTask(
      id: id,
      workerId: 'test_agent',
      leaseAttempt: claimed!.attempts,
      error: 'boom',
      now: claimedAt.add(const Duration(minutes: 1)),
    );
    await pumpEventQueue();
    expect(emissions.last.single.status, 'failed');

    await db.requeueLlmTask(id: id);
    await pumpEventQueue();
    expect(emissions.last.single.status, 'pending');

    await db.cancelLlmTask(id: id, reason: 'test over');
    await pumpEventQueue();
    expect(emissions.last.single.status, 'cancelled');

    // A task in another project re-runs the query but must not leak into
    // this project-scoped watcher.
    await db.enqueueLlmTask(
      projectId: 'proj_b',
      title: 'Other project',
      objective: 'Must not appear in proj_a watcher.',
      contextJson: '{}',
    );
    await pumpEventQueue();
    expect(emissions.last.map((task) => task.id), [id]);
  });

  test(
    'completeLlmTask propagates through a status-filtered watchLlmTasks',
    () async {
      final id = await db.enqueueLlmTask(
        projectId: 'proj_a',
        title: 'Complete me',
        objective: 'Completion must reach the completed-status watcher.',
        contextJson: '{}',
      );
      final claimedAt = DateTime.utc(2026, 7, 21, 13);
      final claimed = await db.claimLlmTask(
        taskId: id,
        leasedBy: 'test_agent',
        now: claimedAt,
      );

      final emissions = <List<LlmTaskQueueItem>>[];
      final sub = db
          .watchLlmTasks(projectId: 'proj_a', status: 'completed')
          .listen(emissions.add);
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions.last, isEmpty);

      await db.completeLlmTask(
        id: id,
        workerId: 'test_agent',
        leaseAttempt: claimed!.attempts,
        resultJson: '{"ok":true}',
        now: claimedAt.add(const Duration(minutes: 1)),
      );
      await pumpEventQueue();
      expect(emissions.last.map((task) => task.id), [id]);
      expect(emissions.last.single.status, 'completed');
    },
  );

  test('lease conflicts do not emit a queue mutation', () async {
    final id = await db.enqueueLlmTask(
      projectId: 'proj_a',
      title: 'Keep lease',
      objective: 'A rejected terminal transition must not notify watchers.',
      contextJson: '{}',
    );
    final claimedAt = DateTime.utc(2026, 7, 21, 14);
    final claimed = await db.claimLlmTask(
      taskId: id,
      leasedBy: 'worker-a',
      now: claimedAt,
      leaseDuration: const Duration(minutes: 5),
    );

    final emissions = <List<LlmTaskQueueItem>>[];
    final sub = db.watchLlmTasksForProject('proj_a').listen(emissions.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    final beforeConflict = emissions.length;

    final conflict = await db.completeLlmTask(
      id: id,
      workerId: 'worker-b',
      leaseAttempt: claimed!.attempts,
      resultJson: '{"ok":false}',
      now: claimedAt.add(const Duration(minutes: 1)),
    );
    await pumpEventQueue();

    expect(conflict.outcome, LlmTaskTerminalOutcome.conflict);
    expect(conflict.conflictReason, LlmTaskLeaseConflictReason.wrongOwner);
    expect(emissions, hasLength(beforeConflict));
    expect(emissions.last.single.status, 'leased');
  });
}
