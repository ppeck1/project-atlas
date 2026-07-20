import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../services/project_runtime_service.dart' as runtime;
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_runtime_section.dart';

class ProjectCommandToolbar extends StatefulWidget {
  final String projectId;
  final Future<void> Function() onOpenWorkboard;
  final VoidCallback onEditMeta;
  final VoidCallback onExportBundle;
  final VoidCallback onRecovery;

  const ProjectCommandToolbar({
    super.key,
    required this.projectId,
    required this.onOpenWorkboard,
    required this.onEditMeta,
    required this.onExportBundle,
    required this.onRecovery,
  });

  @override
  State<ProjectCommandToolbar> createState() => _ProjectCommandToolbarState();
}

class _ProjectCommandToolbarState extends State<ProjectCommandToolbar> {
  bool _openingWorkboard = false;
  bool _launching = false;
  bool _testing = false;
  bool _checkingCapsule = false;

  Stream<ProjectRuntimeProfile?>? _watchRuntimeProfile;
  Stream<List<ProjectRuntimeRun>>? _watchRuntimeRuns;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchRuntimeProfile ??= AppStateScope.of(
      context,
    ).watchProjectRuntimeProfile(widget.projectId);
    _watchRuntimeRuns ??= AppStateScope.of(
      context,
    ).watchProjectRuntimeRuns(widget.projectId, limit: 5);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceDeep,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: StreamBuilder<ProjectRuntimeProfile?>(
        stream: _watchRuntimeProfile,
        builder: (context, profileSnap) {
          final profile = profileSnap.data;
          final runtimeReady = profile != null && profile.enabled;
          final tests = profile == null
              ? const <String>[]
              : runtime.decodeStringList(profile.testCommandsJson);
          final capsuleEnabled = profile?.capsuleEnabled ?? false;
          return StreamBuilder<List<ProjectRuntimeRun>>(
            stream: _watchRuntimeRuns,
            builder: (context, runSnap) {
              final runs = runSnap.data ?? const <ProjectRuntimeRun>[];
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ProjectToolbarButton(
                    tooltip: 'Open work board',
                    icon: Icons.view_kanban_outlined,
                    label: 'Work board',
                    busy: _openingWorkboard,
                    onPressed: () async {
                      if (_openingWorkboard) return;
                      setState(() => _openingWorkboard = true);
                      try {
                        await widget.onOpenWorkboard();
                      } finally {
                        if (mounted) {
                          setState(() => _openingWorkboard = false);
                        }
                      }
                    },
                  ),
                  _ProjectToolbarButton(
                    tooltip: 'Edit metadata',
                    icon: Icons.edit_note_outlined,
                    label: 'Metadata',
                    onPressed: widget.onEditMeta,
                  ),
                  _ProjectToolbarButton(
                    tooltip: 'Export project bundle',
                    icon: Icons.archive_outlined,
                    label: 'Export',
                    onPressed: widget.onExportBundle,
                  ),
                  _ProjectToolbarButton(
                    tooltip: 'Back up or stage-validate this project',
                    icon: Icons.health_and_safety_outlined,
                    label: 'Recovery',
                    onPressed: widget.onRecovery,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? 'Launch project'
                        : 'No runtime profile configured',
                    icon: Icons.rocket_launch_outlined,
                    label: 'Launch',
                    busy: _launching,
                    color: latestRuntimeRunColor(runs, 'launch', colors),
                    onPressed: runtimeReady
                        ? () => _runRuntimeAction(
                            action: 'launch',
                            body: () =>
                                state.launchProjectRuntime(widget.projectId),
                          )
                        : null,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? (tests.isEmpty ? 'No test command' : 'Run tests')
                        : 'No runtime profile configured',
                    icon: Icons.fact_check_outlined,
                    label: 'Tests',
                    busy: _testing,
                    color: latestRuntimeRunColor(runs, 'test', colors),
                    onPressed: runtimeReady && tests.isNotEmpty
                        ? () => _runRuntimeAction(
                            action: 'test',
                            body: () =>
                                state.runProjectRuntimeTest(widget.projectId),
                            showResult: true,
                          )
                        : null,
                  ),
                  _ProjectToolbarButton(
                    tooltip: runtimeReady
                        ? (capsuleEnabled
                              ? 'Run capsule check'
                              : 'Capsule disabled')
                        : 'No runtime profile configured',
                    icon: Icons.health_and_safety_outlined,
                    label: 'Capsule',
                    busy: _checkingCapsule,
                    color: latestRuntimeRunColor(runs, 'capsule', colors),
                    onPressed: runtimeReady && capsuleEnabled
                        ? () => _runRuntimeAction(
                            action: 'capsule',
                            body: () => state.runProjectRuntimeCapsule(
                              widget.projectId,
                            ),
                            showResult: true,
                          )
                        : null,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _runRuntimeAction({
    required String action,
    required Future<ProjectRuntimeRun> Function() body,
    bool showResult = false,
  }) async {
    if (_isBusy(action)) return;
    final label = runtimeActionLabel(action);
    setState(() => _setBusy(action, true));
    try {
      final run = await body();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(runtimeRunMessage(label, run))));
      if (showResult && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => RuntimeRunDialog(run: run, label: label),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label failed: $error')));
    } finally {
      if (mounted) setState(() => _setBusy(action, false));
    }
  }

  bool _isBusy(String action) => switch (action) {
    'launch' => _launching,
    'test' => _testing,
    'capsule' => _checkingCapsule,
    _ => false,
  };

  void _setBusy(String action, bool value) {
    switch (action) {
      case 'launch':
        _launching = value;
        break;
      case 'test':
        _testing = value;
        break;
      case 'capsule':
        _checkingCapsule = value;
        break;
    }
  }
}

class _ProjectToolbarButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final String label;
  final bool busy;
  final Color? color;
  final VoidCallback? onPressed;

  const _ProjectToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.label,
    this.busy = false,
    this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final effectiveColor = enabled ? color : Colors.white24;
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 16, color: effectiveColor),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 36),
        ),
      ),
    );
  }
}
