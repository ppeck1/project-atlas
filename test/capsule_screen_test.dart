import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/app/theme.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/features/capsule/capsule_screen.dart';
import 'package:project_atlas/services/atlas_agent_service.dart';
import 'package:project_atlas/services/project_capsule_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';
import 'package:project_atlas/shared/models/app_state_scope.dart';

void main() {
  testWidgets(
    'renders the resume contract at Act, Understand, and Audit depths',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDb.withExecutor(NativeDatabase.memory());
      final state = AppState(db, enableBackgroundSummaryRefresh: false);
      addTearDown(() async {
        state.dispose();
        await db.close();
      });

      await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
      await db.updateProjectMeta('atlas', {
        'description': 'A governed local project command center.',
        'desiredOutcome': 'Resume without reconstructing context.',
        'successCriteria': 'Choose one justified action quickly.',
        'phase': 'build',
        'priority': 'high',
      });
      await state.addWorkItemToProject(
        'atlas',
        'Build capsule resume surface',
        readiness: 'ready',
        suggestedActor: 'codex',
        verificationNeeded: 'tests',
        nextAction: 'Implement the read-only vertical slice.',
      );
      final capsule = await _capsule(state, 'atlas');

      await tester.pumpWidget(_harness(state, loader: (_) async => capsule));
      await _pumpFrames(tester);

      expect(find.text('Project Capsule'), findsOneWidget);
      expect(find.text('Resume with shared project truth'), findsOneWidget);
      expect(find.text('Sources & Health'), findsOneWidget);
      expect(find.text('Act'), findsOneWidget);
      expect(find.text('Understand'), findsOneWidget);
      expect(find.text('Audit'), findsOneWidget);
      expect(find.text('Recommended next action'), findsOneWidget);
      expect(find.text('Build capsule resume surface'), findsOneWidget);
      expect(find.textContaining('Why here:'), findsOneWidget);
      expect(find.textContaining('Moves forward when:'), findsWidgets);

      await tester.tap(find.text('Understand'));
      await _pumpFrames(tester);
      expect(find.text('Intent'), findsOneWidget);
      expect(
        find.text('Resume without reconstructing context.'),
        findsOneWidget,
      );
      expect(find.text('Accepted project state'), findsOneWidget);

      await tester.tap(find.text('Audit'));
      await _pumpFrames(tester);
      expect(find.text('Freshness preflight'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Acceptance boundary'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('capsule-audit-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Acceptance boundary'), findsOneWidget);
      expect(
        find.textContaining('Agent output remains a proposal'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
    },
  );

  testWidgets('switches projects without retaining the prior capsule', (
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

    await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
    await db.createProject('other', 'Other Project', DateTime.utc(2026));
    await db.updateProjectMeta('other', {
      'desiredOutcome': 'Prove project switching is coherent.',
    });
    final capsules = {
      'atlas': await _capsule(state, 'atlas'),
      'other': await _capsule(state, 'other'),
    };

    await tester.pumpWidget(
      _harness(state, loader: (projectId) async => capsules[projectId]),
    );
    await _pumpFrames(tester);
    expect(find.text('Project Atlas'), findsWidgets);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Project Atlas'));
    await _pumpFrames(tester);
    expect(find.text('Other Project'), findsOneWidget);
    await tester.tap(find.text('Other Project'));
    await _pumpFrames(tester);

    expect(find.text('Other Project'), findsWidgets);
    await tester.tap(find.text('Understand'));
    await _pumpFrames(tester);
    expect(find.text('Prove project switching is coherent.'), findsOneWidget);
    expect(find.text('Resume without reconstructing context.'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('shows an explicit empty state', (tester) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await tester.pumpWidget(_harness(state));
    await _pumpFrames(tester);

    expect(find.text('No projects to resume'), findsOneWidget);
    expect(find.text('Open Projects'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('default loader completes from one-shot database reads', (
    tester,
  ) async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    await db.createProject('atlas', 'Project Atlas', DateTime.utc(2026));
    await state.addWorkItemToProject(
      'atlas',
      'Exercise the real capsule loader',
      readiness: 'ready',
      suggestedActor: 'codex',
    );

    await tester.pumpWidget(_harness(state));
    await _pumpFrames(tester);

    expect(find.text('Recommended next action'), findsOneWidget);
    expect(find.text('Exercise the real capsule loader'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  });
}

Widget _harness(AppState state, {ProjectCapsuleLoader? loader}) =>
    AppStateScope(
      state: state,
      child: MaterialApp(
        theme: buildAtlasTheme(),
        home: CapsuleScreen(loader: loader),
      ),
    );

Future<ProjectCapsuleSnapshot?> _capsule(AppState state, String projectId) =>
    ProjectCapsuleService(
      AtlasAgentProjectCapsuleSource(AtlasAgentService(state)),
      now: () => DateTime.utc(2026, 7, 17, 12),
    ).buildSnapshot(projectId);

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
