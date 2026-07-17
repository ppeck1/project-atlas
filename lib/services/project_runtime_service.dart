import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../db/app_db.dart';

const defaultRuntimeManifestPath = r'.local\runtime_manifest.yaml';
const defaultProjectProtocolPath = r'.local\project_protocol';
const defaultCapsulePythonPath = 'python';

class RuntimeUrl {
  final String label;
  final String url;

  const RuntimeUrl({required this.label, required this.url});

  Map<String, Object?> toJson() => {'label': label, 'url': url};

  static RuntimeUrl? fromJson(Object? value) {
    if (value is! Map) return null;
    final url = value['url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    final label = value['label']?.toString().trim();
    return RuntimeUrl(
      label: label == null || label.isEmpty ? url : label,
      url: url,
    );
  }
}

class ProjectRuntimeProfileDraft {
  final bool enabled;
  final String? workingDirectory;
  final String? launchCommand;
  final String? stopCommand;
  final List<String> testCommands;
  final List<int> ports;
  final List<RuntimeUrl> urls;
  final List<String> healthUrls;
  final String? notes;
  final bool autostart;
  final bool capsuleEnabled;
  final String capsuleMode;
  final String? capsuleSourcePath;
  final String? capsuleProfile;
  final String? importSource;
  final DateTime? lastImportedAt;

  const ProjectRuntimeProfileDraft({
    required this.enabled,
    required this.workingDirectory,
    required this.launchCommand,
    required this.stopCommand,
    required this.testCommands,
    required this.ports,
    required this.urls,
    required this.healthUrls,
    required this.notes,
    required this.autostart,
    required this.capsuleEnabled,
    required this.capsuleMode,
    required this.capsuleSourcePath,
    required this.capsuleProfile,
    this.importSource,
    this.lastImportedAt,
  });

  factory ProjectRuntimeProfileDraft.empty({String? workingDirectory}) =>
      ProjectRuntimeProfileDraft(
        enabled: false,
        workingDirectory: _blankToNull(workingDirectory),
        launchCommand: null,
        stopCommand: null,
        testCommands: const [],
        ports: const [],
        urls: const [],
        healthUrls: const [],
        notes: null,
        autostart: false,
        capsuleEnabled: true,
        capsuleMode: 'check',
        capsuleSourcePath: defaultProjectProtocolPath,
        capsuleProfile: 'software_project',
      );

  factory ProjectRuntimeProfileDraft.fromProfile(
    ProjectRuntimeProfile profile,
  ) => ProjectRuntimeProfileDraft(
    enabled: profile.enabled,
    workingDirectory: profile.workingDirectory,
    launchCommand: profile.launchCommand,
    stopCommand: profile.stopCommand,
    testCommands: decodeStringList(profile.testCommandsJson),
    ports: decodeIntList(profile.portsJson),
    urls: decodeRuntimeUrls(profile.urlsJson),
    healthUrls: decodeStringList(profile.healthUrlsJson),
    notes: profile.notes,
    autostart: profile.autostart,
    capsuleEnabled: profile.capsuleEnabled,
    capsuleMode: normalizeCapsuleMode(profile.capsuleMode),
    capsuleSourcePath: profile.capsuleSourcePath,
    capsuleProfile: _blankToNull(profile.capsuleProfile),
    importSource: profile.importSource,
    lastImportedAt: profile.lastImportedAt,
  );

  ProjectRuntimeProfileDraft copyWith({
    bool? enabled,
    String? workingDirectory,
    String? launchCommand,
    String? stopCommand,
    List<String>? testCommands,
    List<int>? ports,
    List<RuntimeUrl>? urls,
    List<String>? healthUrls,
    String? notes,
    bool? autostart,
    bool? capsuleEnabled,
    String? capsuleMode,
    String? capsuleSourcePath,
    String? capsuleProfile,
    String? importSource,
    DateTime? lastImportedAt,
  }) => ProjectRuntimeProfileDraft(
    enabled: enabled ?? this.enabled,
    workingDirectory: workingDirectory ?? this.workingDirectory,
    launchCommand: launchCommand ?? this.launchCommand,
    stopCommand: stopCommand ?? this.stopCommand,
    testCommands: testCommands ?? this.testCommands,
    ports: ports ?? this.ports,
    urls: urls ?? this.urls,
    healthUrls: healthUrls ?? this.healthUrls,
    notes: notes ?? this.notes,
    autostart: autostart ?? this.autostart,
    capsuleEnabled: capsuleEnabled ?? this.capsuleEnabled,
    capsuleMode: capsuleMode ?? this.capsuleMode,
    capsuleSourcePath: capsuleSourcePath ?? this.capsuleSourcePath,
    capsuleProfile: capsuleProfile ?? this.capsuleProfile,
    importSource: importSource ?? this.importSource,
    lastImportedAt: lastImportedAt ?? this.lastImportedAt,
  );
}

class ProjectRuntimeDefaultsSettings {
  final String? runtimeManifestPath;
  final bool capsuleEnabled;
  final String capsuleMode;
  final String capsuleSourcePath;
  final String? capsuleProfile;

  const ProjectRuntimeDefaultsSettings({
    this.runtimeManifestPath,
    this.capsuleEnabled = true,
    this.capsuleMode = 'check',
    this.capsuleSourcePath = defaultProjectProtocolPath,
    this.capsuleProfile = 'software_project',
  });

  String get resolvedRuntimeManifestPath =>
      _blankToNull(runtimeManifestPath) ?? defaultRuntimeManifestPath;

  ProjectRuntimeProfileDraft emptyDraft({String? workingDirectory}) =>
      applyToImportedDraft(
        ProjectRuntimeProfileDraft.empty(workingDirectory: workingDirectory),
      );

  ProjectRuntimeProfileDraft applyToImportedDraft(
    ProjectRuntimeProfileDraft draft,
  ) => ProjectRuntimeProfileDraft(
    enabled: draft.enabled,
    workingDirectory: draft.workingDirectory,
    launchCommand: draft.launchCommand,
    stopCommand: draft.stopCommand,
    testCommands: draft.testCommands,
    ports: draft.ports,
    urls: draft.urls,
    healthUrls: draft.healthUrls,
    notes: draft.notes,
    autostart: draft.autostart,
    capsuleEnabled: capsuleEnabled,
    capsuleMode: normalizeCapsuleMode(capsuleMode),
    capsuleSourcePath:
        _blankToNull(capsuleSourcePath) ?? defaultProjectProtocolPath,
    capsuleProfile: _blankToNull(capsuleProfile),
    importSource: draft.importSource,
    lastImportedAt: draft.lastImportedAt,
  );
}

class RuntimeManifestImporter {
  const RuntimeManifestImporter();

  Future<ProjectRuntimeProfileDraft?> readProfileForProject({
    required String projectTitle,
    String yamlPath = defaultRuntimeManifestPath,
  }) async {
    final file = File(yamlPath);
    if (!await file.exists()) {
      throw StateError('Runtime manifest not found: $yamlPath');
    }
    final content = await file.readAsString();
    final decoded = loadYaml(content);
    if (decoded is! YamlMap) {
      throw const FormatException('Runtime manifest root is not a map.');
    }
    final apps = decoded['apps'];
    if (apps is! YamlList) return null;
    final titleKey = _nameKey(projectTitle);
    YamlMap? match;
    for (final app in apps) {
      if (app is! YamlMap) continue;
      final name = app['name']?.toString();
      if (_nameKey(name ?? '') == titleKey) {
        match = app;
        break;
      }
    }
    if (match == null) return null;

    return ProjectRuntimeProfileDraft(
      enabled: true,
      workingDirectory: _blankToNull(match['path']?.toString()),
      launchCommand: _blankToNull(match['start']?.toString()),
      stopCommand: _blankToNull(match['stop']?.toString()),
      testCommands: _commandsFromYaml(match['tests']),
      ports: _portsFromYaml(match['ports']),
      urls: _urlsFromYaml(match['urls']),
      healthUrls: _stringsFromYaml(match['health_urls']),
      notes: _blankToNull(match['notes']?.toString()),
      autostart: match['autostart'] == true,
      capsuleEnabled: true,
      capsuleMode: 'check',
      capsuleSourcePath: defaultProjectProtocolPath,
      capsuleProfile: 'software_project',
      importSource: yamlPath,
      lastImportedAt: DateTime.now(),
    );
  }

  List<String> _commandsFromYaml(Object? value) {
    if (value is YamlList || value is List) {
      return [
        for (final item in value as Iterable)
          if (_blankToNull(item?.toString()) != null) item.toString().trim(),
      ];
    }
    final command = _blankToNull(value?.toString());
    return command == null ? const [] : [command];
  }

  List<String> _stringsFromYaml(Object? value) {
    if (value is YamlList || value is List) {
      return [
        for (final item in value as Iterable)
          if (_blankToNull(item?.toString()) != null) item.toString().trim(),
      ];
    }
    final item = _blankToNull(value?.toString());
    return item == null ? const [] : [item];
  }

  List<int> _portsFromYaml(Object? value) {
    final result = <int>[];
    for (final item in _stringsFromYaml(value)) {
      final port = int.tryParse(item);
      if (port != null) result.add(port);
    }
    return result;
  }

  List<RuntimeUrl> _urlsFromYaml(Object? value) {
    if (value is! Iterable) return const [];
    final result = <RuntimeUrl>[];
    for (final item in value) {
      if (item is YamlMap || item is Map) {
        final map = item as Map;
        final url = _blankToNull(map['url']?.toString());
        if (url == null) continue;
        result.add(
          RuntimeUrl(
            label: _blankToNull(map['label']?.toString()) ?? url,
            url: url,
          ),
        );
      }
    }
    return result;
  }
}

class ProjectRuntimeService {
  final AppDb db;
  final String pythonPath;

  const ProjectRuntimeService({
    required this.db,
    this.pythonPath = defaultCapsulePythonPath,
  });

  Future<ProjectRuntimeRun> runLaunch(ProjectRuntimeProfile profile) async {
    final command = _requireCommand(profile.launchCommand, 'Launch command');
    final run = await db.startProjectRuntimeRun(
      profileId: profile.id,
      projectId: profile.projectId,
      action: 'launch',
      command: command,
    );
    final capsule = await _runCapsulePreflight(profile);
    if (capsule.shouldBlock) {
      return db.finishProjectRuntimeRun(
        id: run.id,
        status: 'failed',
        errorText: 'Capsule preflight failed.',
        capsuleStatus: capsule.status,
        capsuleOutputText: capsule.output,
      );
    }
    try {
      final launch = await _startLaunchCommand(command, profile, run.id);
      if (launch.exitCode != 0) {
        return db.finishProjectRuntimeRun(
          id: run.id,
          status: 'failed',
          exitCode: launch.exitCode,
          outputText: launch.output,
          errorText: launch.error,
          capsuleStatus: capsule.status,
          capsuleOutputText: capsule.output,
        );
      }
      final readiness = await _waitForReadiness(profile);
      final outputText = [
        launch.output,
        if (readiness.message != null) readiness.message,
      ].whereType<String>().join('\n');
      final launchStatus = readiness.checked && !readiness.ready
          ? 'failed'
          : 'started';
      return db.finishProjectRuntimeRun(
        id: run.id,
        status: launchStatus,
        exitCode: launch.exitCode,
        outputText: outputText,
        errorText: launchStatus == 'failed' ? readiness.message : launch.error,
        capsuleStatus: capsule.status,
        capsuleOutputText: capsule.output,
        metadataJson: jsonEncode({
          if (launch.pid != null) 'pid': launch.pid,
          if (launch.wrapperPath != null) 'wrapperPath': launch.wrapperPath,
        }),
      );
    } catch (error) {
      return db.finishProjectRuntimeRun(
        id: run.id,
        status: 'failed',
        errorText: error.toString(),
        capsuleStatus: capsule.status,
        capsuleOutputText: capsule.output,
      );
    }
  }

  Future<ProjectRuntimeRun> runTest(
    ProjectRuntimeProfile profile, {
    String? command,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    final resolved = _requireCommand(
      command ?? decodeStringList(profile.testCommandsJson).firstOrNull,
      'Test command',
    );
    final run = await db.startProjectRuntimeRun(
      profileId: profile.id,
      projectId: profile.projectId,
      action: 'test',
      command: resolved,
    );
    final capsule = await _runCapsulePreflight(profile);
    if (capsule.shouldBlock) {
      return db.finishProjectRuntimeRun(
        id: run.id,
        status: 'failed',
        errorText: 'Capsule preflight failed.',
        capsuleStatus: capsule.status,
        capsuleOutputText: capsule.output,
      );
    }
    final result = await _runShellCommand(
      resolved,
      workingDirectory: _workingDirectory(profile),
      timeout: timeout,
    );
    return db.finishProjectRuntimeRun(
      id: run.id,
      status: result.exitCode == 0 ? 'succeeded' : 'failed',
      exitCode: result.exitCode,
      outputText: result.stdout,
      errorText: result.stderr,
      capsuleStatus: capsule.status,
      capsuleOutputText: capsule.output,
    );
  }

  Future<ProjectRuntimeRun> runCapsule(ProjectRuntimeProfile profile) async {
    final run = await db.startProjectRuntimeRun(
      profileId: profile.id,
      projectId: profile.projectId,
      action: 'capsule',
      command: 'Project protocol verification',
    );
    final capsule = await _runCapsulePreflight(profile, force: true);
    return db.finishProjectRuntimeRun(
      id: run.id,
      status: capsule.isReady ? 'succeeded' : 'failed',
      exitCode: capsule.exitCode,
      outputText: capsule.output,
      errorText: capsule.error,
      capsuleStatus: capsule.status,
      capsuleOutputText: capsule.output,
    );
  }

  Future<_LaunchResult> _startLaunchCommand(
    String command,
    ProjectRuntimeProfile profile,
    String runId,
  ) async {
    if (Platform.isWindows) {
      return _startWindowsVisibleLaunch(command, profile, runId);
    }
    final shell = _shellCommand(command);
    final process = await Process.start(
      shell.executable,
      shell.args,
      workingDirectory: _workingDirectory(profile),
      mode: ProcessStartMode.detached,
    );
    return _LaunchResult(
      exitCode: 0,
      output: 'Started process ${process.pid}.',
      pid: process.pid,
    );
  }

  Future<_LaunchResult> _startWindowsVisibleLaunch(
    String command,
    ProjectRuntimeProfile profile,
    String runId,
  ) async {
    final workingDirectory = _workingDirectory(profile);
    final scriptDir = Directory(
      p.join(Directory.systemTemp.path, 'project_atlas_runtime'),
    );
    await scriptDir.create(recursive: true);
    final scriptFile = File(
      p.join(scriptDir.path, '${_safeFileStem(runId)}.ps1'),
    );
    await scriptFile.writeAsString('''
\$ErrorActionPreference = 'Stop'
${workingDirectory == null ? '' : 'Set-Location -LiteralPath ${_psQuote(workingDirectory)}'}
$command
''');

    final argumentList = [
      '-NoExit',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptFile.path,
    ].map(_psQuote).join(', ');
    final startScript =
        '''
\$process = Start-Process -FilePath 'powershell.exe' -ArgumentList @($argumentList) -WindowStyle Normal -PassThru${workingDirectory == null ? '' : ' -WorkingDirectory ${_psQuote(workingDirectory)}'}
Write-Output \$process.Id
''';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      startScript,
    ], workingDirectory: workingDirectory).timeout(const Duration(seconds: 15));
    final output = _trimOutput('${result.stdout}');
    final error = _trimOutput('${result.stderr}');
    final pid = int.tryParse(output.split(RegExp(r'\s+')).last.trim());
    return _LaunchResult(
      exitCode: result.exitCode,
      output: [
        if (pid != null) 'Started visible PowerShell process $pid.',
        if (pid == null && output.isNotEmpty) output,
        'Launch wrapper: ${scriptFile.path}',
      ].join('\n'),
      error: error,
      pid: pid,
      wrapperPath: scriptFile.path,
    );
  }

  Future<_ReadinessResult> _waitForReadiness(
    ProjectRuntimeProfile profile, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final healthUrls = decodeStringList(profile.healthUrlsJson);
    final ports = decodeIntList(profile.portsJson);
    if (healthUrls.isEmpty && ports.isEmpty) {
      return const _ReadinessResult(checked: false, ready: true);
    }

    final deadline = DateTime.now().add(timeout);
    var lastMessage = 'Readiness checks did not complete.';
    while (DateTime.now().isBefore(deadline)) {
      if (healthUrls.isNotEmpty) {
        final failed = <String>[];
        for (final url in healthUrls) {
          if (!await _probeUrl(url)) failed.add(url);
        }
        if (failed.isEmpty) {
          return _ReadinessResult(
            checked: true,
            ready: true,
            message: 'Readiness confirmed: ${healthUrls.join(', ')}',
          );
        }
        lastMessage = 'Waiting for health checks: ${failed.join(', ')}';
      } else {
        final failed = <int>[];
        for (final port in ports) {
          if (!await _probeTcpPort(port)) failed.add(port);
        }
        if (failed.isEmpty) {
          return _ReadinessResult(
            checked: true,
            ready: true,
            message: 'Readiness confirmed: ports ${ports.join(', ')}',
          );
        }
        lastMessage = 'Waiting for ports: ${failed.join(', ')}';
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return _ReadinessResult(
      checked: true,
      ready: false,
      message: '$lastMessage timed out after ${timeout.inSeconds}s.',
    );
  }

  Future<bool> _probeUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (e) {
      debugPrint('[Atlas] ProjectRuntimeService._probeUrl: health check for URL failed (not yet ready): $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _probeTcpPort(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 1),
      );
      await socket.close();
      return true;
    } catch (e) {
      debugPrint('[Atlas] ProjectRuntimeService._probeTcpPort: port $port not yet open: $e');
      return false;
    }
  }

  Future<_CapsulePreflightResult> _runCapsulePreflight(
    ProjectRuntimeProfile profile, {
    bool force = false,
  }) async {
    if (!force && (!profile.capsuleEnabled || profile.capsuleMode == 'off')) {
      return const _CapsulePreflightResult(status: 'skipped');
    }
    final root = _blankToNull(profile.workingDirectory);
    if (root == null) {
      return const _CapsulePreflightResult(
        status: 'not_ready',
        error: 'No working directory configured.',
        exitCode: 1,
      );
    }
    final capsuleRoot =
        _blankToNull(profile.capsuleSourcePath) ?? defaultProjectProtocolPath;
    final script = File(p.join(capsuleRoot, 'scripts', 'capsule_doctor.py'));
    if (!await script.exists()) {
      return _CapsulePreflightResult(
        status: 'not_ready',
        error: 'Capsule doctor not found: ${script.path}',
        exitCode: 1,
      );
    }
    final args = <String>[
      script.path,
      root,
      '--json',
      if (_blankToNull(profile.capsuleProfile) != null) ...[
        '--profile',
        profile.capsuleProfile!.trim(),
      ],
      if (profile.capsuleMode == 'strict_check') '--strict',
    ];
    try {
      final result = await Process.run(
        pythonPath,
        args,
        workingDirectory: capsuleRoot,
      ).timeout(const Duration(minutes: 2));
      final output = _trimOutput('${result.stdout}');
      final error = _trimOutput('${result.stderr}');
      return _CapsulePreflightResult(
        status: _doctorStatus(output, result.exitCode),
        output: output,
        error: error,
        exitCode: result.exitCode,
        strict: profile.capsuleMode == 'strict_check',
      );
    } on TimeoutException {
      return const _CapsulePreflightResult(
        status: 'not_ready',
        error: 'Capsule doctor timed out.',
        exitCode: 124,
      );
    } catch (error) {
      return _CapsulePreflightResult(
        status: 'not_ready',
        error: error.toString(),
        exitCode: 1,
      );
    }
  }

  Future<_ShellResult> _runShellCommand(
    String command, {
    required String? workingDirectory,
    required Duration timeout,
  }) async {
    final shell = _shellCommand(command);
    try {
      final result = await Process.run(
        shell.executable,
        shell.args,
        workingDirectory: workingDirectory,
      ).timeout(timeout);
      return _ShellResult(
        exitCode: result.exitCode,
        stdout: _trimOutput('${result.stdout}'),
        stderr: _trimOutput('${result.stderr}'),
      );
    } on TimeoutException {
      return const _ShellResult(
        exitCode: 124,
        stdout: '',
        stderr: 'Command timed out.',
      );
    } catch (error) {
      return _ShellResult(exitCode: 1, stdout: '', stderr: error.toString());
    }
  }

  _ShellCommand _shellCommand(String command) {
    if (Platform.isWindows) {
      return _ShellCommand('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ]);
    }
    return _ShellCommand('/bin/sh', ['-lc', command]);
  }

  String? _workingDirectory(ProjectRuntimeProfile profile) {
    final path = _blankToNull(profile.workingDirectory);
    if (path == null) return null;
    return path;
  }

  String _requireCommand(String? command, String label) {
    final clean = _blankToNull(command);
    if (clean == null) throw StateError('$label is not configured.');
    return clean;
  }

  String _safeFileStem(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  String _doctorStatus(String output, int exitCode) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['doctor_result'] is String) {
        return decoded['doctor_result'] as String;
      }
    } catch (e) {
      debugPrint('[Atlas] ProjectRuntimeService._doctorStatus: JSON decode of capsule doctor output failed: $e');
    }
    return exitCode == 0 ? 'healthy' : 'not_ready';
  }
}

class _ShellCommand {
  final String executable;
  final List<String> args;

  const _ShellCommand(this.executable, this.args);
}

class _ShellResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _ShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

class _LaunchResult {
  final int exitCode;
  final String output;
  final String? error;
  final int? pid;
  final String? wrapperPath;

  const _LaunchResult({
    required this.exitCode,
    required this.output,
    this.error,
    this.pid,
    this.wrapperPath,
  });
}

class _ReadinessResult {
  final bool checked;
  final bool ready;
  final String? message;

  const _ReadinessResult({
    required this.checked,
    required this.ready,
    this.message,
  });
}

class _CapsulePreflightResult {
  final String status;
  final String? output;
  final String? error;
  final int? exitCode;
  final bool strict;

  const _CapsulePreflightResult({
    required this.status,
    this.output,
    this.error,
    this.exitCode,
    this.strict = false,
  });

  bool get isReady => status == 'healthy' || status == 'usable_with_warnings';
  bool get shouldBlock => strict && !isReady;
}

List<String> decodeStringList(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (_blankToNull(item?.toString()) != null) item.toString().trim(),
    ];
  } catch (e) {
    debugPrint('[Atlas] decodeStringList (project_runtime_service): JSON decode failed: $e');
    return const [];
  }
}

List<int> decodeIntList(String? rawJson) {
  return [
    for (final value in decodeStringList(rawJson))
      if (int.tryParse(value) != null) int.parse(value),
  ];
}

List<RuntimeUrl> decodeRuntimeUrls(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (RuntimeUrl.fromJson(item) != null) RuntimeUrl.fromJson(item)!,
    ];
  } catch (e) {
    debugPrint('[Atlas] decodeRuntimeUrls (project_runtime_service): JSON decode failed: $e');
    return const [];
  }
}

String encodeStringList(Iterable<String> values) => jsonEncode([
  for (final value in values)
    if (_blankToNull(value) != null) value.trim(),
]);

String encodeIntList(Iterable<int> values) => jsonEncode(values.toList());

String encodeRuntimeUrls(Iterable<RuntimeUrl> values) =>
    jsonEncode(values.map((value) => value.toJson()).toList());

String normalizeCapsuleMode(String? value) {
  final clean = _blankToNull(value)?.toLowerCase();
  return const {'off', 'check', 'strict_check'}.contains(clean)
      ? clean!
      : 'check';
}

String _nameKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

String _trimOutput(String value, {int maxChars = 12000}) {
  final clean = value.replaceAll('\u0000', '').trimRight();
  if (clean.length <= maxChars) return clean;
  return '${clean.substring(clean.length - maxChars)}\n[output truncated]';
}

String? _blankToNull(String? value) {
  final clean = value?.trim();
  return clean == null || clean.isEmpty ? null : clean;
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
