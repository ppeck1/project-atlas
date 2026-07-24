import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

enum PortableExportPhase {
  preparing,
  writingManifest,
  addingFiles,
  promoting,
  complete,
  cancelled,
  failed,
}

class PortableExportLimits {
  static const int hardMaxEntries = 100000;
  static const int hardMaxFileBytes = 8 * 1024 * 1024 * 1024;
  static const int hardMaxTotalSourceBytes = 64 * 1024 * 1024 * 1024;
  static const int hardMaxManifestBytes = 256 * 1024 * 1024;
  static const int hardMaxMetadataRecords = 1000000;
  static const int hardMaxPathLength = 1024;

  final int maxEntries;
  final int maxFileBytes;
  final int maxTotalSourceBytes;
  final int maxManifestBytes;
  final int maxMetadataRecords;
  final int maxPathLength;

  const PortableExportLimits({
    this.maxEntries = 10000,
    this.maxFileBytes = 2 * 1024 * 1024 * 1024,
    this.maxTotalSourceBytes = 10 * 1024 * 1024 * 1024,
    this.maxManifestBytes = 64 * 1024 * 1024,
    this.maxMetadataRecords = 250000,
    this.maxPathLength = 512,
  });

  void validate() {
    _validateBound('maxEntries', maxEntries, hardMaxEntries);
    _validateBound('maxFileBytes', maxFileBytes, hardMaxFileBytes);
    _validateBound(
      'maxTotalSourceBytes',
      maxTotalSourceBytes,
      hardMaxTotalSourceBytes,
    );
    _validateBound('maxManifestBytes', maxManifestBytes, hardMaxManifestBytes);
    _validateBound(
      'maxMetadataRecords',
      maxMetadataRecords,
      hardMaxMetadataRecords,
    );
    _validateBound('maxPathLength', maxPathLength, hardMaxPathLength);
  }

  Map<String, int> toMessage() => {
    'maxEntries': maxEntries,
    'maxFileBytes': maxFileBytes,
    'maxTotalSourceBytes': maxTotalSourceBytes,
    'maxManifestBytes': maxManifestBytes,
    'maxMetadataRecords': maxMetadataRecords,
    'maxPathLength': maxPathLength,
  };

  static void _validateBound(String name, int value, int hardMaximum) {
    if (value <= 0 || value > hardMaximum) {
      throw ArgumentError.value(
        value,
        name,
        'must be positive and no greater than $hardMaximum',
      );
    }
  }
}

class PortableExportSource {
  final String sourcePath;
  final String archivePath;

  const PortableExportSource({
    required this.sourcePath,
    required this.archivePath,
  });
}

class PortableExportProgress {
  final PortableExportPhase phase;
  final String message;
  final int completedEntries;
  final int totalEntries;
  final int processedBytes;
  final int totalBytes;

  const PortableExportProgress({
    required this.phase,
    required this.message,
    this.completedEntries = 0,
    this.totalEntries = 0,
    this.processedBytes = 0,
    this.totalBytes = 0,
  });

  double? get fraction {
    if (totalBytes > 0) {
      return (processedBytes / totalBytes).clamp(0, 1).toDouble();
    }
    if (totalEntries > 0) {
      return (completedEntries / totalEntries).clamp(0, 1).toDouble();
    }
    return null;
  }
}

class PortableExportReport {
  final File output;
  final int payloadSections;
  final int metadataRecords;
  final int exportedFiles;
  final int sourceBytes;
  final int manifestBytes;
  final int outputBytes;
  final List<String> warnings;

  const PortableExportReport({
    required this.output,
    required this.payloadSections,
    required this.metadataRecords,
    required this.exportedFiles,
    required this.sourceBytes,
    required this.manifestBytes,
    required this.outputBytes,
    required this.warnings,
  });
}

class PortableExportException implements Exception {
  final String code;
  final String message;
  final String? archivePath;
  final String? sourcePath;

  const PortableExportException(
    this.code,
    this.message, {
    this.archivePath,
    this.sourcePath,
  });

  @override
  String toString() {
    final entry = archivePath == null ? '' : ' [$archivePath]';
    return 'Portable export failed ($code)$entry: $message';
  }
}

class PortableExportCancelledException implements Exception {
  const PortableExportCancelledException();

  @override
  String toString() => 'Portable export was cancelled.';
}

class PortableExportTask {
  final Future<PortableExportReport> result;
  final Stream<PortableExportProgress> progress;
  final Future<void> Function() _cancel;

  const PortableExportTask._({
    required this.result,
    required this.progress,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  Future<void> cancel() => _cancel();
}

class PortableExportService {
  static final Random _random = Random.secure();

  Future<PortableExportTask> start({
    required String outputPath,
    required Map<String, Object?> payload,
    required List<PortableExportSource> sources,
    List<String> warnings = const [],
    PortableExportLimits limits = const PortableExportLimits(),
  }) async {
    limits.validate();
    if (outputPath.trim().isEmpty) {
      throw const PortableExportException(
        'invalid_output_path',
        'An output path is required.',
      );
    }

    final metadataRecords = _metadataRecordCount(payload);
    if (metadataRecords > limits.maxMetadataRecords) {
      throw PortableExportException(
        'metadata_record_limit',
        'Portable metadata contains $metadataRecords records; the limit is '
            '${limits.maxMetadataRecords}.',
      );
    }
    if (sources.length + 1 > limits.maxEntries) {
      throw PortableExportException(
        'entry_limit',
        'Portable export contains ${sources.length + 1} entries; the limit is '
            '${limits.maxEntries}.',
      );
    }

    final output = File(p.normalize(p.absolute(outputPath)));
    final parent = output.parent;
    await parent.create(recursive: true);
    final outputType = await FileSystemEntity.type(
      output.path,
      followLinks: false,
    );
    if (outputType != FileSystemEntityType.notFound &&
        outputType != FileSystemEntityType.file) {
      throw const PortableExportException(
        'unsafe_output',
        'The output path must be a regular file or a new path.',
      );
    }

    final seenArchivePaths = <String>{};
    final workerSources = <Map<String, Object?>>[];
    var totalSourceBytes = 0;
    for (final source in sources) {
      _validateArchivePath(source.archivePath, limits.maxPathLength);
      final foldedPath = source.archivePath.toLowerCase();
      if (!seenArchivePaths.add(foldedPath)) {
        throw PortableExportException(
          'duplicate_archive_path',
          'Two source files map to the same portable archive path.',
          archivePath: source.archivePath,
          sourcePath: source.sourcePath,
        );
      }
      final sourceType = await FileSystemEntity.type(
        source.sourcePath,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.file) {
        throw PortableExportException(
          'unsafe_source',
          'The source is missing, linked, or not a regular file.',
          archivePath: source.archivePath,
          sourcePath: source.sourcePath,
        );
      }
      final stat = await File(source.sourcePath).stat();
      if (stat.size > limits.maxFileBytes) {
        throw PortableExportException(
          'file_size_limit',
          'The source is ${stat.size} bytes; the per-file limit is '
              '${limits.maxFileBytes}.',
          archivePath: source.archivePath,
          sourcePath: source.sourcePath,
        );
      }
      totalSourceBytes += stat.size;
      if (totalSourceBytes > limits.maxTotalSourceBytes) {
        throw PortableExportException(
          'aggregate_size_limit',
          'Portable source bytes exceed the aggregate limit of '
              '${limits.maxTotalSourceBytes}.',
          archivePath: source.archivePath,
          sourcePath: source.sourcePath,
        );
      }
      workerSources.add({
        'sourcePath': p.normalize(p.absolute(source.sourcePath)),
        'archivePath': source.archivePath,
        'bytes': stat.size,
        'modifiedMicros': stat.modified.microsecondsSinceEpoch,
      });
    }

    final operationId =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    final partial = File('${output.path}.atlas-incomplete-$operationId');
    final manifest = File('${output.path}.atlas-manifest-$operationId.json');
    final previous = File('${output.path}.atlas-previous-$operationId');
    final events = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final progress = StreamController<PortableExportProgress>.broadcast();
    final result = Completer<PortableExportReport>();
    final workerExited = Completer<void>();
    Isolate? worker;
    SendPort? workerControl;
    var terminal = false;
    var cancelled = false;
    var readyReceived = false;
    var retainPrevious = false;
    StreamSubscription<dynamic>? eventSubscription;
    StreamSubscription<dynamic>? errorSubscription;
    StreamSubscription<dynamic>? exitSubscription;

    Future<bool> deleteTransient(File file) async {
      const attempts = 80;
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          if (await file.exists()) await file.delete();
          return true;
        } on FileSystemException {
          if (attempt == attempts - 1) return false;
          // Windows can deliver isolate exit just before its file handles
          // become deletable. Keep cleanup behind a bounded release barrier.
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
      return false;
    }

    Future<void> cleanup() async {
      for (final file in [partial, manifest, previous]) {
        if (identical(file, previous) && retainPrevious) continue;
        await deleteTransient(file);
      }
    }

    Future<void> closePorts() async {
      await eventSubscription?.cancel();
      await errorSubscription?.cancel();
      await exitSubscription?.cancel();
      events.close();
      errors.close();
      exits.close();
      await progress.close();
    }

    Future<void> fail(Object error, [StackTrace? stackTrace]) async {
      if (terminal) return;
      terminal = true;
      worker?.kill(priority: Isolate.immediate);
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Continue best-effort cleanup after the bounded release wait.
      }
      await cleanup();
      if (!result.isCompleted) {
        result.completeError(error, stackTrace);
      }
      await closePorts();
    }

    Future<void> promote(Map<Object?, Object?> message) async {
      if (terminal || cancelled) return;
      progress.add(
        PortableExportProgress(
          phase: PortableExportPhase.promoting,
          message: 'Publishing the completed portable export…',
          completedEntries: workerSources.length + 1,
          totalEntries: workerSources.length + 1,
          processedBytes: totalSourceBytes,
          totalBytes: totalSourceBytes,
        ),
      );
      var movedPrevious = false;
      late final int outputBytes;
      try {
        if (await output.exists()) {
          await output.rename(previous.path);
          movedPrevious = true;
        }
        await partial.rename(output.path);
        outputBytes = await output.length();
      } catch (error, stackTrace) {
        if (movedPrevious) {
          try {
            if (await output.exists()) await output.delete();
            if (await previous.exists()) await previous.rename(output.path);
          } on FileSystemException {
            // Preserve the previous file under its typed sibling on failure.
            retainPrevious = true;
          }
        }
        await fail(
          PortableExportException('promotion_failed', '$error'),
          stackTrace,
        );
        return;
      }

      final reportWarnings = [...warnings];
      if (movedPrevious && !await deleteTransient(previous)) {
        retainPrevious = true;
        reportWarnings.add(
          'The prior export remains in a typed .atlas-previous sibling because '
          'Windows did not release it during the bounded cleanup window.',
        );
      }
      terminal = true;
      final report = PortableExportReport(
        output: output,
        payloadSections: payload.length,
        metadataRecords: metadataRecords,
        exportedFiles: workerSources.length,
        sourceBytes: totalSourceBytes,
        manifestBytes: message['manifestBytes']! as int,
        outputBytes: outputBytes,
        warnings: List.unmodifiable(reportWarnings),
      );
      progress.add(
        PortableExportProgress(
          phase: PortableExportPhase.complete,
          message: 'Portable export complete.',
          completedEntries: workerSources.length + 1,
          totalEntries: workerSources.length + 1,
          processedBytes: totalSourceBytes,
          totalBytes: totalSourceBytes,
        ),
      );
      result.complete(report);
      await closePorts();
    }

    eventSubscription = events.listen((dynamic rawMessage) {
      if (rawMessage is! Map<Object?, Object?>) return;
      final type = rawMessage['type'];
      if (type == 'control') {
        workerControl = rawMessage['sendPort']! as SendPort;
        if (cancelled) workerControl!.send('cancel');
        return;
      }
      if (terminal) return;
      if (type == 'progress') {
        progress.add(_progressFromMessage(rawMessage));
      } else if (type == 'ready') {
        readyReceived = true;
        unawaited(promote(rawMessage));
      } else if (type == 'error') {
        unawaited(
          fail(
            PortableExportException(
              rawMessage['code']! as String,
              rawMessage['message']! as String,
              archivePath: rawMessage['archivePath'] as String?,
              sourcePath: rawMessage['sourcePath'] as String?,
            ),
          ),
        );
      }
    });
    errorSubscription = errors.listen((dynamic rawError) {
      final error = rawError is List && rawError.isNotEmpty
          ? rawError.first
          : rawError;
      unawaited(
        fail(
          PortableExportException(
            'worker_crash',
            'The portable export worker stopped unexpectedly: $error',
          ),
        ),
      );
    });
    exitSubscription = exits.listen((dynamic _) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!terminal && !cancelled && !readyReceived) {
        Timer(const Duration(milliseconds: 50), () {
          if (!terminal && !cancelled && !readyReceived) {
            unawaited(
              fail(
                const PortableExportException(
                  'worker_exit',
                  'The portable export worker exited before completion.',
                ),
              ),
            );
          }
        });
      }
    });
    progress.add(
      PortableExportProgress(
        phase: PortableExportPhase.preparing,
        message: 'Starting the bounded portable export worker…',
        totalEntries: workerSources.length + 1,
        totalBytes: totalSourceBytes,
      ),
    );

    try {
      worker = await Isolate.spawn<Map<String, Object?>>(
        _portableExportWorker,
        {
          'sendPort': events.sendPort,
          'payload': payload,
          'sources': workerSources,
          'partialPath': partial.path,
          'manifestPath': manifest.path,
          'limits': limits.toMessage(),
          'totalSourceBytes': totalSourceBytes,
        },
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'atlas-portable-export',
      );
    } catch (error, stackTrace) {
      terminal = true;
      await cleanup();
      await closePorts();
      Error.throwWithStackTrace(
        PortableExportException(
          'worker_start_failed',
          'The portable export worker could not start: $error',
        ),
        stackTrace,
      );
    }

    Future<void> cancel() async {
      if (terminal || cancelled || readyReceived) return;
      cancelled = true;
      terminal = true;
      workerControl?.send('cancel');
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        worker?.kill(priority: Isolate.immediate);
        try {
          await workerExited.future.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Continue best-effort cleanup after both bounded release waits.
        }
      }
      await cleanup();
      progress.add(
        PortableExportProgress(
          phase: PortableExportPhase.cancelled,
          message: 'Portable export cancelled.',
          totalEntries: workerSources.length + 1,
          totalBytes: totalSourceBytes,
        ),
      );
      if (!result.isCompleted) {
        result.completeError(const PortableExportCancelledException());
      }
      await closePorts();
    }

    return PortableExportTask._(
      result: result.future,
      progress: progress.stream,
      cancel: cancel,
    );
  }

  static int _metadataRecordCount(Map<String, Object?> payload) {
    var count = 0;
    for (final value in payload.values) {
      count += value is List ? value.length : 1;
    }
    return count;
  }

  static void _validateArchivePath(String value, int maxLength) {
    if (value.isEmpty ||
        value.length > maxLength ||
        value.contains('\\') ||
        value.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value) ||
        p.posix.normalize(value) != value ||
        value.split('/').any((segment) => segment.isEmpty || segment == '..')) {
      throw PortableExportException(
        'invalid_archive_path',
        'The portable archive path is not a bounded safe relative path.',
        archivePath: value,
      );
    }
  }

  static PortableExportProgress _progressFromMessage(
    Map<Object?, Object?> message,
  ) => PortableExportProgress(
    phase: PortableExportPhase.values.byName(message['phase']! as String),
    message: message['message']! as String,
    completedEntries: message['completedEntries']! as int,
    totalEntries: message['totalEntries']! as int,
    processedBytes: message['processedBytes']! as int,
    totalBytes: message['totalBytes']! as int,
  );
}

Future<void> _portableExportWorker(Map<String, Object?> message) async {
  final sendPort = message['sendPort']! as SendPort;
  final control = ReceivePort();
  var cancelled = false;
  final controlSubscription = control.listen((dynamic command) {
    if (command == 'cancel') cancelled = true;
  });
  sendPort.send({'type': 'control', 'sendPort': control.sendPort});
  final payload = (message['payload']! as Map).cast<String, Object?>();
  final sources = (message['sources']! as List)
      .map((value) => (value as Map).cast<String, Object?>())
      .toList(growable: false);
  final partial = File(message['partialPath']! as String);
  final manifest = File(message['manifestPath']! as String);
  final limits = (message['limits']! as Map).cast<String, int>();
  final totalSourceBytes = message['totalSourceBytes']! as int;
  final totalEntries = sources.length + 1;
  var currentArchivePath = 'portable_export.json';
  String? currentSourcePath;
  var processedBytes = 0;
  ZipFileEncoder? encoder;

  void checkCancelled() {
    if (cancelled) throw const _WorkerCancelled();
  }

  void progress(
    PortableExportPhase phase,
    String status, {
    required int completedEntries,
  }) {
    sendPort.send({
      'type': 'progress',
      'phase': phase.name,
      'message': status,
      'completedEntries': completedEntries,
      'totalEntries': totalEntries,
      'processedBytes': processedBytes,
      'totalBytes': totalSourceBytes,
    });
  }

  try {
    if (await partial.exists()) await partial.delete();
    if (await manifest.exists()) await manifest.delete();
    checkCancelled();

    encoder = ZipFileEncoder()
      ..create(partial.path, level: ZipFileEncoder.STORE);

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      currentArchivePath = source['archivePath']! as String;
      currentSourcePath = source['sourcePath']! as String;
      final expectedBytes = source['bytes']! as int;
      final expectedModifiedMicros = source['modifiedMicros']! as int;
      final file = File(currentSourcePath);
      final type = await FileSystemEntity.type(
        currentSourcePath,
        followLinks: false,
      );
      checkCancelled();
      if (type != FileSystemEntityType.file) {
        throw const _WorkerFailure(
          'source_changed',
          'The source is missing, linked, or no longer a regular file.',
        );
      }
      final before = await file.stat();
      checkCancelled();
      if (before.size != expectedBytes ||
          before.modified.microsecondsSinceEpoch != expectedModifiedMicros) {
        throw const _WorkerFailure(
          'source_changed',
          'The source size or modification time changed after preflight.',
        );
      }
      final beforeDigest = await sha256.bind(file.openRead()).first;
      checkCancelled();
      await encoder.addFile(file, currentArchivePath, ZipFileEncoder.STORE);
      checkCancelled();
      final after = await file.stat();
      final afterDigest = await sha256.bind(file.openRead()).first;
      checkCancelled();
      if (after.size != expectedBytes ||
          after.modified.microsecondsSinceEpoch != expectedModifiedMicros ||
          beforeDigest != afterDigest) {
        throw const _WorkerFailure(
          'source_changed',
          'The source changed while it was being exported.',
        );
      }
      processedBytes += expectedBytes;
      progress(
        PortableExportPhase.addingFiles,
        'Added ${index + 1} of ${sources.length} file(s).',
        completedEntries: index + 1,
      );
    }

    currentArchivePath = 'portable_export.json';
    currentSourcePath = null;
    progress(
      PortableExportPhase.writingManifest,
      'Writing bounded portable metadata…',
      completedEntries: sources.length,
    );
    final manifestBytes = _writeBoundedJsonFile(
      manifest,
      payload,
      limits['maxManifestBytes']!,
    );
    checkCancelled();
    await encoder.addFile(
      manifest,
      'portable_export.json',
      ZipFileEncoder.STORE,
    );
    checkCancelled();
    await manifest.delete();
    await encoder.close();
    encoder = null;
    checkCancelled();
    sendPort.send({'type': 'ready', 'manifestBytes': manifestBytes});
  } on _WorkerCancelled {
    // The parent emits the terminal cancellation result after this worker has
    // released its archive and source handles in the finally block.
  } on _WorkerFailure catch (error) {
    sendPort.send({
      'type': 'error',
      'code': error.code,
      'message': error.message,
      'archivePath': currentArchivePath,
      'sourcePath': currentSourcePath,
    });
  } catch (error) {
    sendPort.send({
      'type': 'error',
      'code': 'file_error',
      'message': '$error',
      'archivePath': currentArchivePath,
      'sourcePath': currentSourcePath,
    });
  } finally {
    try {
      if (encoder != null) await encoder.close();
    } catch (_) {
      // The parent owns terminal partial-file cleanup.
    }
    try {
      if (await manifest.exists()) await manifest.delete();
    } catch (_) {
      // The parent also performs best-effort cleanup.
    }
    await controlSubscription.cancel();
    control.close();
  }
}

int _writeBoundedJsonFile(
  File destination,
  Map<String, Object?> payload,
  int maxBytes,
) {
  final output = destination.openSync(mode: FileMode.write);
  var written = 0;

  void write(String value) {
    final bytes = utf8.encode(value);
    if (written + bytes.length > maxBytes) {
      throw _WorkerFailure(
        'manifest_size_limit',
        'Portable metadata exceeds the $maxBytes-byte manifest limit.',
      );
    }
    output.writeFromSync(bytes);
    written += bytes.length;
  }

  try {
    write('{');
    var firstSection = true;
    for (final entry in payload.entries) {
      if (!firstSection) write(',');
      firstSection = false;
      write(jsonEncode(entry.key));
      write(':');
      final value = entry.value;
      if (value is List) {
        write('[');
        for (var index = 0; index < value.length; index++) {
          if (index > 0) write(',');
          write(jsonEncode(value[index]));
        }
        write(']');
      } else {
        write(jsonEncode(value));
      }
    }
    write('}');
    output.flushSync();
    return written;
  } finally {
    output.closeSync();
  }
}

class _WorkerFailure implements Exception {
  final String code;
  final String message;

  const _WorkerFailure(this.code, this.message);
}

class _WorkerCancelled implements Exception {
  const _WorkerCancelled();
}
