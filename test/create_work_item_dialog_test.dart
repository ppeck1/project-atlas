import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';
import 'package:project_atlas/shared/widgets/create_work_item_dialog.dart';

void main() {
  testWidgets('create work item dialog exposes workload planning fields', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    Map<String, String?>? draft;
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  draft = await showCreateWorkItemDialog(context);
                },
                child: const Text('Open dialog'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Readiness'), findsOneWidget);
    expect(find.text('Size'), findsOneWidget);
    expect(find.text('Risk'), findsOneWidget);
    expect(find.text('Actor'), findsOneWidget);
    expect(find.text('Verification needed'), findsOneWidget);
    expect(find.text('Next action'), findsOneWidget);
    expect(find.text('Planning notes'), findsOneWidget);
    expect(find.text('Blocker reason'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Plan release notes');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(draft, isNotNull);
    expect(draft!['title'], 'Plan release notes');
    expect(draft!['readiness'], 'ready');
    expect(draft!['size'], 'medium');
    expect(draft!['risk'], 'low_code');
    expect(draft!['suggestedActor'], 'user');
    expect(draft!['verificationNeeded'], 'none');
  });
}
