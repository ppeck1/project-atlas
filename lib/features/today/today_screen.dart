import 'package:flutter/material.dart';

import '../../db/app_db.dart';
import '../../shared/models/app_state_scope.dart';
import 'work_item_detail_sheet.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              _formattedDate(),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.white54),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<WorkItem>>(
        stream: state.watchTodayItems(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
                    SizedBox(height: 16),
                    Text(
                      'Nothing urgent today.',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Items appear here when they are in progress,\noverdue, due today, on your phone queue,\nor marked high priority.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            );
          }

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final tomorrow = today.add(const Duration(days: 1));

          final doing = items.where((i) => i.status == 'doing').toList();
          final overdue = items
              .where((i) =>
                  i.dueAt != null &&
                  i.dueAt!.isBefore(today) &&
                  i.status != 'doing')
              .toList();
          final dueToday = items
              .where((i) =>
                  i.dueAt != null &&
                  !i.dueAt!.isBefore(today) &&
                  i.dueAt!.isBefore(tomorrow) &&
                  i.status != 'doing')
              .toList();
          final phoneQueue = items
              .where((i) =>
                  i.phoneQueue &&
                  i.status != 'doing' &&
                  !overdue.contains(i) &&
                  !dueToday.contains(i))
              .toList();
          final highPrio = items
              .where((i) =>
                  ['high', 'urgent'].contains(i.priority) &&
                  i.status != 'doing' &&
                  !overdue.contains(i) &&
                  !dueToday.contains(i) &&
                  !phoneQueue.contains(i))
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SummaryRow(items: items),
              const SizedBox(height: 16),
              if (doing.isNotEmpty) ...[
                _SectionHeader(
                  label: '🔄 Doing Now',
                  count: doing.length,
                  color: Colors.amber,
                ),
                ...doing.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (overdue.isNotEmpty) ...[
                _SectionHeader(
                  label: '🔴 Overdue',
                  count: overdue.length,
                  color: Colors.red,
                ),
                ...overdue.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (dueToday.isNotEmpty) ...[
                _SectionHeader(
                  label: '📅 Due Today',
                  count: dueToday.length,
                  color: Colors.orange,
                ),
                ...dueToday.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (phoneQueue.isNotEmpty) ...[
                _SectionHeader(
                  label: '📞 Phone / Follow-up',
                  count: phoneQueue.length,
                  color: Colors.blue,
                ),
                ...phoneQueue.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
              if (highPrio.isNotEmpty) ...[
                _SectionHeader(
                  label: '⚡ High Priority',
                  count: highPrio.length,
                  color: Colors.deepOrange,
                ),
                ...highPrio.map((i) => _TodayTile(item: i)),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }

  String _formattedDate() {
    final now = DateTime.now();
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = days[now.weekday - 1];
    return '$dow ${months[now.month]} ${now.day}';
  }
}

class _SummaryRow extends StatelessWidget {
  final List<WorkItem> items;
  const _SummaryRow({required this.items});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final doingCount = items.where((i) => i.status == 'doing').length;
    final overdueCount = items
        .where((i) => i.dueAt != null && i.dueAt!.isBefore(today))
        .length;
    final blockedCount =
        items.where((i) => i.blockedReason != null).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _Stat(label: 'Doing', value: doingCount, color: Colors.amber),
            _Stat(label: 'Overdue', value: overdueCount, color: Colors.red),
            _Stat(label: 'Blocked', value: blockedCount, color: Colors.purple),
            _Stat(label: 'Total', value: items.length, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Stat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: value > 0 ? color : Colors.white30,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _SectionHeader(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: color,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _TodayTile extends StatelessWidget {
  final WorkItem item;
  const _TodayTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showWorkItemDetailSheet(context, item.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Quick done toggle
              SizedBox(
                width: 32,
                height: 32,
                child: Checkbox(
                  value: item.completed,
                  onChanged: (_) => state.toggleWorkDone(item.id),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration:
                            item.completed ? TextDecoration.lineThrough : null,
                        color: item.completed ? Colors.white38 : null,
                      ),
                    ),
                    if (item.description != null &&
                        item.description!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.description!,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (item.blockedReason != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.block, size: 12, color: Colors.red),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.blockedReason!,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.red),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _PriorityBadge(item.priority),
                  if (item.dueAt != null) ...[
                    const SizedBox(height: 4),
                    _DueBadge(item.dueAt!),
                  ],
                  if (item.phoneQueue) ...[
                    const SizedBox(height: 4),
                    const Icon(Icons.phone, size: 14, color: Colors.blue),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final String priority;
  const _PriorityBadge(this.priority);

  @override
  Widget build(BuildContext context) {
    if (priority == 'normal' || priority == 'low') {
      return const SizedBox.shrink();
    }
    final (label, color) = switch (priority) {
      'high' => ('HIGH', Colors.orange),
      'urgent' => ('URGENT', Colors.red),
      _ => (priority.toUpperCase(), Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _DueBadge extends StatelessWidget {
  final DateTime dueAt;
  const _DueBadge(this.dueAt);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isOverdue = dueAt.isBefore(today);
    final isToday =
        !dueAt.isBefore(today) && dueAt.isBefore(today.add(const Duration(days: 1)));

    final color = isOverdue
        ? Colors.red
        : isToday
            ? Colors.orange
            : Colors.white54;

    return Text(
      '${dueAt.month}/${dueAt.day}',
      style: TextStyle(fontSize: 11, color: color),
    );
  }
}
