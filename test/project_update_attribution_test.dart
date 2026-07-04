import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
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

  test(
    'project update attribution uses latest event and contact hint',
    () async {
      final createdAt = DateTime(2026, 1, 1, 9);
      final eventAt = DateTime(2026, 6, 30, 14, 45);

      await db.createProject('project-a', 'Alpha', createdAt);
      await db.updateProjectMeta('project-a', {'owner': 'Pat Peck'});
      await db
          .into(db.eventLog)
          .insert(
            EventLogCompanion(
              id: const Value('event-a'),
              timestamp: Value(eventAt),
              level: const Value('info'),
              area: const Value('local_operations'),
              action: const Value('selected_existing_project_refresh'),
              entityType: const Value('project'),
              entityId: const Value('project-a'),
              outputJson: Value(jsonEncode({'agent': 'codex'})),
            ),
          );

      final attributions = await db.getProjectUpdateAttributions();
      final attribution = attributions['project-a'];

      expect(attribution, isNotNull);
      expect(attribution!.updatedAt, eventAt);
      expect(attribution.updatedBy, 'Codex');
      expect(attribution.source, 'event_log');
      expect(attribution.contactName, 'Pat Peck');
    },
  );

  test(
    'project event logs include metadata diffs and work item events',
    () async {
      final createdAt = DateTime(2026, 1, 1, 9);

      await db.createProject('project-a', 'Alpha', createdAt);
      await db.createProject('project-b', 'Beta', createdAt);
      final stage = (await db.getStagesForProject('project-a')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Follow up',
      );

      await state.updateProjectMeta('project-a', {'owner': 'Pat Peck'});
      await db.logEvent(
        area: 'work',
        action: 'work_item_updated',
        entityType: 'work_item',
        entityId: workItemId,
        outputJson: jsonEncode({
          'actor': {'displayName': 'Pat Peck'},
        }),
      );
      await db.logEvent(
        area: 'projects',
        action: 'project_metadata_updated',
        entityType: 'project',
        entityId: 'project-b',
      );

      final logs = await state.getProjectEventLogs('project-a');
      final metadataEvent = logs.firstWhere(
        (event) => event.action == 'project_metadata_updated',
      );
      final output = jsonDecode(metadataEvent.outputJson!) as Map;
      final changedFields = output['changedFields'] as Map;

      expect(logs.map((event) => event.entityId), contains(workItemId));
      expect(logs.map((event) => event.entityId), isNot(contains('project-b')));
      expect(changedFields.keys.map((key) => '$key'), contains('owner'));

      final attributions = await db.getProjectUpdateAttributions();
      expect(attributions['project-a']!.updatedBy, 'Operator');
    },
  );

  test(
    'project change log normalizes actors, diffs, and related work item events',
    () async {
      final createdAt = DateTime(2026, 1, 1, 9);

      await db.createProject('project-a', 'Alpha', createdAt);
      final stage = (await db.getStagesForProject('project-a')).single;
      final workItemId = await db.addWorkItem(
        stageId: stage.id,
        title: 'Call supplier',
      );

      await state.updateProjectMeta('project-a', {
        'owner': 'Paul Peck',
        'status': 'active',
      }, actor: 'Paul Peck');
      await db.logEvent(
        area: 'work',
        action: 'work_item_updated',
        entityType: 'work_item',
        entityId: workItemId,
        outputJson: jsonEncode({
          'actor': {'type': 'operator', 'displayName': 'Pat Peck'},
        }),
      );

      final changes = await state.getProjectChangeLog('project-a');
      final metadataChange = changes.firstWhere(
        (change) => change.action == 'project_metadata_updated',
      );
      final workChange = changes.firstWhere(
        (change) => change.action == 'work_item_updated',
      );

      expect(metadataChange.actor, 'Paul Peck');
      expect(metadataChange.actorType, 'operator');
      expect(metadataChange.changedFields.keys, contains('owner'));
      expect(metadataChange.beforeJson['owner'], isNull);
      expect(metadataChange.afterJson['owner'], 'Paul Peck');
      expect(metadataChange.summary, contains('Owner'));
      expect(workChange.actor, 'Pat Peck');
      expect(workChange.actorType, 'operator');
      expect(workChange.summary, contains('Call supplier'));
      expect(changes.map((change) => change.projectId).toSet(), {'project-a'});
    },
  );

  test(
    'project change log sorts newest first by default and can reverse',
    () async {
      await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1, 9));
      await db
          .into(db.eventLog)
          .insert(
            EventLogCompanion(
              id: const Value('old-event'),
              timestamp: Value(DateTime(2026, 1, 1, 10)),
              level: const Value('info'),
              area: const Value('projects'),
              action: const Value('old_change'),
              entityType: const Value('project'),
              entityId: const Value('project-a'),
            ),
          );
      await db
          .into(db.eventLog)
          .insert(
            EventLogCompanion(
              id: const Value('new-event'),
              timestamp: Value(DateTime(2026, 1, 1, 11)),
              level: const Value('info'),
              area: const Value('projects'),
              action: const Value('new_change'),
              entityType: const Value('project'),
              entityId: const Value('project-a'),
            ),
          );

      final newest = await state.getProjectChangeLog('project-a');
      final oldest = await state.getProjectChangeLog(
        'project-a',
        newestFirst: false,
      );

      expect(newest.map((change) => change.sourceEventId).take(2), [
        'new-event',
        'old-event',
      ]);
      expect(oldest.map((change) => change.sourceEventId).take(2), [
        'old-event',
        'new-event',
      ]);
    },
  );

  test(
    'project change summary evidence packet is bounded and structured',
    () async {
      final createdAt = DateTime(2026, 1, 1, 9);
      await db.createProject('project-a', 'Alpha', createdAt);
      await db.createProject('project-b', 'Beta', createdAt);

      await state.updateProjectMeta('project-a', {
        'owner': 'Paul Peck',
      }, actor: 'Paul Peck');
      await db.logEvent(
        area: 'projects',
        action: 'project_metadata_updated',
        entityType: 'project',
        entityId: 'project-b',
        outputJson: jsonEncode({
          'actor': {'type': 'operator', 'displayName': 'Other'},
        }),
      );

      final packet = await state.buildProjectChangeSummaryEvidencePacket(
        'project-a',
        limit: 5,
      );
      final project = packet['project'] as Map<String, Object?>;
      final changes = packet['changes'] as List<Object?>;
      final firstChange = changes.single as Map<String, Object?>;

      expect(packet['schema'], 'project_change_summary_evidence_packet_v1');
      expect(project['title'], 'Alpha');
      expect(packet['changeCount'], 1);
      expect(firstChange['projectId'], 'project-a');
      expect(firstChange['actor'], 'Paul Peck');
      expect(firstChange['action'], 'project_metadata_updated');
    },
  );

  test('project change summary saves review draft with evidence', () async {
    final fake = await _FakeOllama.start(
      '## Summary\nOwner changed to Paul Peck.',
    );
    addTearDown(fake.close);

    await state.setSetting(AppDb.kOllamaHost, fake.host);
    await state.saveProjectAiSummarySettings(
      const ProjectAiSummarySettings(enabled: true, model: 'test-model'),
    );
    await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1, 9));
    await state.updateProjectMeta('project-a', {
      'owner': 'Paul Peck',
    }, actor: 'Paul Peck');

    final result = await state.summarizeProjectChanges('project-a', limit: 5);
    final draft = await state.getLatestProjectChangeSummaryDraft('project-a');
    final events = await db.getRecentEvents();

    expect(result.isSuccess, isTrue);
    expect(result.kind, 'project_change_summary');
    expect(fake.requests, hasLength(1));
    expect(
      jsonEncode(fake.requests.single),
      contains('project_change_summary_prompt_evidence_packet_v1'),
    );
    expect(draft, isNotNull);
    expect(draft!.kind, 'project_change_summary');
    expect(draft.body, contains('Owner changed'));
    final input = jsonDecode(draft.inputJson!) as Map<String, Object?>;
    expect(input['schema'], 'project_change_summary_draft_input_v1');
    expect(input['model'], 'test-model');
    final evidence = input['evidence'] as Map<String, Object?>;
    expect(evidence['schema'], 'project_change_summary_evidence_packet_v1');
    expect(
      events.map((event) => event.action),
      contains('project_change_summary_draft_saved'),
    );
  });

  test(
    'project change summary run is tracked while background draft saves',
    () async {
      final fake = await _FakeOllama.start(
        '## Summary\nOwner changed in the background.',
        delay: const Duration(milliseconds: 50),
      );
      addTearDown(fake.close);

      await state.setSetting(AppDb.kOllamaHost, fake.host);
      await state.saveProjectAiSummarySettings(
        const ProjectAiSummarySettings(enabled: true, model: 'test-model'),
      );
      await db.createProject('project-a', 'Alpha', DateTime(2026, 1, 1, 9));
      await state.updateProjectMeta('project-a', {
        'owner': 'Paul Peck',
      }, actor: 'Paul Peck');

      final future = state.startProjectChangeSummary('project-a', limit: 5);
      expect(
        state.getProjectChangeSummaryRunStatus('project-a')?.isRunning,
        isTrue,
      );

      final result = await future;
      final status = state.getProjectChangeSummaryRunStatus('project-a');
      final draft = await state.getLatestProjectChangeSummaryDraft('project-a');

      expect(result.isSuccess, isTrue);
      expect(status?.isRunning, isFalse);
      expect(status?.output, contains('background'));
      expect(status?.error, isNull);
      expect(draft?.body, contains('background'));
    },
  );
}

class _FakeOllama {
  final HttpServer _server;
  final String responseText;
  final Duration delay;
  final List<Map<String, dynamic>> requests = [];

  _FakeOllama._(this._server, this.responseText, this.delay);

  String get host => 'http://${_server.address.host}:${_server.port}';

  static Future<_FakeOllama> start(
    String responseText, {
    Duration delay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeOllama._(server, responseText, delay);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.trim().isNotEmpty) {
      requests.add(jsonDecode(body) as Map<String, dynamic>);
    }
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'message': {'content': responseText},
      }),
    );
    await request.response.close();
  }
}
