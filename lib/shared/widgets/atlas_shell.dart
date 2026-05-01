import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/models/app_state_scope.dart';

class AtlasShell extends StatelessWidget {
  final Widget child;
  const AtlasShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return StreamBuilder<Object?>(
      stream: state.watchActiveProject(),
      builder: (context, snap) {
        final hasProject = snap.data != null;
        final location = GoRouterState.of(context).uri.toString();
        final isProjects = location.startsWith('/projects');

        if (!hasProject && !isProjects) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) context.go('/projects');
          });
        }

        final destinations = <_NavDest>[
          _NavDest('Projects', Icons.folder_open_outlined, Icons.folder_open, '/projects'),
          if (hasProject) ...[
            _NavDest('Dashboard', Icons.dashboard_outlined, Icons.dashboard, '/'),
            _NavDest('Today', Icons.today_outlined, Icons.today, '/today'),
            _NavDest('Work', Icons.checklist_outlined, Icons.checklist, '/work'),
            _NavDest('Review', Icons.timeline_outlined, Icons.timeline, '/review'),
            _NavDest('Export', Icons.ios_share_outlined, Icons.ios_share, '/export'),
            _NavDest('Library', Icons.library_books_outlined, Icons.library_books, '/library'),
            _NavDest('Governance', Icons.account_tree_outlined, Icons.account_tree, '/governance'),
            _NavDest('Log', Icons.terminal_outlined, Icons.terminal, '/log'),
            _NavDest('Settings', Icons.settings_outlined, Icons.settings, '/settings'),
          ],
        ];

        final selectedIndex = _safeIndexForLocation(
          location: location,
          destinations: destinations,
          hardGate: !hasProject,
        );

        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                labelType: NavigationRailLabelType.all,
                selectedIndex: selectedIndex,
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: Text(d.label),
                    ),
                ],
                onDestinationSelected: (i) {
                  context.go(destinations[i].path);
                },
              ),
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }

  int _safeIndexForLocation({
    required String location,
    required List<_NavDest> destinations,
    required bool hardGate,
  }) {
    if (destinations.isEmpty) return 0;
    if (hardGate) return 0;

    for (var i = 0; i < destinations.length; i++) {
      final p = destinations[i].path;
      if (p == '/' && (location == '/' || location.isEmpty)) return i;
      if (p != '/' && location.startsWith(p)) return i;
    }

    final dash = destinations.indexWhere((d) => d.path == '/');
    return dash >= 0 ? dash : 0;
  }
}

class _NavDest {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
  const _NavDest(this.label, this.icon, this.selectedIcon, this.path);
}
