import 'package:flutter/material.dart';

import '../../../db/app_db.dart';
import '../../../services/project_runtime_service.dart' as runtime;
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

class ProjectRuntimeSection extends StatefulWidget {
  final String projectId;
  final VoidCallback onEdit;

  const ProjectRuntimeSection({
    super.key,
    required this.projectId,
    required this.onEdit,
  });

  @override
  State<ProjectRuntimeSection> createState() => _ProjectRuntimeSectionState();
}

class _ProjectRuntimeSectionState extends State<ProjectRuntimeSection> {
  bool _launching = false;
  String? _testingCommand;
  bool _checkingCapsule = false;

  Stream<ProjectRuntimeProfile?>? _watchRuntimeProfile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchRuntimeProfile ??=
        AppStateScope.of(context).watchProjectRuntimeProfile(widget.projectId);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return StreamBuilder<ProjectRuntimeProfile?>(
      stream: _watchRuntimeProfile,
      builder: (context, profileSnap) {
        final profile = profileSnap.data;
        if (profileSnap.connectionState == ConnectionState.waiting &&
            profileSnap.data == null) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        if (profile == null || !profile.enabled) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'No runtime profile configured.',
                style: TextStyle(fontSize: 13, color: Colors.white38),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: widget.onEdit,
                icon: const Icon(Icons.settings_outlined, size: 16),
                label: const Text('Configure runtime'),
              ),
            ],
          );
        }
        final tests = runtime.decodeStringList(profile.testCommandsJson);
        final ports = runtime.decodeIntList(profile.portsJson);
        final urls = runtime.decodeRuntimeUrls(profile.urlsJson);
        final healthUrls = runtime.decodeStringList(profile.healthUrlsJson);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MiniPill('Mode', profile.enabled ? 'enabled' : 'off'),
                if (profile.capsuleEnabled)
                  MiniPill('Preflight', profile.capsuleMode)
                else
                  const MiniPill('Preflight', 'off'),
                if (profile.autostart) const MiniPill('Autostart', 'yes'),
                if (ports.isNotEmpty) MiniPill('Ports', ports.join(', ')),
              ],
            ),
            const SizedBox(height: 10),
            FieldRow(
              label: 'Working directory',
              value: profile.workingDirectory,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            Divider(height: 1, color: colors.line.withAlpha(0x44)),
            FieldRow(
              label: 'Launch command',
              value: profile.launchCommand,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            Divider(height: 1, color: colors.line.withAlpha(0x44)),
            FieldRow(
              label: 'Stop command',
              value: profile.stopCommand,
              placeholder: 'Not configured',
              onEdit: widget.onEdit,
            ),
            if (urls.isNotEmpty) ...[
              Divider(height: 1, color: colors.line.withAlpha(0x44)),
              FieldRow(
                label: 'URLs',
                value: urls.map((url) => '${url.label}: ${url.url}').join('\n'),
                placeholder: '',
              ),
            ],
            if (healthUrls.isNotEmpty) ...[
              Divider(height: 1, color: colors.line.withAlpha(0x44)),
              FieldRow(
                label: 'Health URLs',
                value: healthUrls.join('\n'),
                placeholder: '',
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _launching
                      ? null
                      : () => _runRuntimeAction(
                          label: 'Launch',
                          busy: 'launch',
                          body: () =>
                              state.launchProjectRuntime(widget.projectId),
                        ),
                  icon: _launching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined, size: 16),
                  label: const Text('Launch'),
                ),
                OutlinedButton.icon(
                  onPressed: profile.capsuleEnabled && !_checkingCapsule
                      ? () => _runRuntimeAction(
                          label: 'Protocol preflight',
                          busy: 'capsule',
                          body: () =>
                              state.runProjectRuntimeCapsule(widget.projectId),
                          showResult: true,
                        )
                      : null,
                  icon: _checkingCapsule
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.health_and_safety_outlined, size: 16),
                  label: const Text('Preflight'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_note_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (tests.isEmpty)
              const Text(
                'No test commands configured.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              )
            else ...[
              const Text(
                'Tests',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...tests.map(
                (command) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          command,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _testingCommand == null
                            ? () => _runRuntimeAction(
                                label: 'Test',
                                busy: 'test',
                                command: command,
                                body: () => state.runProjectRuntimeTest(
                                  widget.projectId,
                                  command: command,
                                ),
                                showResult: true,
                              )
                            : null,
                        icon: _testingCommand == command
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check_outlined, size: 16),
                        label: const Text('Run'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _RuntimeRunHistory(projectId: widget.projectId),
          ],
        );
      },
    );
  }

  Future<void> _runRuntimeAction({
    required String label,
    required String busy,
    required Future<ProjectRuntimeRun> Function() body,
    String? command,
    bool showResult = false,
  }) async {
    setState(() {
      if (busy == 'launch') _launching = true;
      if (busy == 'capsule') _checkingCapsule = true;
      if (busy == 'test') _testingCommand = command ?? '';
    });
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
      if (mounted) {
        setState(() {
          if (busy == 'launch') _launching = false;
          if (busy == 'capsule') _checkingCapsule = false;
          if (busy == 'test') _testingCommand = null;
        });
      }
    }
  }
}

class _RuntimeRunHistory extends StatefulWidget {
  final String projectId;

  const _RuntimeRunHistory({required this.projectId});

  @override
  State<_RuntimeRunHistory> createState() => _RuntimeRunHistoryState();
}

class _RuntimeRunHistoryState extends State<_RuntimeRunHistory> {
  Stream<List<ProjectRuntimeRun>>? _watchRuntimeRuns;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchRuntimeRuns ??= AppStateScope.of(context)
        .watchProjectRuntimeRuns(widget.projectId, limit: 8);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return StreamBuilder<List<ProjectRuntimeRun>>(
      stream: _watchRuntimeRuns,
      builder: (context, snap) {
        final runs = snap.data ?? const <ProjectRuntimeRun>[];
        if (runs.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recent runtime runs',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            ...runs.map(
              (run) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _runtimeRunIcon(run),
                  size: 18,
                  color: _runtimeRunColor(run, colors),
                ),
                title: Text(
                  '${run.action} - ${run.status}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${compactDateTime(run.startedAt)}'
                  '${run.capsuleStatus == null ? '' : ' - preflight ${run.capsuleStatus}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right, size: 16),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => RuntimeRunDialog(
                    run: run,
                    label: runtimeActionLabel(run.action),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class RuntimeRunDialog extends StatelessWidget {
  final ProjectRuntimeRun run;
  final String label;

  const RuntimeRunDialog({super.key, required this.run, required this.label});

  @override
  Widget build(BuildContext context) {
    final text = [
      'Status: ${run.status}',
      'Started: ${compactDateTime(run.startedAt)}',
      if (run.completedAt != null)
        'Completed: ${compactDateTime(run.completedAt)}',
      if ((run.capsuleStatus ?? '').isNotEmpty)
        'Protocol preflight: ${run.capsuleStatus}',
      if ((run.command ?? '').isNotEmpty) 'Command: ${run.command}',
      if (run.exitCode != null) 'Exit code: ${run.exitCode}',
      if ((run.outputText ?? '').isNotEmpty) '\nOutput:\n${run.outputText}',
      if ((run.errorText ?? '').isNotEmpty) '\nError:\n${run.errorText}',
      if ((run.capsuleOutputText ?? '').isNotEmpty)
        '\nProtocol preflight output:\n${run.capsuleOutputText}',
    ].join('\n');
    return AlertDialog(
      title: Text('$label result'),
      content: SizedBox(
        width: 760,
        height: 480,
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

IconData _runtimeRunIcon(ProjectRuntimeRun run) => switch (run.action) {
  'launch' => Icons.rocket_launch_outlined,
  'test' => Icons.fact_check_outlined,
  'capsule' => Icons.health_and_safety_outlined,
  _ => Icons.terminal_outlined,
};

Color _runtimeRunColor(ProjectRuntimeRun run, AtlasColors colors) =>
    switch (run.status) {
      'succeeded' || 'started' => const Color(0xFF4CAF50),
      'running' => colors.primary,
      'failed' => const Color(0xFFFF8A80),
      _ => Colors.white54,
    };

Color latestRuntimeRunColor(
  List<ProjectRuntimeRun> runs,
  String action,
  AtlasColors colors,
) {
  for (final run in runs) {
    if (run.action == action) return _runtimeRunColor(run, colors);
  }
  return Colors.white54;
}

String runtimeActionLabel(String action) => switch (action) {
  'launch' => 'Launch',
  'test' => 'Test',
  'capsule' => 'Protocol preflight',
  _ => action,
};

String runtimeRunMessage(String label, ProjectRuntimeRun run) {
  final capsule = (run.capsuleStatus ?? '').isEmpty
      ? ''
      : ' Protocol preflight: ${run.capsuleStatus}.';
  if (run.status == 'started') return '$label started.$capsule';
  if (run.status == 'succeeded') return '$label succeeded.$capsule';
  return '$label ${run.status}.$capsule';
}
