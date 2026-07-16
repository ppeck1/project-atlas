import '../../db/app_db.dart';

/// Result of bucketing a list of [WorkItem]s relative to a given [now].
///
/// Buckets are mutually exclusive and match the Today screen display order:
///   doing → overdue → dueToday → phoneQueue → highPrio
class TodayBuckets {
  final List<WorkItem> doing;
  final List<WorkItem> overdue;
  final List<WorkItem> dueToday;
  final List<WorkItem> phoneQueue;
  final List<WorkItem> highPrio;

  const TodayBuckets({
    required this.doing,
    required this.overdue,
    required this.dueToday,
    required this.phoneQueue,
    required this.highPrio,
  });
}

/// Pure function: bucket [items] into the five Today-screen categories relative
/// to [now].  Accepts an injected [now] so it is unit-testable without a Timer.
TodayBuckets bucketTodayItems(List<WorkItem> items, {required DateTime now}) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));

  final doing = items.where((i) => i.status == 'doing').toList();
  final overdue = items
      .where(
        (i) =>
            i.dueAt != null &&
            i.dueAt!.isBefore(today) &&
            i.status != 'doing',
      )
      .toList();
  final dueToday = items
      .where(
        (i) =>
            i.dueAt != null &&
            !i.dueAt!.isBefore(today) &&
            i.dueAt!.isBefore(tomorrow) &&
            i.status != 'doing',
      )
      .toList();
  final phoneQueue = items
      .where(
        (i) =>
            i.phoneQueue &&
            i.status != 'doing' &&
            !overdue.contains(i) &&
            !dueToday.contains(i),
      )
      .toList();
  final highPrio = items
      .where(
        (i) =>
            ['high', 'urgent'].contains(i.priority) &&
            i.status != 'doing' &&
            !overdue.contains(i) &&
            !dueToday.contains(i) &&
            !phoneQueue.contains(i),
      )
      .toList();

  return TodayBuckets(
    doing: doing,
    overdue: overdue,
    dueToday: dueToday,
    phoneQueue: phoneQueue,
    highPrio: highPrio,
  );
}
