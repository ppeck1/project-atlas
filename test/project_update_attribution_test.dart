import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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
}
