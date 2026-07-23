import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

const recoveryArtifactLockFile = '.atlas-recovery-artifacts.lock';

final Map<String, Future<void>> _recoveryArtifactLockTails =
    <String, Future<void>>{};

Future<T> withRecoveryArtifactLock<T>(
  Directory handoffRoot,
  Future<T> Function() action,
) async {
  await handoffRoot.create(recursive: true);
  final lockFile = File(p.join(handoffRoot.path, recoveryArtifactLockFile));
  final normalized = p.normalize(p.absolute(lockFile.path));
  final key = Platform.isWindows ? normalized.toLowerCase() : normalized;
  final previous = _recoveryArtifactLockTails[key] ?? Future<void>.value();
  final releaseLocal = Completer<void>();
  final tail = releaseLocal.future;
  _recoveryArtifactLockTails[key] = tail;
  await previous;
  RandomAccessFile? handle;
  var locked = false;
  try {
    handle = await lockFile.open(mode: FileMode.append);
    await handle.lock(FileLock.exclusive);
    locked = true;
    return await action();
  } finally {
    try {
      if (locked) await handle!.unlock();
    } finally {
      try {
        await handle?.close();
      } finally {
        releaseLocal.complete();
        if (identical(_recoveryArtifactLockTails[key], tail)) {
          _recoveryArtifactLockTails.remove(key);
        }
      }
    }
  }
}
