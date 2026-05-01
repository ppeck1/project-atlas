import 'package:go_router/go_router.dart';

import '../shared/widgets/atlas_shell.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/today/today_screen.dart';
import '../features/projects/projects_screen.dart';
import '../features/work/work_screen.dart';
import '../features/governance/governance_screen.dart';
import '../features/review/review_screen.dart';
import '../features/export/export_screen.dart';
import '../features/library/library_screen.dart';
import '../features/log/log_screen.dart';
import '../features/settings/settings_screen.dart';

GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/projects',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AtlasShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/projects', builder: (_, __) => const ProjectsScreen()),
          GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
          GoRoute(path: '/work', builder: (_, __) => const WorkScreen()),
          GoRoute(path: '/governance', builder: (_, __) => const GovernanceScreen()),
          GoRoute(path: '/review', builder: (_, __) => const ReviewScreen()),
          GoRoute(path: '/export', builder: (_, __) => const ExportScreen()),
          GoRoute(path: '/library', builder: (_, __) => const LibraryScreen()),
          GoRoute(path: '/log', builder: (_, __) => const LogScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
  );
}
