// Regression test for the A1 "resubscribe storm":
// After caching the Drift stream in didChangeDependencies with ??=, a mutation
// via AppState must NOT reset the Today list to a loading/waiting state.
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
    'mutating a work item does not flash a loading spinner on Today screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDb.withExecutor(NativeDatabase.memory());
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(() async {
        state.dispose();
        await db.close();
      });

      // Seed a general work item that will appear in watchAllActiveWorkItems.
      final itemId = await state.addGeneralWorkItem(
        'Fix the resubscribe storm',
        status: 'next',
      );

      await tester.pumpWidget(
        AppStateScope(
          state: state,
          // Use the real app theme so ThemeExtension<AtlasColors> lookups
          // (with `!`) succeed like they do in production.
          child: MaterialApp(theme: buildAtlasTheme(), home: const TodayScreen()),
        ),
      );

      // Let the stream emit its first batch and all animations settle.
      await tester.pumpAndSettle();

      // The item should be visible now (in the task-list section).
      expect(find.text('Fix the resubscribe storm'), findsOneWidget);
      // No spinner on initial load.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Perform a mutation that keeps the item active (next → doing).
      // This calls notifyListeners() which rebuilds AppStateScope consumers
      // and, before the fix, caused StreamBuilder to see a new Stream object,
      // resetting connectionState to waiting and blanking the UI.
      await state.setWorkItemStatus(itemId, 'doing');

      // Pump exactly one frame — the critical moment where the old bug would
      // show a spinner because connectionState == waiting.
      await tester.pump();

      // After the fix: the spinner must NOT appear.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // The item row must still be present (not replaced by blank/loading UI).
      // Once the item is 'doing' it renders in both the Doing bucket and the
      // task list, so accept one-or-more matches.
      expect(find.text('Fix the resubscribe storm'), findsAtLeastNWidgets(1));

      // Allow everything to settle cleanly.
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Fix the resubscribe storm'), findsAtLeastNWidgets(1));

      // Unmount the tree so TodayScreen.dispose cancels its midnight timer,
      // then advance fake time so drift's stream keep-alive timer (scheduled
      // when the last subscriber detaches) fires before the binding's
      // pending-timer invariant check.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
    },
  );
}
