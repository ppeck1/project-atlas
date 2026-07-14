import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import '../../services/ollama_service.dart';
import '../today/work_item_detail_sheet.dart';
import '../work/status_priority_helpers.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _loading = false;
  List<WorkItem> _allActive = [];
  List<WorkItem> _blocked = [];
  List<WorkItem> _overdue = [];
  List<WorkItem> _dueToday = [];
  bool _loaded = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final state = AppStateScope.of(context);
    try {
      await state.db.logEvent(area: 'ui', action: 'review_load_request');
      final allItems = await state.getAllActiveWorkItems();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      if (!mounted) return;
      setState(() {
        _allActive = allItems;
        _blocked = allItems.where((i) => i.blockedReason != null).toList();
        _overdue = allItems
            .where((i) => i.dueAt != null && i.dueAt!.isBefore(today))
            .toList();
        _dueToday = allItems
            .where(
              (i) =>
                  i.dueAt != null &&
                  !i.dueAt!.isBefore(today) &&
                  i.dueAt!.isBefore(tomorrow),
            )
            .toList();
      });
      final generated = _buildDeterministicSummary();
      state.saveDailyReview(generated); // persist to DailyReviews
      await state.db.logEvent(
        area: 'ui',
        action: 'review_load_success',
        outputJson: '{"count":${allItems.length}}',
      );
    } catch (e, st) {
      await state.db.logError(
        area: 'ui',
        action: 'review_load_failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _buildDeterministicSummary() {
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
      '# Daily Review - ${months[now.month]} ${now.day}, ${now.year}',
    );
    buf.writeln();
    buf.writeln('**Active tasks:** ${_allActive.length}');
    buf.writeln('**Blocked:** ${_blocked.length}');
    buf.writeln('**Overdue:** ${_overdue.length}');
    buf.writeln('**Due today:** ${_dueToday.length}');
    buf.writeln();

    if (_blocked.isNotEmpty) {
      buf.writeln('## Blocked');
      for (final i in _blocked) {
        buf.writeln('- ${i.title}');
        if (i.blockedReason != null) buf.writeln('  - ${i.blockedReason}');
      }
      buf.writeln();
    }

    if (_overdue.isNotEmpty) {
      buf.writeln('## Overdue');
      for (final i in _overdue) {
        final due = i.dueAt;
        final label = due != null ? ' (was ${due.month}/${due.day})' : '';
        buf.writeln('- ${i.title}$label');
      }
      buf.writeln();
    }

    if (_dueToday.isNotEmpty) {
      buf.writeln('## Due Today');
      for (final i in _dueToday) {
        buf.writeln('- ${i.title}');
      }
      buf.writeln();
    }

    final doing = _allActive.where((i) => i.status == 'doing').toList();
    if (doing.isNotEmpty) {
      buf.writeln('## In Progress');
      for (final i in doing) {
        buf.writeln('- ${i.title}');
      }
    }

    return buf.toString().trim();
  }

  Future<void> _runOllamaSummary() async {
    final state = AppStateScope.of(context);

    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Asking Ollama...'),
          ],
        ),
      ),
    );

    final result = await state.summarizeToday();

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop(); // dismiss loading

    if (!result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ollama not available. Is it running at localhost:11434?',
          ),
        ),
      );
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => _OllamaReviewDialog(result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 32,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Review failed to load.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Stats
                _StatsRow(
                  active: _allActive.length,
                  blocked: _blocked.length,
                  overdue: _overdue.length,
                  dueToday: _dueToday.length,
                ),
                const SizedBox(height: 20),

                // Ollama button
                Row(
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.psychology_outlined),
                      label: const Text('Summarize with AI'),
                      onPressed: _runOllamaSummary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'AI output is shown for review first',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                const _DraftReviewSection(),
                const SizedBox(height: 20),
                const Divider(),

                // Deterministic summary
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Today\'s Summary',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      tooltip: 'Copy as Markdown',
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: _buildDeterministicSummary()),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard.')),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                if (_blocked.isNotEmpty) ...[
                  _SectionHeader('Blocked', Colors.red),
                  ..._blocked.map(
                    (i) => _ReviewTile(item: i, showBlocked: true),
                  ),
                  const SizedBox(height: 16),
                ],

                if (_overdue.isNotEmpty) ...[
                  _SectionHeader('Overdue', Colors.red.shade300),
                  ..._overdue.map((i) => _ReviewTile(item: i)),
                  const SizedBox(height: 16),
                ],

                if (_dueToday.isNotEmpty) ...[
                  _SectionHeader('Due Today', Colors.orange),
                  ..._dueToday.map((i) => _ReviewTile(item: i)),
                  const SizedBox(height: 16),
                ],

                if (_allActive
                    .where((i) => i.status == 'doing')
                    .isNotEmpty) ...[
                  _SectionHeader('In Progress', Colors.amber),
                  ..._allActive
                      .where((i) => i.status == 'doing')
                      .map((i) => _ReviewTile(item: i)),
                  const SizedBox(height: 16),
                ],

                if (_blocked.isEmpty &&
                    _overdue.isEmpty &&
                    _dueToday.isEmpty &&
                    _allActive.where((i) => i.status == 'doing').isEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'Nothing urgent to review today.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final int active;
  final int blocked;
  final int overdue;
  final int dueToday;

  const _StatsRow({
    required this.active,
    required this.blocked,
    required this.overdue,
    required this.dueToday,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatCard(label: 'Active', value: active, color: Colors.blue),
        const SizedBox(width: 12),
        _StatCard(label: 'Blocked', value: blocked, color: Colors.purple),
        const SizedBox(width: 12),
        _StatCard(label: 'Overdue', value: overdue, color: Colors.red),
        const SizedBox(width: 12),
        _StatCard(label: 'Due Today', value: dueToday, color: Colors.orange),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: value > 0 ? color : Colors.white24,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _SectionHeader(String label, Color color) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      label,
      style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 13),
    ),
  );
}

class _ReviewTile extends StatelessWidget {
  final WorkItem item;
  final bool showBlocked;
  const _ReviewTile({required this.item, this.showBlocked = false});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showWorkItemDetailSheet(context, item.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  statusChip(item.status),
                ],
              ),
              if (showBlocked && item.blockedReason != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Blocked: ${item.blockedReason}',
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OllamaReviewDialog extends StatelessWidget {
  final OllamaResult result;
  const _OllamaReviewDialog({required this.result});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return AlertDialog(
      title: Text(result.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI-generated summary - review before saving.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(result.output ?? ''),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Discard'),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: result.output ?? ''));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Copied.')));
          },
        ),
        FilledButton(
          onPressed: () async {
            await state.saveDraft(
              kind: result.kind,
              title: result.title,
              body: result.output!,
              inputJson: result.input,
            );
            if (context.mounted) {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Saved to Drafts.')));
            }
          },
          child: const Text('Save Draft'),
        ),
      ],
    );
  }
}

class _DraftReviewSection extends StatelessWidget {
  const _DraftReviewSection();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return StreamBuilder<List<Draft>>(
      stream: state.watchDrafts(),
      builder: (context, snap) {
        final drafts = snap.data ?? const <Draft>[];
        if (drafts.isEmpty) {
          return const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'No AI drafts waiting for review.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              'AI Draft Review',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final d in drafts.take(5))
              Card(
                child: ExpansionTile(
                  title: Text(d.title),
                  subtitle: Text('${d.kind} · ${d.createdAt}'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (d.inputJson != null) ...[
                      const Text(
                        'Input/context',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SelectableText(
                        d.inputJson!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white60,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const Text(
                      'Draft output',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SelectableText(d.body),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: d.body));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied draft.')),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy'),
                        ),
                        TextButton.icon(
                          onPressed: () => state.deleteDraft(d.id),
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
