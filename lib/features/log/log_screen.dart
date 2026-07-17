import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String _level = 'all';
  String _area = 'all';
  Stream<List<EventLogData>>? _eventsStream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _eventsStream ??= AppStateScope.of(context).watchRecentEvents();
  }

  List<EventLogData> _filter(List<EventLogData> rows) => rows.where((e) {
    final levelOk = _level == 'all' || e.level == _level;
    final areaOk = _area == 'all' || e.area == _area;
    return levelOk && areaOk;
  }).toList();

  Future<void> _copyJson(List<EventLogData> rows) async {
    final data = rows
        .map(
          (e) => {
            'id': e.id,
            'timestamp': e.timestamp.toIso8601String(),
            'level': e.level,
            'area': e.area,
            'action': e.action,
            'entity_type': e.entityType,
            'entity_id': e.entityId,
            'input_json': e.inputJson,
            'output_json': e.outputJson,
            'error': e.error,
            'stack_trace': e.stackTrace,
            'correlation_id': e.correlationId,
          },
        )
        .toList();
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied log JSON.')));
  }

  Future<void> _copyMarkdown(List<EventLogData> rows) async {
    final b = StringBuffer('# Project Atlas Event Log\n\n');
    for (final e in rows) {
      b.writeln(
        '## ${e.timestamp.toIso8601String()} — ${e.level.toUpperCase()} — ${e.area}.${e.action}',
      );
      if (e.entityType != null || e.entityId != null)
        b.writeln('- Entity: ${e.entityType ?? ''} ${e.entityId ?? ''}');
      if (e.inputJson != null) b.writeln('- Input: `${e.inputJson}`');
      if (e.outputJson != null) b.writeln('- Output: `${e.outputJson}`');
      if (e.error != null) b.writeln('- Error: `${e.error}`');
      b.writeln();
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Copied log Markdown.')));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backend Log')),
      body: StreamBuilder<List<EventLogData>>(
        stream: _eventsStream,
        builder: (context, snap) {
          final all = snap.data ?? const <EventLogData>[];
          final areas = [
            'all',
            ...{for (final e in all) e.area}.toList()..sort(),
          ];
          final rows = _filter(all);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    DropdownButton<String>(
                      value: _level,
                      items: const ['all', 'debug', 'info', 'warn', 'error']
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text('Level: $v'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _level = v ?? 'all'),
                    ),
                    DropdownButton<String>(
                      value: areas.contains(_area) ? _area : 'all',
                      items: areas
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text('Area: $v'),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _area = v ?? 'all'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copyJson(rows),
                      icon: const Icon(Icons.data_object),
                      label: const Text('Copy JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copyMarkdown(rows),
                      icon: const Icon(Icons.notes),
                      label: const Text('Copy Markdown'),
                    ),
                    TextButton.icon(
                      onPressed: () => state.clearEventLog(),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: rows.isEmpty
                    ? const Center(child: Text('No log events.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final e = rows[i];
                          final color = e.level == 'error'
                              ? Colors.redAccent
                              : e.level == 'warn'
                              ? Colors.orangeAccent
                              : Colors.white70;
                          return Card(
                            child: ExpansionTile(
                              leading: Icon(
                                Icons.circle,
                                size: 10,
                                color: color,
                              ),
                              title: Text('${e.area}.${e.action}'),
                              subtitle: Text(
                                '${e.timestamp} · ${e.level}${e.entityType != null ? ' · ${e.entityType}:${e.entityId ?? ''}' : ''}',
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                0,
                                16,
                                16,
                              ),
                              children: [
                                if (e.inputJson != null)
                                  SelectableText('Input:\n${e.inputJson}'),
                                if (e.outputJson != null)
                                  SelectableText('Output:\n${e.outputJson}'),
                                if (e.error != null)
                                  SelectableText('Error:\n${e.error}'),
                                if (e.stackTrace != null)
                                  SelectableText(
                                    'Stack:\n${e.stackTrace}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
