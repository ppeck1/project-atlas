import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/features/work/status_priority_helpers.dart';

void main() {
  test('priority dropdown values are unique and medium normalizes safely', () {
    final values = priorityOptions.map((p) => p.value).toList();
    expect(values.toSet().length, values.length);
    expect(normalizePriorityValue('medium'), 'normal');
    expect(normalizePriorityValue('med'), 'normal');
    expect(normalizePriorityValue('critical'), 'urgent');
  });

  test('status dropdown values are unique and aliases normalize safely', () {
    final values = statusOptions.map((s) => s.value).toList();
    expect(values.toSet().length, values.length);
    expect(normalizeStatusValue('in progress'), 'doing');
    expect(normalizeStatusValue('blocked'), 'waiting');
  });
}
