// Widget tests for AtlasLegacyRouteBar.
//
// AtlasLegacyRouteBar is a standalone widget that requires only:
//   - a theme with the AtlasColors extension (supplied by buildAtlasTheme())
//   - a Navigator ancestor (supplied by MaterialApp)
//   - no GoRouter needed for render tests; the back-button tap test stubs
//     Navigator.canPop via a spy route.
//
// We do NOT pump AtlasShell here — that requires a full GoRouter context.
// Instead we test the extracted bar widget directly (the integration with the
// shell's conditional guard is covered by reading the shell source + the
// unit tests in atlas_nav_selection_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/app/theme.dart';
import 'package:project_atlas/shared/widgets/atlas_shell.dart';

/// Wraps [child] in a minimal themed MaterialApp so AtlasColors lookups work.
Widget _themed(Widget child) {
  return MaterialApp(
    theme: buildAtlasTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('AtlasLegacyRouteBar', () {
    testWidgets('renders the back arrow icon', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/review'),
      ));
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('shows humanized label for /review', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/review'),
      ));
      expect(find.text('Review'), findsOneWidget);
    });

    testWidgets('shows humanized label for /export', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/export'),
      ));
      expect(find.text('Export'), findsOneWidget);
    });

    testWidgets('shows humanized label for /governance', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/governance'),
      ));
      expect(find.text('Governance'), findsOneWidget);
    });

    testWidgets('shows humanized label for /log', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/log'),
      ));
      expect(find.text('Log'), findsOneWidget);
    });

    testWidgets('shows "Home" label for /', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/'),
      ));
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('bar renders at 40 px height', (tester) async {
      await tester.pumpWidget(_themed(
        const AtlasLegacyRouteBar(path: '/export'),
      ));
      // The bar is the outermost widget; measure the render size of the bar
      // itself via its key-less type.
      final size = tester.getSize(find.byType(AtlasLegacyRouteBar));
      expect(size.height, 40.0);
    });

    testWidgets('back button pops when navigator can pop', (tester) async {
      // Build a two-screen navigator: screen 1 → screen 2 (which hosts the
      // bar). Tapping back should pop back to screen 1.
      bool poppedToScreen1 = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAtlasTheme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: Column(
                          children: [
                            const AtlasLegacyRouteBar(path: '/review'),
                            const Text('screen2'),
                          ],
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
          navigatorObservers: [
            _PopObserver(onPop: () => poppedToScreen1 = true),
          ],
        ),
      );

      // Navigate to screen 2.
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('screen2'), findsOneWidget);

      // Tap the back button in the bar — should pop.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(poppedToScreen1, isTrue);
      expect(find.text('screen2'), findsNothing);
    });
  });
}

class _PopObserver extends NavigatorObserver {
  final VoidCallback onPop;
  _PopObserver({required this.onPop});

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onPop();
  }
}
