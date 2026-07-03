import 'dart:convert';

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
}
