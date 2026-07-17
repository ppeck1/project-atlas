// Tests for app-level keyboard shortcuts wired in AtlasShell.
//
// Pumping AtlasShell itself requires a full go_router context (GoRouterState),
// which would make the test fragile.  Instead we pump the same
// Shortcuts + Actions + Focus subtree that AtlasShell assembles, which gives
// us full coverage of the shortcut machinery without the router overhead.
// (The Ctrl+K navigation test is the exception: it pumps a minimal two-route
// GoRouter so Enter can exercise the real `/projects/:id` navigation.)
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
import 'package:go_router/go_router.dart';
import 'package:project_atlas/app/theme.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';
import 'package:project_atlas/shared/widgets/atlas_command_palette.dart';
import 'package:project_atlas/shared/widgets/atlas_shortcuts.dart';

/// The same Shortcuts + Actions + Focus subtree that AtlasShell assembles.
///
/// autofocus so the Focus node holds the primary focus and the Shortcuts
/// widget can intercept key events immediately.
Widget _shortcutsSubtree({Widget body = const SizedBox.expand()}) {
  return Shortcuts(
    shortcuts: atlasShortcuts,
    child: Actions(
      actions: atlasActions(),
      child: Focus(autofocus: true, child: Scaffold(body: body)),
    ),
  );
}

Widget _buildHarness({required AppState state}) {
  return AppStateScope(
    state: state,
    child: MaterialApp(
      // Real app theme so ThemeExtension<AtlasColors> lookups succeed in any
      // widget this harness ends up building.
      theme: buildAtlasTheme(),
      home: _shortcutsSubtree(),
    ),
  );
}

/// Harness with a minimal real go_router so command-palette selection can
/// exercise the actual `/projects/:id` navigation.
Widget _buildRouterHarness({
  required AppState state,
  required GoRouter router,
}) {
  return AppStateScope(
    state: state,
    child: MaterialApp.router(theme: buildAtlasTheme(), routerConfig: router),
  );
}

GoRouter _buildTestRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => _shortcutsSubtree()),
      GoRoute(
        path: '/projects/:id',
        builder: (_, state) =>
            Scaffold(body: Text('project:${state.pathParameters['id']}')),
      ),
    ],
  );
}

/// Harness for the `/` shortcut: no db/AppState needed (the slash action only
/// touches the focus registry). [searchFocus] is the registry-registered
/// field; [otherFocus] is an unrelated text field for typing-guard tests.
Widget _buildSlashHarness({
  required FocusNode searchFocus,
  FocusNode? otherFocus,
}) {
  return MaterialApp(
    theme: buildAtlasTheme(),
    home: _shortcutsSubtree(
      body: Column(
        children: [
          TextField(focusNode: searchFocus),
          if (otherFocus != null) TextField(focusNode: otherFocus),
        ],
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

Future<void> _pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
  // Bounded pumps: the palette's autofocused search field cursor never stops
  // animating, so pumpAndSettle would hang.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  // One more frame so the palette's one-shot project load can apply.
  await tester.pump();
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

  testWidgets('Ctrl+K opens the palette, filters, and Enter navigates', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    final router = _buildTestRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_buildRouterHarness(state: state, router: router));
    await tester.pumpAndSettle();

    // Seed two projects the palette can list.
    final alphaId = await state.createProject('Alpha Rocket');
    final betaId = await state.createProject('Beta Garden');
    expect(alphaId, isNotNull);
    expect(betaId, isNotNull);
    await tester.pumpAndSettle();

    expect(find.byType(AtlasCommandPalette), findsNothing);

    await _pressCtrlK(tester);
    expect(find.byType(AtlasCommandPalette), findsOneWidget);
    // Rows are sorted by title: Alpha Rocket, Beta Garden.
    expect(find.text('Alpha Rocket'), findsOneWidget);
    expect(find.text('Beta Garden'), findsOneWidget);

    // Arrow keys move the highlighted row.
    var tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles[0].selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles[0].selected, isFalse);
    expect(tiles[1].selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles[0].selected, isTrue);

    // Typing filters by case-insensitive title substring (and resets the
    // highlight to the first row).
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump();
    expect(find.text('Beta Garden'), findsOneWidget);
    expect(find.text('Alpha Rocket'), findsNothing);

    // Enter selects the highlighted row: palette closes and go_router
    // navigates to the project detail route.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AtlasCommandPalette), findsNothing);
    expect(find.text('project:$betaId'), findsOneWidget);

    await _flushTimers(tester);
  });

  testWidgets('Ctrl+K while palette is open does not open a second palette', (
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

    await _pressCtrlK(tester);
    expect(find.byType(AtlasCommandPalette), findsOneWidget);

    // The guard in OpenCommandPaletteAction should block a second palette.
    await _pressCtrlK(tester);
    expect(find.byType(AtlasCommandPalette), findsOneWidget);

    // Esc dismisses the palette via Flutter's default DismissIntent handling.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AtlasCommandPalette), findsNothing);

    await _flushTimers(tester);
  });

  testWidgets('/ focuses the registered search field', (tester) async {
    final searchFocus = FocusNode(debugLabel: 'search');
    addTearDown(searchFocus.dispose);
    AtlasSearchFocusRegistry.register(searchFocus);
    addTearDown(() => AtlasSearchFocusRegistry.unregister(searchFocus));

    await tester.pumpWidget(_buildSlashHarness(searchFocus: searchFocus));
    await tester.pumpAndSettle();
    expect(searchFocus.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    // Bounded pump: the now-focused search field's cursor blinks forever.
    await tester.pump();

    expect(searchFocus.hasFocus, isTrue);

    await _flushTimers(tester);
  });

  testWidgets('/ while typing in a text field does not steal focus', (
    tester,
  ) async {
    final searchFocus = FocusNode(debugLabel: 'search');
    final otherFocus = FocusNode(debugLabel: 'other');
    addTearDown(() {
      searchFocus.dispose();
      otherFocus.dispose();
    });
    AtlasSearchFocusRegistry.register(searchFocus);
    addTearDown(() => AtlasSearchFocusRegistry.unregister(searchFocus));

    await tester.pumpWidget(
      _buildSlashHarness(searchFocus: searchFocus, otherFocus: otherFocus),
    );
    await tester.pumpAndSettle();

    otherFocus.requestFocus();
    await tester.pump();
    expect(otherFocus.hasFocus, isTrue);

    // With an EditableText focused the action reports itself disabled, which
    // makes ShortcutManager return KeyEventResult.ignored for the keystroke.
    expect(FocusSearchAction().isEnabled(const FocusSearchIntent()), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();

    // Focus stays in the field the user is typing in.
    expect(otherFocus.hasFocus, isTrue);
    expect(searchFocus.hasFocus, isFalse);

    // Note: we can't assert the '/' character is inserted here — simulated
    // raw key events bypass the IME in widget tests, so no text would be
    // inserted regardless of the shortcut. The disabled-action + ignored key
    // result is what lets the real platform text input type the character.

    await _flushTimers(tester);
  });
}
