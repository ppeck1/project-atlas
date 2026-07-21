import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/shared/models/atlas_operation_status.dart';

void main() {
  test('operation status exposes determinate, terminal, and failure progress', () {
    expect(
      const AtlasOperationStatus(
        title: 'Export',
        message: 'Copying',
        state: AtlasOperationState.running,
        current: 3,
        total: 12,
      ).fraction,
      0.25,
    );
    expect(
      const AtlasOperationStatus(
        title: 'Export',
        message: 'Done',
        state: AtlasOperationState.complete,
      ).fraction,
      1,
    );
    expect(
      const AtlasOperationStatus(
        title: 'Export',
        message: 'Failed',
        state: AtlasOperationState.failed,
      ).fraction,
      isNull,
    );
  });
}
