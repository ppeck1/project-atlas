import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/atlas_colors.dart';
import 'atlas_shortcuts.dart';

/// Resolves the selected nav-rail index for [location] against [destinationPaths].
///
/// Returns the index of the longest path in [destinationPaths] that is an
/// exact match or a proper prefix of [location] (i.e. followed by '/').
/// Returns -1 when no destination matches, so callers can suppress highlighting
/// on routes like /review, /export, /governance, /log, and / that don't belong
/// to any nav destination.
int resolveNavSelectedIndex(String location, List<String> destinationPaths) {
  int selectedIndex = -1;
  int bestLen = 0;
  for (var i = 0; i < destinationPaths.length; i++) {
    final p = destinationPaths[i];
    if ((location == p || location.startsWith('$p/')) && p.length > bestLen) {
      selectedIndex = i;
      bestLen = p.length;
    }
  }
  return selectedIndex;
}

class AtlasShell extends StatelessWidget {
  final Widget child;
  const AtlasShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();

    final destinations = <_NavDest>[
      _NavDest('Today', Icons.today_outlined, Icons.today, '/today'),
      _NavDest(
        'Projects',
        Icons.folder_open_outlined,
        Icons.folder_open,
        '/projects',
      ),
      _NavDest('Work', Icons.view_kanban_outlined, Icons.view_kanban, '/work'),
      _NavDest('Ops', Icons.radar_outlined, Icons.radar, '/operations'),
      _NavDest(
        'Library',
        Icons.library_books_outlined,
        Icons.library_books,
        '/library',
      ),
    ];
    const settingsDest = _NavDest(
      'Settings',
      Icons.settings_outlined,
      Icons.settings,
      '/settings',
    );

    final selectedIndex = resolveNavSelectedIndex(
      location,
      destinations.map((d) => d.path).toList(),
    );
    final settingsSelected = location.startsWith('/settings');

    return Shortcuts(
      shortcuts: atlasShortcuts,
      child: Actions(
        actions: atlasActions(),
        child: Focus(
          autofocus: true,
          // Allow the focus node to receive key events without stealing focus
          // from text fields: descendant focus always wins over this node.
          child: Scaffold(
            body: Row(
              children: [
                _AtlasNavRail(
                  destinations: destinations,
                  selectedIndex: settingsSelected ? -1 : selectedIndex,
                  settingsDest: settingsDest,
                  settingsSelected: settingsSelected,
                  onDestinationSelected: (i) =>
                      context.go(destinations[i].path),
                  onSettingsSelected: () => context.go('/settings'),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AtlasNavRail extends StatelessWidget {
  final List<_NavDest> destinations;
  final int selectedIndex;
  final _NavDest settingsDest;
  final bool settingsSelected;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onSettingsSelected;

  const _AtlasNavRail({
    required this.destinations,
    required this.selectedIndex,
    required this.settingsDest,
    required this.settingsSelected,
    required this.onDestinationSelected,
    required this.onSettingsSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;

    return Container(
      width: 72,
      color: colors.panel,
      child: Column(
        children: [
          // Logo mark
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.line)),
            ),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.line),
                  ),
                  child: Icon(
                    Icons.location_on,
                    color: colors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ATLAS',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: colors.primary,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),

          // Main nav items
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    _NavItem(
                      dest: destinations[i],
                      isSelected: selectedIndex == i,
                      onTap: () => onDestinationSelected(i),
                    ),
                ],
              ),
            ),
          ),

          // Settings pinned to bottom
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.line)),
            ),
            child: _NavItem(
              dest: settingsDest,
              isSelected: settingsSelected,
              onTap: onSettingsSelected,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final _NavDest dest;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavItem({
    required this.dest,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? colors.selectedFill : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                isSelected ? dest.selectedIcon : dest.icon,
                size: 22,
                color: isSelected ? colors.primary : colors.inactive,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              dest.label,
              style: TextStyle(
                fontSize: 10,
                color: isSelected ? colors.primary : colors.inactive,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavDest {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
  const _NavDest(this.label, this.icon, this.selectedIcon, this.path);
}
