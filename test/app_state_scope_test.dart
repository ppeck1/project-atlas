import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';

void main() {
  testWidgets('read does not subscribe a widget to AppStateScope changes', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    var readBuilds = 0;
    var watchedBuilds = 0;

    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          home: Column(
            children: [
              Builder(
                builder: (context) {
                  readBuilds += 1;
                  AppStateScope.read(context);
                  return const Text('read');
                },
              ),
              Builder(
                builder: (context) {
                  watchedBuilds += 1;
                  AppStateScope.of(context);
                  return const Text('watched');
                },
              ),
            ],
          ),
        ),
      ),
    );

    expect(readBuilds, 1);
    expect(watchedBuilds, 1);

    await db.createProject('atlas', 'Atlas', DateTime(2026, 1, 1));
    await tester.pump();

    expect(readBuilds, 1);
    expect(watchedBuilds, 2);
  });
}
