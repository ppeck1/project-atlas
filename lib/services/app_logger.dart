import '../db/app_db.dart';

/// Thin app-level logger facade over the durable event_log table.
class AppLogger {
  final AppDb db;
  const AppLogger(this.db);

  Future<void> log({
    String level = 'info',
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    String? inputJson,
    String? outputJson,
    String? error,
    StackTrace? stackTrace,
    String? correlationId,
  }) => db.logEvent(
    level: level,
    area: area,
    action: action,
    entityType: entityType,
    entityId: entityId,
    inputJson: inputJson,
    outputJson: outputJson,
    error: error,
    correlationId: correlationId,
  );

  Future<void> error({
    required String area,
    required String action,
    String? entityType,
    String? entityId,
    Object error = '',
    StackTrace? stackTrace,
    String? inputJson,
  }) => db.logError(
    area: area,
    action: action,
    entityType: entityType,
    entityId: entityId,
    error: error,
    stackTrace: stackTrace,
    inputJson: inputJson,
  );
}
