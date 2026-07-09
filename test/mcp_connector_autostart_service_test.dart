import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/mcp_connector_autostart_service.dart';

void main() {
  test('parses connector autostart config with safe defaults', () {
    final config = McpConnectorAutostartConfig.fromJson({
      'enabled': true,
      'resourceUrl': 'https://example.test/resource',
      'authorizationServers': ['https://auth.example.test/'],
      'jwksUrl': 'https://auth.example.test/.well-known/jwks.json',
    });

    expect(config.enabled, isTrue);
    expect(config.pythonPath, 'python');
    expect(config.gatewayScriptPath, 'tools/atlas_mcp_gateway.py');
    expect(
      config.projectAtlasExePath,
      'build/windows/x64/runner/Release/project_atlas.exe',
    );
    expect(config.host, '127.0.0.1');
    expect(config.port, 4874);
    expect(config.authMode, 'oauth');
    expect(config.scope, 'atlas.read');
    expect(config.tunnelEnabled, isTrue);
    expect(config.tunnelProfile, 'project-atlas');
  });

  test('skips autostart when local config is missing', () async {
    final temp = await Directory.systemTemp.createTemp(
      'atlas_mcp_autostart_missing_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final service = McpConnectorAutostartService(
      repoRoot: temp,
      configFile: File(p.join(temp.path, '.local', 'missing.json')),
      logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
    );

    final result = await service.startIfConfigured();

    expect(result.configFound, isFalse);
    expect(result.enabled, isFalse);
    expect(result.gatewayStarted, isFalse);
    expect(result.tunnelStarted, isFalse);
  });

  test('skips autostart when local config is disabled', () async {
    final temp = await Directory.systemTemp.createTemp(
      'atlas_mcp_autostart_disabled_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final configFile = File(
      p.join(temp.path, '.local', 'atlas_mcp_connector_autostart.json'),
    );
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(jsonEncode({'enabled': false}));

    final service = McpConnectorAutostartService(
      repoRoot: temp,
      configFile: configFile,
      logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
    );

    final result = await service.startIfConfigured();

    expect(result.configFound, isTrue);
    expect(result.enabled, isFalse);
    expect(result.gatewayStarted, isFalse);
    expect(result.tunnelStarted, isFalse);
  });
}
