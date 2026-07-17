import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../db/app_db.dart';
import '../models/app_state_scope.dart';
import '../theme/atlas_colors.dart';

/// Maximum number of rows shown in the palette result list.
const int kAtlasCommandPaletteMaxResults = 15;

/// Opens the Ctrl+K "jump to project" command palette.
///
/// Resolves once the dialog closes. If the user picked a project, navigates
/// to its detail route (`/projects/:id`) — matching how the rest of the app
/// navigates to project detail (see e.g. projects_screen.dart).
Future<void> showAtlasCommandPalette(BuildContext context) async {
  // One-shot read, hoisted out of the builder (which reruns during the
  // dialog's open animation).
  final projectsFuture = AppStateScope.read(context).getVisibleProjects();
  final projectId = await showDialog<String>(
    context: context,
    builder: (_) => AtlasCommandPalette(projects: projectsFuture),
  );
  if (projectId == null || !context.mounted) return;
  context.go('/projects/$projectId');
}

/// Search-and-jump dialog: type to filter projects by title, Up/Down to move
/// the highlight, Enter (or click) to select. Pops with the chosen project id,
/// or null when dismissed.
class AtlasCommandPalette extends StatefulWidget {
  /// One-shot read of the project list. The palette is short-lived, so a
  /// Future (rather than a watch stream) keeps it simple.
  final Future<List<Project>> projects;

  const AtlasCommandPalette({super.key, required this.projects});

  @override
  State<AtlasCommandPalette> createState() => _AtlasCommandPaletteState();
}

class _AtlasCommandPaletteState extends State<AtlasCommandPalette> {
  final _searchCtrl = TextEditingController();
  List<Project> _all = const [];
  bool _loaded = false;
  String _query = '';
  int _highlighted = 0;
  // Enter can arrive through both the CallbackShortcuts binding and the
  // TextField's onSubmitted; guard so we only pop once.
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.projects.then((rows) {
      if (!mounted) return;
      final sorted = [...rows]
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      setState(() {
        _all = sorted;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Project> _filtered() {
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty
        ? _all
        : _all.where((p) => p.title.toLowerCase().contains(q)).toList();
    return rows.length > kAtlasCommandPaletteMaxResults
        ? rows.sublist(0, kAtlasCommandPaletteMaxResults)
        : rows;
  }

  static int _clampIndex(int value, int maxIndex) {
    if (value < 0) return 0;
    if (value > maxIndex) return maxIndex;
    return value;
  }

  void _moveHighlight(int delta) {
    final rows = _filtered();
    if (rows.isEmpty) return;
    setState(
      () => _highlighted = _clampIndex(_highlighted + delta, rows.length - 1),
    );
  }

  void _selectHighlighted() {
    final rows = _filtered();
    if (rows.isEmpty) return;
    _select(rows[_clampIndex(_highlighted, rows.length - 1)]);
  }

  void _select(Project project) {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).pop(project.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final rows = _filtered();
    final highlighted = rows.isEmpty
        ? -1
        : _clampIndex(_highlighted, rows.length - 1);

    return Dialog(
      backgroundColor: colors.panel,
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              // CallbackShortcuts sits between the focused EditableText and
              // the app-level DefaultTextEditingShortcuts in the focus chain,
              // so it wins: the arrows drive the highlight instead of the
              // caret, and Enter selects.
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _moveHighlight(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _moveHighlight(-1),
                  const SingleActivator(LogicalKeyboardKey.enter):
                      _selectHighlighted,
                },
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  onChanged: (q) => setState(() {
                    _query = q;
                    _highlighted = 0;
                  }),
                  onSubmitted: (_) => _selectHighlighted(),
                  decoration: InputDecoration(
                    hintText: 'Jump to project...',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: colors.inactive,
                    ),
                    isDense: true,
                    filled: true,
                    fillColor: colors.bg,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.primary),
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: colors.line),
            Flexible(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _loaded ? 'No matching projects.' : 'Loading...',
                        style: TextStyle(color: colors.inactive, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final project = rows[i];
                        final isHighlighted = i == highlighted;
                        return ListTile(
                          dense: true,
                          selected: isHighlighted,
                          selectedTileColor: colors.selectedFill,
                          leading: Icon(
                            Icons.folder_open,
                            size: 18,
                            color: isHighlighted
                                ? colors.primary
                                : colors.inactive,
                          ),
                          title: Text(
                            project.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _select(project),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
