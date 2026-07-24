import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/recovery_artifact_lock.dart';

void main() {
  test(
    'serializes recovery mutation and retention across file handles',
    () async {
      final root = await Directory.systemTemp.createTemp('atlas_lock_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondStarted = Completer<void>();

      final first = withRecoveryArtifactLock(root, () async {
        firstStarted.complete();
        await releaseFirst.future;
      });
      await firstStarted.future;
      final second = withRecoveryArtifactLock(root, () async {
        secondStarted.complete();
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(secondStarted.isCompleted, isFalse);
      releaseFirst.complete();
      await Future.wait([first, second]);
      expect(secondStarted.isCompleted, isTrue);
    },
  );
}
