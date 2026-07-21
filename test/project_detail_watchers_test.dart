import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';

void main() {
  test(
    'project people, risks, and decisions watchers emit mutations',
    () async {
      final db = AppDb.withExecutor(NativeDatabase.memory());
      addTearDown(db.close);
      const projectId = 'watch-project';
      await db.createProject(
        projectId,
        'Watcher project',
        DateTime(2026, 7, 21),
      );

      final peopleUpdate = db
          .watchProjectPeople(projectId)
          .firstWhere((items) => items.length == 1);
      await db.addProjectPerson(projectId, 'Ada', 'Owner', 'Accountable');
      expect((await peopleUpdate).single.name, 'Ada');

      final risksUpdate = db
          .watchProjectRisks(projectId)
          .firstWhere((items) => items.length == 1);
      await db.addProjectRisk(projectId, 'Watcher risk', null, 'medium');
      expect((await risksUpdate).single.title, 'Watcher risk');

      final decisionsUpdate = db
          .watchProjectDecisions(projectId)
          .firstWhere((items) => items.length == 1);
      await db.addProjectDecision(projectId, 'Watcher decision', null, null);
      expect((await decisionsUpdate).single.title, 'Watcher decision');
    },
  );
}
