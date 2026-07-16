// Tests for app-level keyboard shortcuts wired in AtlasShell.
//
// Pumping AtlasShell itself requires a full go_router context (GoRouterState),
// which would make the test fragile.  Instead we pump the same
// Shortcuts + Actions + Focus subtree that AtlasShell assembles, which gives
// us full coverage of the shortcut machinery without the router overhead.
//
// Two fake-async traps handled here:
// - The create-work-item dialog autofocuses its title TextField, whose
//   blinking cursor schedules frames forever, so pumpAndSettle would never
//   settle while the dialog is open. Use bounded pumps once it is open.
// - AppState runs async init (ensureDefaultStages etc.) after construction;
//   db.close() deadlocks if that init is still awaiting fake-async timers.
//   Let the initial pumpAndSettle drive init to completion before the dialog
//   opens, and flush remaining timers before teardown.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';
import 'package:project_atlas/shared/widgets/atlas_shortcuts.dart';

Widget _buildHarness({required AppState state}) {
  return AppStateScope(
    state: state,
    child: MaterialApp(
      home: Shortcuts(
        shortcuts: atlasShortcuts,
        child: Actions(
          actions: atlasActions(),
          // autofocus so the Focus node holds the primary focus and the
          // Shortcuts widget can intercept key events immediately.
          child: Focus(
            autofocus: true,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pressCtrlN(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
  // Bounded pumps: let the dialog route animate in without pumpAndSettle
  // (the dialog's autofocused TextField cursor never stops animating).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Unmounts the tree and advances fake time so the blinking-cursor and
/// drift stream keep-alive timers are gone before teardown and the
/// binding's pending-timer invariant check.
Future<void> _flushTimers(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(minutes: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Ctrl+N opens the create-work-item dialog', (tester) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await tester.pumpWidget(_buildHarness(state: state));
    // Drive AppState's async init to completion (no dialog open yet, so
    // pumpAndSettle terminates).
    await tester.pumpAndSettle();

    // Verify the dialog is not yet present.
    expect(find.text('New task'), findsNothing);

    await _pressCtrlN(tester);

    // The dialog title rendered by showCreateWorkItemDialog is "New task".
    expect(find.text('New task'), findsOneWidget);

    // Dismiss
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('New task'), findsNothing);

    await _flushTimers(tester);
  });

  testWidgets('Ctrl+N while dialog is open does not open a second dialog', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await tester.pumpWidget(_buildHarness(state: state));
    await tester.pumpAndSettle();

    // Open the dialog the first time.
    await _pressCtrlN(tester);
    expect(find.text('New task'), findsOneWidget);

    // Press Ctrl+N again — the guard in NewWorkItemAction should block it.
    await _pressCtrlN(tester);

    // Still exactly one "New task" title on screen.
    expect(find.text('New task'), findsOneWidget);

    await _flushTimers(tester);
  });
}
