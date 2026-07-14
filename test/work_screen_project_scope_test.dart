import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/features/work/work_screen.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';

void main() {
  testWidgets('project-scoped workboard locks the project filter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await db.createProject('shop', 'Catalog Sync Demo', DateTime(2026));
    await db.createProject('other', 'Other Project', DateTime(2026));

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: const MaterialApp(
          home: WorkScreen(initialProjectId: 'shop', projectScoped: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Project scoped'), findsOneWidget);
    expect(find.text('Catalog Sync Demo'), findsOneWidget);
    expect(find.text('All projects'), findsNothing);
    final projectDropdown = tester.widget<DropdownButtonFormField<String?>>(
      find.byType(DropdownButtonFormField<String?>).first,
    );
    expect(projectDropdown.onChanged, isNull);
  });
}
