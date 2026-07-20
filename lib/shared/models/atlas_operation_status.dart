enum AtlasOperationState { running, complete, failed }

/// Route-independent feedback for a potentially long-running local operation.
class AtlasOperationStatus {
  final String title;
  final String message;
  final AtlasOperationState state;
  final int? current;
  final int? total;

  const AtlasOperationStatus({
    required this.title,
    required this.message,
    required this.state,
    this.current,
    this.total,
  });

  double? get fraction {
    if (state == AtlasOperationState.complete) return 1;
    if (state == AtlasOperationState.failed) return null;
    if (current == null || total == null || total! <= 0) return null;
    return current!.clamp(0, total!).toDouble() / total!;
  }

  String? get progressLabel => current != null && total != null && total! > 0
      ? '$current / $total'
      : null;
}
