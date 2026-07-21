import 'dart:async';

/// Coordinates Atlas-owned file mutations with full database-plus-files
/// snapshots.
///
/// A backup receives exclusive access after already-running mutations finish.
/// Mutations requested while a backup is pending or active wait until the
/// snapshot is complete. State transitions occur synchronously on the main
/// isolate, so no mutation can enter between the final check and lock claim.
class AtlasOwnedFileSnapshotCoordinator {
  static final instance = AtlasOwnedFileSnapshotCoordinator();

  var _activeMutations = 0;
  var _backupActive = false;
  var _backupRequested = false;
  Completer<void>? _stateChanged;

  Future<T> runMutation<T>(Future<T> Function() action) async {
    while (_backupRequested || _backupActive) {
      await _nextStateChange();
    }
    _activeMutations++;
    try {
      return await action();
    } finally {
      _activeMutations--;
      _signalStateChange();
    }
  }

  Future<T> runBackup<T>(Future<T> Function() action) async {
    while (_backupRequested || _backupActive) {
      await _nextStateChange();
    }
    _backupRequested = true;
    while (_activeMutations > 0) {
      await _nextStateChange();
    }
    _backupActive = true;
    _backupRequested = false;
    _signalStateChange();
    try {
      return await action();
    } finally {
      _backupActive = false;
      _signalStateChange();
    }
  }

  Future<void> _nextStateChange() {
    final current = _stateChanged;
    if (current != null) return current.future;
    final created = Completer<void>();
    _stateChanged = created;
    return created.future;
  }

  void _signalStateChange() {
    final current = _stateChanged;
    _stateChanged = null;
    if (current != null && !current.isCompleted) current.complete();
  }
}
