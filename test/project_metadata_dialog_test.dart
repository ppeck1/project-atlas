import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/features/projects/project_metadata_dialog.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';

void main() {
  testWidgets('metadata dialog opens with a legacy custom phase', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await db.close();
    });

    await db
        .createProject(
          'reference-project',
          'Reference Project',
          DateTime(2026, 1, 1),
        )
        .timeout(const Duration(seconds: 5));
    await db
        .updateProjectMeta('reference-project', {'phase': 'reference'})
        .timeout(const Duration(seconds: 5));
    final project = await db
        .getProjectFull('reference-project')
        .timeout(const Duration(seconds: 5));

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          home: Scaffold(
            body: ProjectMetadataDialog(
              project: project!,
              categories: const [],
              includeOwnerField: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('reference'), findsOneWidget);
  });
}
