import 'package:go_router/go_router.dart';

import '../shared/widgets/atlas_shell.dart';
import '../features/today/today_screen.dart';
import '../features/projects/projects_screen.dart';
import '../features/projects/project_detail_screen.dart';
import '../features/capsule/capsule_screen.dart';
import '../features/operations/operations_screen.dart';
import '../features/library/library_screen.dart';
import '../features/settings/settings_screen.dart';
// Legacy screens kept accessible via deep links
import '../features/work/work_screen.dart';
import '../features/review/review_screen.dart';
import '../features/export/export_screen.dart';
import '../features/governance/governance_screen.dart';
import '../features/log/log_screen.dart';
import '../features/dashboard/dashboard_screen.dart';

GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/today',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AtlasShell(child: child),
        routes: [
          GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
          GoRoute(
            path: '/projects',
            builder: (_, __) => const ProjectsScreen(),
          ),
          GoRoute(
            path: '/projects/:id',
            builder: (_, state) =>
                ProjectDetailScreen(projectId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/capsule', builder: (_, __) => const CapsuleScreen()),
          GoRoute(
            path: '/operations',
            builder: (_, __) => const OperationsScreen(),
          ),
          GoRoute(
            path: '/library',
            builder: (_, state) => LibraryScreen(
              initialEntryId: state.uri.queryParameters['entryId'],
              initialEntryType: state.uri.queryParameters['entryType'],
              initialProjectId: state.uri.queryParameters['projectId'],
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
          ),
          // Legacy routes — still navigable (e.g. from Settings tabs)
          GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
          GoRoute(
            path: '/work',
            builder: (_, state) => WorkScreen(
              initialProjectId: state.uri.queryParameters['projectId'],
              projectScoped: state.uri.queryParameters['scope'] == 'project',
            ),
          ),
          GoRoute(path: '/review', builder: (_, __) => const ReviewScreen()),
          GoRoute(path: '/export', builder: (_, __) => const ExportScreen()),
          GoRoute(
            path: '/governance',
            builder: (_, __) => const GovernanceScreen(),
          ),
          GoRoute(path: '/log', builder: (_, __) => const LogScreen()),
        ],
      ),
    ],
  );
}
