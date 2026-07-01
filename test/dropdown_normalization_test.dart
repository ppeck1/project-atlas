import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/features/work/status_priority_helpers.dart';
import 'package:project_atlas/shared/models/project_metadata.dart';

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

  test(
    'project status options are unique, described, and normalize aliases',
    () {
      final values = projectStatusOptions.map((s) => s.value).toList();
      expect(values.toSet().length, values.length);
      expect(normalizeProjectStatusValue('Needs Review'), 'needs_review');
      expect(normalizeProjectStatusValue('needs-review'), 'needs_review');
      expect(normalizeProjectStatusValue('local only'), 'local_only');
      expect(normalizeProjectStatusValue('unknown'), 'active');
      expect(
        projectStatusOptions.every(
          (s) => s.descriptor.isNotEmpty && s.description.isNotEmpty,
        ),
        isTrue,
      );
    },
  );

  test(
    'project status helpers distinguish open, review, inactive, and closed',
    () {
      expect(isSummaryEligibleProjectStatus('active'), isTrue);
      expect(isSummaryEligibleProjectStatus('needs review'), isTrue);
      expect(isAttentionProjectStatus('needs-update'), isTrue);
      expect(isSummaryEligibleProjectStatus('paused'), isFalse);
      expect(projectStatusDescriptor('paused'), 'Inactive');
      expect(projectStatusDescriptor('completed'), 'Closed');
    },
  );
}
