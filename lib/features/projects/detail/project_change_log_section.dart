import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/models/app_state.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ProjectChangeLogSection extends StatefulWidget {
  final String projectId;

  const ProjectChangeLogSection({
    super.key,
    required this.projectId,
  });

  @override
  State<ProjectChangeLogSection> createState() =>
      _ProjectChangeLogSectionState();
}

class _ProjectChangeLogSectionState extends State<ProjectChangeLogSection> {
  String _window = '30';
  String _sort = 'newest';
  Future<List<ProjectChangeLogEntry>>? _future;
  String? _changeSummary;
  DateTime? _changeSummaryAt;

  AtlasColors get _colors => Theme.of(context).extension<AtlasColors>()!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) {
      _future = _load();
      _loadLatestChangeSummary();
    }
  }

  @override
  void didUpdateWidget(covariant ProjectChangeLogSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      _future = _load();
      _changeSummary = null;
      _changeSummaryAt = null;
      _loadLatestChangeSummary();
    }
  }

  DateTime? get _since {
    final days = switch (_window) {
      '7' => 7,
      '30' => 30,
      '90' => 90,
      _ => null,
    };
    return days == null ? null : DateTime.now().subtract(Duration(days: days));
  }

  Future<List<ProjectChangeLogEntry>> _load() =>
      AppStateScope.of(context).getProjectChangeLog(
        widget.projectId,
        since: _since,
        limit: 80,
        newestFirst: _sort == 'newest',
      );

  void _loadLatestChangeSummary() {
    final projectId = widget.projectId;
    unawaited(() async {
      final draft = await AppStateScope.of(
        context,
      ).getLatestProjectChangeSummaryDraft(projectId);
      if (!mounted || widget.projectId != projectId || draft == null) return;
      setState(() {
        _changeSummary = draft.body;
        _changeSummaryAt = draft.createdAt;
      });
    }());
  }

  void _refresh() {
    setState(() => _future = _load());
  }

  Future<void> _copyJson(List<ProjectChangeLogEntry> rows) async {
    final data = rows.map((entry) => entry.toJson()).toList();
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${rows.length} project change(s).')),
    );
  }

  Future<void> _copySummary() async {
    final text = _changeSummary;
    if (text == null || text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied change summary.')));
  }

  void _summarizeChanges() {
    final projectId = widget.projectId;
    final future = AppStateScope.of(
      context,
    ).startProjectChangeSummary(projectId, since: _since, limit: 80);
    unawaited(() async {
      try {
        final result = await future;
        if (!mounted) return;
        if (widget.projectId != projectId) return;
        if (result.isSuccess) {
          _loadLatestChangeSummary();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Change summary draft saved.')),
          );
        }
      } catch (error) {
        if (!mounted) return;
        if (widget.projectId != projectId) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Change summary failed: $error')),
        );
      }
    }());
  }

  Color _levelColor(String level) => switch (level) {
    'error' => const Color(0xFFFF8A80),
    'warn' => Colors.amber,
    'debug' => Colors.white38,
    _ => _colors.primary,
  };

  String _formatValue(Object? value) {
    if (value == null) return 'blank';
    final text = '$value'.trim();
    if (text.isEmpty) return 'blank';
    return text.length <= 90 ? text : '${text.substring(0, 90)}...';
  }

  Widget _changedFieldsView(ProjectChangeLogEntry entry) {
    if (entry.changedFields.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _colors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entry.changedFields.entries.map((field) {
          final value = field.value;
          Object? from;
          Object? to;
          if (value is Map) {
            from = value['from'];
            to = value['to'];
          }
          final detail = value is Map
              ? '${_formatValue(from)} -> ${_formatValue(to)}'
              : _formatValue(value);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${field.key}: $detail',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _mapBlock(String label, Map<String, Object?> value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return _rawBlock(label, const JsonEncoder.withIndent('  ').convert(value));
  }

  Widget _rawBlock(String label, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(40),
        border: Border.all(color: _colors.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        '$label:\n$value',
        style: const TextStyle(fontSize: 11, color: Colors.white70),
      ),
    );
  }

  Color _actorTypeColor(String actorType) => switch (actorType) {
    'ai_model' => const Color(0xFFCE93D8),
    'system' => const Color(0xFF90CAF9),
    'mcp' => const Color(0xFFFFCC80),
    'import' => const Color(0xFFA5D6A7),
    _ => _colors.primary,
  };

  Widget _changeRow(ProjectChangeLogEntry entry) {
    final color = _levelColor(entry.level);
    final actorColor = _actorTypeColor(entry.actorType);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: _colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.history, color: color, size: 18),
          title: Text(
            entry.summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${entry.actor} - ${compactDateTime(entry.timestamp)} - ${entry.area}.${entry.action}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
          trailing: Pill(label: entry.level, color: color),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Pill(label: entry.actorType, color: actorColor),
                MiniPill('Source event', entry.sourceEventId),
                if ((entry.entityType ?? '').isNotEmpty)
                  MiniPill('Entity', '${entry.entityType}:${entry.entityId}'),
                if ((entry.correlationId ?? '').isNotEmpty)
                  MiniPill('Correlation', entry.correlationId!),
              ],
            ),
            const SizedBox(height: 8),
            _changedFieldsView(entry),
            _mapBlock('Before', entry.beforeJson),
            _mapBlock('After', entry.afterJson),
            _mapBlock('Input', entry.input),
            _mapBlock('Output', entry.output),
            _rawBlock('Error', entry.error),
            _rawBlock('Stack', entry.stackTrace),
          ],
        ),
      ),
    );
  }

  Widget _changeSummaryPanel(ProjectChangeSummaryRunStatus? runStatus) {
    final running = runStatus?.isRunning == true;
    final error = running ? null : runStatus?.error;
    final summary = _changeSummary;
    if (!running &&
        (summary == null || summary.trim().isEmpty) &&
        (error == null || error.trim().isEmpty)) {
      return const SizedBox.shrink();
    }
    final hasSummary = summary != null && summary.trim().isNotEmpty;
    final showError = !running && !hasSummary && error != null;
    final title = running
        ? 'AI change summary running'
        : hasSummary
        ? 'Latest AI change summary'
        : 'Summary failed';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(
          color: showError ? Colors.redAccent.withAlpha(120) : _colors.line,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                running || hasSummary
                    ? Icons.auto_awesome_outlined
                    : Icons.error_outline,
                color: running || hasSummary ? _colors.primary : Colors.redAccent,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_changeSummaryAt != null)
                MiniPill('Updated', compactDateTime(_changeSummaryAt!)),
              if (hasSummary) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Copy summary',
                  onPressed: _copySummary,
                  icon: const Icon(Icons.copy, size: 16),
                ),
              ],
            ],
          ),
          if (running) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
            const Text(
              'Still running in the background. You can leave this screen; a successful result will be saved to the project.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ] else ...[
            const SizedBox(height: 8),
            SelectableText(
              hasSummary ? summary : (error ?? ''),
              style: TextStyle(
                fontSize: 12,
                color: showError ? Colors.redAccent : Colors.white70,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final runStatus = state.getProjectChangeSummaryRunStatus(widget.projectId);
    final summaryRunning = runStatus?.isRunning == true;
    return FutureBuilder<List<ProjectChangeLogEntry>>(
      future: _future,
      builder: (context, snap) {
        final rows = snap.data ?? const <ProjectChangeLogEntry>[];
        final loading = snap.connectionState != ConnectionState.done;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MiniPill('Changes', '${rows.length}'),
                DropdownButton<String>(
                  value: _window,
                  items: const [
                    DropdownMenuItem(value: '7', child: Text('Last 7 days')),
                    DropdownMenuItem(value: '30', child: Text('Last 30 days')),
                    DropdownMenuItem(value: '90', child: Text('Last 90 days')),
                    DropdownMenuItem(value: 'all', child: Text('All recent')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _window = value;
                      _future = _load();
                    });
                  },
                ),
                DropdownButton<String>(
                  value: _sort,
                  items: const [
                    DropdownMenuItem(
                      value: 'newest',
                      child: Text('Newest first'),
                    ),
                    DropdownMenuItem(
                      value: 'oldest',
                      child: Text('Oldest first'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _sort = value;
                      _future = _load();
                    });
                  },
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                ),
                OutlinedButton.icon(
                  onPressed: rows.isEmpty ? null : () => _copyJson(rows),
                  icon: const Icon(Icons.data_object, size: 16),
                  label: const Text('Copy JSON'),
                ),
                if (state.projectAiSummariesEnabled)
                  OutlinedButton.icon(
                    onPressed: rows.isEmpty || loading || summaryRunning
                        ? null
                        : _summarizeChanges,
                    icon: summaryRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_outlined, size: 16),
                    label: Text(
                      summaryRunning ? 'Summarizing' : 'Summarize changes',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _changeSummaryPanel(runStatus),
            if (snap.hasError)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(18),
                  border: Border.all(color: Colors.red.withAlpha(80)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Change log failed to load: ${snap.error}',
                  style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                ),
              )
            else if (loading)
              const LinearProgressIndicator(minHeight: 2)
            else if (rows.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(6),
                  border: Border.all(color: _colors.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'No project changes in this window.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              )
            else
              ...rows.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _changeRow(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}
