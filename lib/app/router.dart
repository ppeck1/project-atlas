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
          GoRoute(path: '/', builder: (context, state) => const DashboardScreen()),
          GoRoute(path: '/projects', builder: (context, state) => const ProjectsScreen()),
          GoRoute(path: '/today', builder: (context, state) => const TodayScreen()),
          GoRoute(path: '/work', builder: (context, state) => const WorkScreen()),
          GoRoute(path: '/governance', builder: (context, state) => const GovernanceScreen()),
          GoRoute(path: '/review', builder: (context, state) => const ReviewScreen()),
          GoRoute(path: '/export', builder: (context, state) => const ExportScreen()),
          GoRoute(path: '/library', builder: (context, state) => const LibraryScreen()),
          GoRoute(path: '/log', builder: (context, state) => const LogScreen()),
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
        ],
      ),
    ],
  );
}
