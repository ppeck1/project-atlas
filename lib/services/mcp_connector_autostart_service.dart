import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class McpConnectorAutostartConfig {
  final bool enabled;
  final String pythonPath;
  final String gatewayScriptPath;
  final String projectAtlasExePath;
  final String host;
  final int port;
  final String authMode;
  final String? resourceUrl;
  final List<String> authorizationServers;
  final String scope;
  final String? jwksUrl;
  final String? introspectionUrl;
  final List<String> allowedOrigins;
  final bool tunnelEnabled;
  final String? tunnelClientPath;
  final String tunnelProfile;
  final String tunnelProfileDir;

  const McpConnectorAutostartConfig({
    required this.enabled,
    required this.pythonPath,
    required this.gatewayScriptPath,
    required this.projectAtlasExePath,
    required this.host,
    required this.port,
    required this.authMode,
    required this.resourceUrl,
    required this.authorizationServers,
    required this.scope,
    required this.jwksUrl,
    required this.introspectionUrl,
    required this.allowedOrigins,
    required this.tunnelEnabled,
    required this.tunnelClientPath,
    required this.tunnelProfile,
    required this.tunnelProfileDir,
  });

  factory McpConnectorAutostartConfig.fromJson(Map<String, Object?> json) {
    return McpConnectorAutostartConfig(
      enabled: json['enabled'] == true,
      pythonPath: _string(json['pythonPath']) ?? 'python',
      gatewayScriptPath:
          _string(json['gatewayScriptPath']) ?? 'tools/atlas_mcp_gateway.py',
      projectAtlasExePath:
          _string(json['projectAtlasExePath']) ??
          'build/windows/x64/runner/Release/project_atlas.exe',
      host: _string(json['host']) ?? '127.0.0.1',
      port: _int(json['port']) ?? 4874,
      authMode: _string(json['authMode']) ?? 'oauth',
      resourceUrl: _string(json['resourceUrl']),
      authorizationServers: _stringList(json['authorizationServers']),
      scope: _string(json['scope']) ?? 'atlas.read',
      jwksUrl: _string(json['jwksUrl']),
      introspectionUrl: _string(json['introspectionUrl']),
      allowedOrigins: _stringList(json['allowedOrigins']),
      tunnelEnabled: json['tunnelEnabled'] != false,
      tunnelClientPath: _string(json['tunnelClientPath']),
      tunnelProfile: _string(json['tunnelProfile']) ?? 'project-atlas',
      tunnelProfileDir:
          _string(json['tunnelProfileDir']) ?? '.local/tunnel-client/profiles',
    );
  }

  bool get usesOAuth => authMode == 'oauth';

  Uri get gatewayMetadataUri =>
      Uri.parse('http://$host:$port/.well-known/project-atlas-mcp');

  static String? _string(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static List<String> _stringList(Object? value) {
    if (value is! Iterable) return const [];
    return [
      for (final item in value)
        if (_string(item) != null) _string(item)!,
    ];
  }
}

class McpConnectorAutostartResult {
  final bool configFound;
  final bool enabled;
  final bool gatewayStarted;
  final bool gatewayAlreadyHealthy;
  final bool tunnelStarted;
  final bool tunnelAlreadyHealthy;
  final String? message;

  const McpConnectorAutostartResult({
    required this.configFound,
    required this.enabled,
    required this.gatewayStarted,
    required this.gatewayAlreadyHealthy,
    required this.tunnelStarted,
    required this.tunnelAlreadyHealthy,
    this.message,
  });

  Map<String, Object?> toJson() => {
    'configFound': configFound,
    'enabled': enabled,
    'gatewayStarted': gatewayStarted,
    'gatewayAlreadyHealthy': gatewayAlreadyHealthy,
    'tunnelStarted': tunnelStarted,
    'tunnelAlreadyHealthy': tunnelAlreadyHealthy,
    if (message != null) 'message': message,
  };
}

class McpConnectorAutostartService {
  final Directory repoRoot;
  final File configFile;
  final File logFile;

  McpConnectorAutostartService({
    Directory? repoRoot,
    File? configFile,
    File? logFile,
  }) : repoRoot = repoRoot ?? _detectRepoRoot(),
       configFile =
           configFile ??
           File(
             p.join(
               (repoRoot ?? _detectRepoRoot()).path,
               '.local',
               'atlas_mcp_connector_autostart.json',
             ),
           ),
       logFile =
           logFile ??
           File(
             p.join(
               (repoRoot ?? _detectRepoRoot()).path,
               '.local',
               'runs',
               'atlas-mcp-connector-autostart.log',
             ),
           );

  Future<McpConnectorAutostartResult> startIfConfigured() async {
    if (!Platform.isWindows) {
      return _record(
        const McpConnectorAutostartResult(
          configFound: false,
          enabled: false,
          gatewayStarted: false,
          gatewayAlreadyHealthy: false,
          tunnelStarted: false,
          tunnelAlreadyHealthy: false,
          message: 'Skipped: connector autostart is Windows-only.',
        ),
      );
    }
    if (!await configFile.exists()) {
      return _record(
        const McpConnectorAutostartResult(
          configFound: false,
          enabled: false,
          gatewayStarted: false,
          gatewayAlreadyHealthy: false,
          tunnelStarted: false,
          tunnelAlreadyHealthy: false,
          message: 'Skipped: no local autostart config file.',
        ),
      );
    }

    try {
      final decoded = jsonDecode(await configFile.readAsString());
      if (decoded is! Map<String, Object?>) {
        return _record(
          const McpConnectorAutostartResult(
            configFound: true,
            enabled: false,
            gatewayStarted: false,
            gatewayAlreadyHealthy: false,
            tunnelStarted: false,
            tunnelAlreadyHealthy: false,
            message: 'Skipped: autostart config root is not an object.',
          ),
        );
      }
      final config = McpConnectorAutostartConfig.fromJson(decoded);
      if (!config.enabled) {
        return _record(
          const McpConnectorAutostartResult(
            configFound: true,
            enabled: false,
            gatewayStarted: false,
            gatewayAlreadyHealthy: false,
            tunnelStarted: false,
            tunnelAlreadyHealthy: false,
            message: 'Skipped: autostart config is disabled.',
          ),
        );
      }

      final gatewayHealthy = await _projectAtlasGatewayHealthy(config);
      var gatewayStarted = false;
      if (!gatewayHealthy) {
        await _startGateway(config);
        gatewayStarted = true;
      }

      final tunnelHealthy = await _tunnelHealthy();
      var tunnelStarted = false;
      if (config.tunnelEnabled && !tunnelHealthy) {
        await _startTunnel(config);
        tunnelStarted = config.tunnelClientPath != null;
      }

      return _record(
        McpConnectorAutostartResult(
          configFound: true,
          enabled: true,
          gatewayStarted: gatewayStarted,
          gatewayAlreadyHealthy: gatewayHealthy,
          tunnelStarted: tunnelStarted,
          tunnelAlreadyHealthy: tunnelHealthy,
        ),
      );
    } catch (error) {
      return _record(
        McpConnectorAutostartResult(
          configFound: true,
          enabled: false,
          gatewayStarted: false,
          gatewayAlreadyHealthy: false,
          tunnelStarted: false,
          tunnelAlreadyHealthy: false,
          message: 'Autostart failed: $error',
        ),
      );
    }
  }

  Future<bool> _projectAtlasGatewayHealthy(
    McpConnectorAutostartConfig config,
  ) async {
    final payload = await _getJson(config.gatewayMetadataUri);
    return payload?['name'] == 'Project Atlas MCP Gateway';
  }

  Future<bool> _tunnelHealthy() async {
    final urlFile = File(
      p.join(repoRoot.path, '.local', 'runs', 'tunnel-client-health.url'),
    );
    if (!await urlFile.exists()) return false;
    final baseUrl = (await urlFile.readAsString()).trim();
    if (baseUrl.isEmpty) return false;
    final uri = Uri.tryParse('$baseUrl/readyz');
    if (uri == null) return false;
    final response = await _getText(uri);
    return response?.startsWith('ready') == true;
  }

  Future<Map<String, Object?>?> _getJson(Uri uri) async {
    final text = await _getText(uri);
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getText(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _startGateway(McpConnectorAutostartConfig config) async {
    _validateGatewayConfig(config);
    final runsDir = Directory(p.join(repoRoot.path, '.local', 'runs'));
    await runsDir.create(recursive: true);
    final args = <String>[
      _resolve(config.gatewayScriptPath),
      '--host',
      config.host,
      '--port',
      config.port.toString(),
      '--exe',
      _resolve(config.projectAtlasExePath),
      '--auth-mode',
      config.authMode,
      '--scope',
      config.scope,
      if (config.resourceUrl != null) ...[
        '--resource-url',
        config.resourceUrl!,
      ],
      for (final server in config.authorizationServers) ...[
        '--authorization-server',
        server,
      ],
      if (config.jwksUrl != null) ...['--jwks-url', config.jwksUrl!],
      if (config.introspectionUrl != null) ...[
        '--introspection-url',
        config.introspectionUrl!,
      ],
      for (final origin in config.allowedOrigins) ...[
        '--allowed-origin',
        origin,
      ],
    ];
    await _startHiddenProcess(
      executable: config.pythonPath,
      args: args,
      stdoutPath: p.join(runsDir.path, 'atlas-mcp-gateway-autostart.out.log'),
      stderrPath: p.join(runsDir.path, 'atlas-mcp-gateway-autostart.err.log'),
      workingDirectory: repoRoot.path,
    );
  }

  Future<void> _startTunnel(McpConnectorAutostartConfig config) async {
    final tunnelClientPath = config.tunnelClientPath;
    if (tunnelClientPath == null) return;
    final runsDir = Directory(p.join(repoRoot.path, '.local', 'runs'));
    await runsDir.create(recursive: true);
    await _startHiddenProcess(
      executable: _resolve(tunnelClientPath),
      args: [
        'run',
        '--profile',
        config.tunnelProfile,
        '--profile-dir',
        _resolve(config.tunnelProfileDir),
        '--health.url-file',
        p.join(runsDir.path, 'tunnel-client-health.url'),
        '--pid.file',
        p.join(runsDir.path, 'tunnel-client.pid'),
        '--log.file',
        p.join(runsDir.path, 'tunnel-client-autostart.log'),
        '--log.format',
        'json',
      ],
      stdoutPath: p.join(runsDir.path, 'tunnel-client-autostart.out.log'),
      stderrPath: p.join(runsDir.path, 'tunnel-client-autostart.err.log'),
      workingDirectory: repoRoot.path,
    );
  }

  void _validateGatewayConfig(McpConnectorAutostartConfig config) {
    if (config.usesOAuth) {
      if (config.resourceUrl == null || config.authorizationServers.isEmpty) {
        throw StateError(
          'OAuth autostart requires resourceUrl and authorizationServers.',
        );
      }
      if (config.jwksUrl == null && config.introspectionUrl == null) {
        throw StateError(
          'OAuth autostart requires jwksUrl or introspectionUrl.',
        );
      }
    }
  }

  Future<void> _startHiddenProcess({
    required String executable,
    required List<String> args,
    required String stdoutPath,
    required String stderrPath,
    required String workingDirectory,
  }) async {
    final psArgs = args.map(_psQuote).join(', ');
    final script =
        '''
\$processPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
if ([string]::IsNullOrWhiteSpace(\$processPath)) {
  \$processPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
}
if (-not [string]::IsNullOrWhiteSpace(\$processPath)) {
  [Environment]::SetEnvironmentVariable('PATH', \$null, 'Process')
  [Environment]::SetEnvironmentVariable('Path', \$processPath, 'Process')
}
Start-Process -FilePath ${_psQuote(executable)} -ArgumentList @($psArgs) -WorkingDirectory ${_psQuote(workingDirectory)} -WindowStyle Hidden -RedirectStandardOutput ${_psQuote(stdoutPath)} -RedirectStandardError ${_psQuote(stderrPath)}
''';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ], workingDirectory: workingDirectory).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to start ${p.basename(executable)}: ${result.stderr}',
      );
    }
  }

  Future<McpConnectorAutostartResult> _record(
    McpConnectorAutostartResult result,
  ) async {
    try {
      await logFile.parent.create(recursive: true);
      await logFile.writeAsString(
        '${DateTime.now().toIso8601String()} ${jsonEncode(result.toJson())}\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Startup should never fail just because the local log cannot be written.
    }
    return result;
  }

  String _resolve(String value) {
    final normalized = value.replaceAll('/', p.separator);
    if (p.isAbsolute(normalized)) return normalized;
    return p.normalize(p.join(repoRoot.path, normalized));
  }

  static Directory _detectRepoRoot() {
    var current = Directory.current;
    final executable = File(Platform.resolvedExecutable);
    if (_looksLikeRepoRoot(current)) return current;

    current = executable.parent;
    for (var i = 0; i < 8; i += 1) {
      if (_looksLikeRepoRoot(current)) return current;
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return Directory.current;
  }

  static bool _looksLikeRepoRoot(Directory dir) {
    return File(p.join(dir.path, 'tools', 'atlas_mcp_gateway.py')).existsSync();
  }

  static String _psQuote(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }
}
