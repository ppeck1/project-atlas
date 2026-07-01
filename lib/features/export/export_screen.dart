import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  bool _generating = false;
  bool _sending = false;
  String _exportText = '';
  String _statusMessage = '';

  Future<void> _generateMarkdown() async {
    final state = AppStateScope.of(context);
    setState(() {
      _generating = true;
      _statusMessage = '';
    });
    try {
      await state.db.logEvent(area: 'export', action: 'export_all_request');
      final items = await state.getAllActiveWorkItems();
      final now = DateTime.now();
      const months = [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final buf = StringBuffer();
      buf.writeln(
        '# Project Atlas - Task Export - ${months[now.month]} ${now.day}, ${now.year}',
      );
      buf.writeln();
      final statusGroups = <String, List<WorkItem>>{
        'doing': [],
        'next': [],
        'inbox': [],
        'waiting': [],
      };
      for (final item in items) {
        statusGroups[item.status]?.add(item);
      }
      void writeGroup(String header, List<WorkItem> groupItems) {
        if (groupItems.isEmpty) return;
        buf.writeln('## $header');
        for (final i in groupItems) {
          final check = i.completed ? 'x' : ' ';
          final due = i.dueAt != null
              ? ' - due ${i.dueAt!.month}/${i.dueAt!.day}'
              : '';
          final owner = i.owner != null ? ' - @${i.owner}' : '';
          final priority = i.priority != 'normal'
              ? ' [${i.priority.toUpperCase()}]'
              : '';
          buf.writeln('- [$check] ${i.title}$priority$due$owner');
          if (i.description != null && i.description!.isNotEmpty)
            buf.writeln('  ${i.description}');
          if (i.blockedReason != null)
            buf.writeln('  BLOCKED: ${i.blockedReason}');
        }
        buf.writeln();
      }

      writeGroup('Doing', statusGroups['doing']!);
      writeGroup('Next', statusGroups['next']!);
      writeGroup('Inbox', statusGroups['inbox']!);
      writeGroup('Waiting', statusGroups['waiting']!);
      final phoneItems = items.where((i) => i.phoneQueue).toList();
      if (phoneItems.isNotEmpty) {
        buf.writeln('## Phone / Follow-up Queue');
        for (final i in phoneItems) {
          buf.writeln('- [ ] ${i.title}');
        }
        buf.writeln();
      }
      await state.db.logEvent(
        area: 'export',
        action: 'export_all_success',
        outputJson: '{"count":${items.length}}',
      );
      if (!mounted) return;
      setState(() => _exportText = buf.toString().trim());
    } catch (e, st) {
      await state.db.logError(
        area: 'export',
        action: 'export_all_failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _statusMessage = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _generateTodayMarkdown() async {
    final state = AppStateScope.of(context);
    setState(() {
      _generating = true;
      _statusMessage = '';
    });
    try {
      await state.db.logEvent(area: 'export', action: 'export_today_request');
      final items = await state.getTodayItems();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      final buf = StringBuffer();
      buf.writeln('# Today - ${now.month}/${now.day}/${now.year}');
      buf.writeln();
      void writeSection(String header, List<WorkItem> sectionItems) {
        if (sectionItems.isEmpty) return;
        buf.writeln('## $header');
        for (final i in sectionItems) {
          final due = i.dueAt != null
              ? ' - ${i.dueAt!.month}/${i.dueAt!.day}'
              : '';
          buf.writeln('- [ ] ${i.title}$due');
          if (i.blockedReason != null)
            buf.writeln('  BLOCKED: ${i.blockedReason}');
        }
        buf.writeln();
      }

      writeSection('Doing', items.where((i) => i.status == 'doing').toList());
      writeSection(
        'Overdue',
        items
            .where(
              (i) =>
                  i.dueAt != null &&
                  i.dueAt!.isBefore(today) &&
                  i.status != 'doing',
            )
            .toList(),
      );
      writeSection(
        'Due Today',
        items
            .where(
              (i) =>
                  i.dueAt != null &&
                  !i.dueAt!.isBefore(today) &&
                  i.dueAt!.isBefore(tomorrow) &&
                  i.status != 'doing',
            )
            .toList(),
      );
      writeSection(
        'Phone Queue',
        items.where((i) => i.phoneQueue && i.status != 'doing').toList(),
      );
      await state.db.logEvent(
        area: 'export',
        action: 'export_today_success',
        outputJson: '{"count":${items.length}}',
      );
      if (!mounted) return;
      setState(() => _exportText = buf.toString().trim());
    } catch (e, st) {
      await state.db.logError(
        area: 'export',
        action: 'export_today_failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _statusMessage = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _sendToTelegram() async {
    if (_exportText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Generate a list first, then send to Telegram.'),
        ),
      );
      return;
    }
    final state = AppStateScope.of(context);
    setState(() {
      _sending = true;
      _statusMessage = '';
    });
    try {
      await state.db.logEvent(area: 'telegram', action: 'send_request');
      final (ok, err) = await state.sendTodayToTelegram();
      await state.db.logEvent(
        level: ok ? 'info' : 'error',
        area: 'telegram',
        action: ok ? 'send_success' : 'send_failed',
        error: err,
      );
      if (!mounted) return;
      setState(
        () => _statusMessage = ok
            ? '✓ Sent to Telegram successfully.'
            : '✗ Send failed: ${err ?? 'Unknown error'}',
      );
    } catch (e, st) {
      await state.db.logError(
        area: 'telegram',
        action: 'send_failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _statusMessage = '✗ Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _runOllamaOnExport() async {
    final state = AppStateScope.of(context);
    setState(() {
      _generating = true;
      _statusMessage = 'Asking Ollama...';
    });
    try {
      await state.db.logEvent(area: 'ollama', action: 'summary_request');
      final result = await state.summarizeToday().timeout(
        const Duration(seconds: 45),
      );
      if (!result.isSuccess) {
        await state.db.logEvent(
          level: 'error',
          area: 'ollama',
          action: 'summary_failed',
          inputJson: result.input,
        );
        if (mounted)
          setState(
            () => _statusMessage =
                'Ollama failed or returned no output. Check Settings and whether Ollama is running.',
          );
        return;
      }
      await state.saveDraft(
        kind: result.kind,
        title: result.title,
        body: result.output!,
        inputJson: result.input,
      );
      await state.db.logEvent(
        area: 'ollama',
        action: 'summary_success',
        inputJson: result.input,
        outputJson: result.output,
      );
      if (!mounted) return;
      setState(() {
        _exportText = result.output!;
        _statusMessage =
            '✓ AI summary created and saved as a reviewable draft.';
      });
    } catch (e, st) {
      await state.db.logError(
        area: 'ollama',
        action: 'summary_failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _statusMessage = 'Ollama failed: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _generating ? null : _generateTodayMarkdown,
                  icon: const Icon(Icons.today),
                  label: const Text("Today's List"),
                ),
                OutlinedButton.icon(
                  onPressed: _generating ? null : _generateMarkdown,
                  icon: const Icon(Icons.list_alt),
                  label: const Text('All Active Tasks'),
                ),
                OutlinedButton.icon(
                  onPressed: _generating ? null : _runOllamaOnExport,
                  icon: const Icon(Icons.psychology_outlined),
                  label: const Text('AI Summary'),
                ),
                FilledButton.icon(
                  onPressed: _sending || _exportText.isEmpty
                      ? null
                      : _sendToTelegram,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Send to Telegram'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF229ED9),
                  ),
                ),
                if (_exportText.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _exportText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied to clipboard.')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
              ],
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _statusMessage.startsWith('✓')
                      ? Colors.green.withAlpha(30)
                      : Colors.red.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    color: _statusMessage.startsWith('✓')
                        ? Colors.green
                        : Colors.red,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Expanded(
              child: _generating
                  ? const Center(child: CircularProgressIndicator())
                  : _exportText.isEmpty
                  ? const Center(
                      child: Text(
                        'Choose an export format above.',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(8),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          _exportText,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            _OutboxLog(),
          ],
        ),
      ),
    );
  }
}

class _OutboxLog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<OutboxMessage>>(
      stream: state.db.watchOutboxMessages(),
      builder: (context, snap) {
        final msgs = snap.data ?? [];
        if (msgs.isEmpty) return const SizedBox.shrink();
        final recent = msgs.take(3).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recent sends',
              style: TextStyle(fontSize: 11, color: Colors.white38),
            ),
            const SizedBox(height: 6),
            for (final m in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      m.status == 'sent'
                          ? Icons.check_circle
                          : Icons.error_outline,
                      size: 14,
                      color: m.status == 'sent' ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${m.title} - ${_timeAgo(m.createdAt)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
