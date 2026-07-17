// Regression test for the D2 follow-up: the Today task list reads its
// tag/project context from cached Drift streams, so tag mutations must show
// up WITHOUT AppState.notifyListeners() (the tag CRUD methods no longer
// notify) and without the removed _taskListRevision counter.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/app/theme.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/features/today/today_screen.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';

void main() {
  testWidgets(
    'tag assignment and rename propagate to the Today list via streams',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDb.withExecutor(NativeDatabase.memory());
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(() async {
        state.dispose();
        await db.close();
      });

      // Seed a general work item that appears in watchAllActiveWorkItems.
      final itemId = await state.addGeneralWorkItem(
        'Tag stream check',
        status: 'next',
      );

      await tester.pumpWidget(
        AppStateScope(
          state: state,
          child: MaterialApp(
            theme: buildAtlasTheme(),
            home: const TodayScreen(),
          ),
        ),
      );

      // Let all cached streams emit their first batch before mutating.
      await tester.pumpAndSettle();
      expect(find.text('Tag stream check'), findsAtLeastNWidgets(1));
      expect(find.text('errand'), findsNothing);

      // Mutation 1: create a tag and assign it to the work item. This writes
      // the hand-managed work_item_tags table; the explicit notifyUpdates in
      // AppDb must re-run watchWorkItemTags. No notifyListeners fires.
      final tagId = await state.saveTag(name: 'errand');
      await state.setWorkItemTags(itemId, {tagId});
      await tester.pumpAndSettle();

      // The chip renders in the task list (and the tag also appears in the
      // filter dropdown's item stack), so accept one-or-more matches.
      expect(find.text('errand'), findsAtLeastNWidgets(1));

      // Mutation 2: rename the tag. The tags-table stream must refresh the
      // chip text everywhere.
      await state.updateTag(tagId, name: 'chores');
      await tester.pumpAndSettle();
      expect(find.text('errand'), findsNothing);
      expect(find.text('chores'), findsAtLeastNWidgets(1));

      // No loading UI may appear as a side effect of the mutations.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Unmount so TodayScreen.dispose cancels its midnight timer, then
      // advance fake time so drift's stream keep-alive timer fires before the
      // binding's pending-timer invariant check.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
    },
  );
}
