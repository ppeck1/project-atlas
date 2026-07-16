import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/features/today/today_bucketing.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final _epoch = DateTime(2026, 1, 15); // arbitrary fixed "today" for tests

WorkItem _item({
  required String id,
  String status = 'next',
  String priority = 'normal',
  DateTime? dueAt,
  bool phoneQueue = false,
}) {
  return WorkItem(
    id: id,
    stageId: 'stage-1',
    title: 'Item $id',
    status: status,
    priority: priority,
    dueAt: dueAt,
    phoneQueue: phoneQueue,
    completed: false,
    readiness: 'ready',
    size: 'medium',
    risk: 'low_code',
    suggestedActor: 'user',
    verificationNeeded: 'none',
    updatedAt: _epoch,
    createdAt: _epoch,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Fixed "now" anchored to noon on 2026-01-15 so day boundaries are clear.
  final now = DateTime(2026, 1, 15, 12, 0);
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final tomorrow = today.add(const Duration(days: 1));

  group('bucketTodayItems – basic placement', () {
    test('doing item lands in doing bucket only', () {
      final item = _item(id: 'a', status: 'doing');
      final b = bucketTodayItems([item], now: now);
      expect(b.doing, contains(item));
      expect(b.overdue, isEmpty);
      expect(b.dueToday, isEmpty);
      expect(b.phoneQueue, isEmpty);
      expect(b.highPrio, isEmpty);
    });

    test('item due yesterday lands in overdue', () {
      final item = _item(id: 'b', dueAt: yesterday);
      final b = bucketTodayItems([item], now: now);
      expect(b.overdue, contains(item));
      expect(b.dueToday, isEmpty);
    });

    test('item due today (midnight) lands in dueToday', () {
      final item = _item(id: 'c', dueAt: today);
      final b = bucketTodayItems([item], now: now);
      expect(b.dueToday, contains(item));
      expect(b.overdue, isEmpty);
    });

    test('item due tomorrow does not appear in overdue or dueToday', () {
      final item = _item(id: 'd', dueAt: tomorrow);
      final b = bucketTodayItems([item], now: now);
      expect(b.overdue, isEmpty);
      expect(b.dueToday, isEmpty);
      // No other high-prio or phoneQueue flags — not in any bucket.
      expect(b.highPrio, isEmpty);
      expect(b.phoneQueue, isEmpty);
    });

    test('phone-queue item not already overdue/dueToday lands in phoneQueue', () {
      final item = _item(id: 'e', phoneQueue: true, dueAt: tomorrow);
      final b = bucketTodayItems([item], now: now);
      expect(b.phoneQueue, contains(item));
      expect(b.overdue, isEmpty);
      expect(b.dueToday, isEmpty);
    });

    test('high-priority item not in earlier buckets lands in highPrio', () {
      final item = _item(id: 'f', priority: 'high');
      final b = bucketTodayItems([item], now: now);
      expect(b.highPrio, contains(item));
    });

    test('urgent priority also lands in highPrio', () {
      final item = _item(id: 'g', priority: 'urgent');
      final b = bucketTodayItems([item], now: now);
      expect(b.highPrio, contains(item));
    });
  });

  group('bucketTodayItems – mutual exclusion', () {
    test('doing item with overdue dueAt stays only in doing', () {
      final item = _item(id: 'h', status: 'doing', dueAt: yesterday);
      final b = bucketTodayItems([item], now: now);
      expect(b.doing, contains(item));
      expect(b.overdue, isEmpty);
    });

    test('overdue item with phoneQueue flag lands in overdue, not phoneQueue', () {
      final item = _item(id: 'i', dueAt: yesterday, phoneQueue: true);
      final b = bucketTodayItems([item], now: now);
      expect(b.overdue, contains(item));
      expect(b.phoneQueue, isEmpty);
    });

    test('dueToday item with high priority stays only in dueToday', () {
      final item = _item(id: 'j', dueAt: today, priority: 'high');
      final b = bucketTodayItems([item], now: now);
      expect(b.dueToday, contains(item));
      expect(b.highPrio, isEmpty);
    });
  });

  group('bucketTodayItems – day-boundary flip', () {
    // An item due on 2026-01-15 (today) should be overdue once "now" crosses
    // midnight into 2026-01-16.
    test('item due today flips to overdue when now crosses midnight', () {
      final itemDueToday = _item(id: 'k', dueAt: today);

      // 23:59 on 2026-01-15 — still dueToday
      final before = DateTime(2026, 1, 15, 23, 59);
      final bBefore = bucketTodayItems([itemDueToday], now: before);
      expect(bBefore.dueToday, contains(itemDueToday));
      expect(bBefore.overdue, isEmpty);

      // 00:01 on 2026-01-16 — now overdue
      final after = DateTime(2026, 1, 16, 0, 1);
      final bAfter = bucketTodayItems([itemDueToday], now: after);
      expect(bAfter.overdue, contains(itemDueToday));
      expect(bAfter.dueToday, isEmpty);
    });

    test('item due tomorrow becomes dueToday once now crosses midnight', () {
      final itemDueTomorrow = _item(id: 'l', dueAt: tomorrow);

      // 23:59 on 2026-01-15 — not yet due today
      final before = DateTime(2026, 1, 15, 23, 59);
      final bBefore = bucketTodayItems([itemDueTomorrow], now: before);
      expect(bBefore.dueToday, isEmpty);
      expect(bBefore.overdue, isEmpty);

      // 00:01 on 2026-01-16 — now due today
      final after = DateTime(2026, 1, 16, 0, 1);
      final bAfter = bucketTodayItems([itemDueTomorrow], now: after);
      expect(bAfter.dueToday, contains(itemDueTomorrow));
      expect(bAfter.overdue, isEmpty);
    });

    test('month-end rollover: item due on Feb 1 flips correctly after midnight', () {
      // today = Jan 31; item due Jan 31 should flip to overdue on Feb 1
      final jan31 = DateTime(2026, 1, 31);
      final item = _item(id: 'm', dueAt: jan31);

      final beforeMidnight = DateTime(2026, 1, 31, 23, 59);
      final bBefore = bucketTodayItems([item], now: beforeMidnight);
      expect(bBefore.dueToday, contains(item));
      expect(bBefore.overdue, isEmpty);

      final afterMidnight = DateTime(2026, 2, 1, 0, 1);
      final bAfter = bucketTodayItems([item], now: afterMidnight);
      expect(bAfter.overdue, contains(item));
      expect(bAfter.dueToday, isEmpty);
    });
  });

  group('bucketTodayItems – empty list', () {
    test('all buckets empty when no items provided', () {
      final b = bucketTodayItems([], now: now);
      expect(b.doing, isEmpty);
      expect(b.overdue, isEmpty);
      expect(b.dueToday, isEmpty);
      expect(b.phoneQueue, isEmpty);
      expect(b.highPrio, isEmpty);
    });
  });
}
