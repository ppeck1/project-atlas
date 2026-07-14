import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    expect(
      config.disclosurePolicyPath,
      '.local/atlas_mcp_remote_disclosure.json',
    );
    expect(
      config.disclosureAuditLogPath,
      '.local/runs/atlas-mcp-disclosure-audit.jsonl',
    );
    expect(config.host, '127.0.0.1');
    expect(config.port, 4874);
    expect(config.authMode, 'oauth');
    expect(config.scope, 'atlas.read');
    expect(config.tunnelEnabled, isTrue);
    expect(config.tunnelProfile, 'project-atlas');
  });

  test('accepts an explicit shared disclosure audit path', () {
    final config = McpConnectorAutostartConfig.fromJson({
      'disclosureAuditLogPath': r'D:\atlas-state\remote-audit.jsonl',
    });

    expect(config.disclosureAuditLogPath, r'D:\atlas-state\remote-audit.jsonl');
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

  test('accepts only hardened gateway metadata as already healthy', () async {
    final temp = await Directory.systemTemp.createTemp(
      'atlas_mcp_autostart_hardened_health_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final policyFile = await _writeTestPolicy(temp);
    final expectedDigest = sha256
        .convert(await policyFile.readAsBytes())
        .toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          _healthyMetadata(
            policyMatches:
                request.headers.value('X-Project-Atlas-Policy-Digest') ==
                expectedDigest,
          ),
        ),
      );
      await request.response.close();
    });

    final configFile = File(
      p.join(temp.path, '.local', 'atlas_mcp_connector_autostart.json'),
    );
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(
      jsonEncode({
        'enabled': true,
        'host': '127.0.0.1',
        'port': server.port,
        'authMode': 'static',
        'tunnelEnabled': false,
      }),
    );

    final service = McpConnectorAutostartService(
      repoRoot: temp,
      configFile: configFile,
      logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
    );

    final result = await service.startIfConfigured();

    expect(result.gatewayAlreadyHealthy, isTrue);
    expect(result.gatewayStarted, isFalse);
    expect(result.tunnelStarted, isFalse);
  });

  test('refuses to treat legacy gateway metadata as healthy', () async {
    final temp = await Directory.systemTemp.createTemp(
      'atlas_mcp_autostart_legacy_health_',
    );
    addTearDown(() => temp.delete(recursive: true));
    await _writeTestPolicy(temp);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'name': 'Project Atlas MCP Gateway'}));
      await request.response.close();
    });

    final configFile = File(
      p.join(temp.path, '.local', 'atlas_mcp_connector_autostart.json'),
    );
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString(
      jsonEncode({
        'enabled': true,
        'host': '127.0.0.1',
        'port': server.port,
        'authMode': 'static',
        'tunnelEnabled': false,
      }),
    );
    final service = McpConnectorAutostartService(
      repoRoot: temp,
      configFile: configFile,
      logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
    );

    final result = await service.startIfConfigured();

    expect(result.enabled, isFalse);
    expect(result.gatewayStarted, isFalse);
    expect(result.message, contains('current-policy projection boundary'));
  });

  test('refuses stale policy, extra tools, and wrong auth metadata', () async {
    final variants = <String, Map<String, Object?>>{
      'stale_policy': _healthyMetadata(policyMatches: false),
      'extra_tool': _healthyMetadata(
        policyMatches: true,
        allowedTools: [..._testRemoteTools, 'get_project_brief'],
      ),
      'wrong_auth': _healthyMetadata(
        policyMatches: true,
        auth: {'type': 'oauth2', 'mode': 'oauth', 'scope': 'atlas.read'},
      ),
    };

    for (final entry in variants.entries) {
      final temp = await Directory.systemTemp.createTemp(
        'atlas_mcp_autostart_${entry.key}_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(entry.value));
        await request.response.close();
      });
      try {
        await _writeTestPolicy(temp);
        final configFile = File(
          p.join(temp.path, '.local', 'atlas_mcp_connector_autostart.json'),
        );
        await configFile.writeAsString(
          jsonEncode({
            'enabled': true,
            'host': '127.0.0.1',
            'port': server.port,
            'authMode': 'static',
            'tunnelEnabled': false,
          }),
        );
        final service = McpConnectorAutostartService(
          repoRoot: temp,
          configFile: configFile,
          logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
        );

        final result = await service.startIfConfigured();

        expect(result.enabled, isFalse, reason: entry.key);
        expect(result.gatewayStarted, isFalse, reason: entry.key);
      } finally {
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    }
  });

  test('refuses introspection authority that also advertises JWKS', () async {
    final temp = await Directory.systemTemp.createTemp(
      'atlas_mcp_autostart_oauth_authority_',
    );
    addTearDown(() => temp.delete(recursive: true));
    await _writeTestPolicy(temp);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/.well-known/project-atlas-mcp') {
        request.response.write(
          jsonEncode(
            _healthyMetadata(
              policyMatches: true,
              auth: {'type': 'oauth2', 'mode': 'oauth', 'scope': 'atlas.read'},
            ),
          ),
        );
      } else {
        request.response.write(
          jsonEncode({
            'resource': 'https://atlas.example.test',
            'authorization_servers': ['https://auth.example.test'],
            'scopes_supported': ['atlas.read'],
            'introspection_endpoint': 'https://auth.example.test/introspect',
            'jwks_uri': 'https://unexpected.example.test/jwks.json',
          }),
        );
      }
      await request.response.close();
    });
    final configFile = File(
      p.join(temp.path, '.local', 'atlas_mcp_connector_autostart.json'),
    );
    await configFile.writeAsString(
      jsonEncode({
        'enabled': true,
        'host': '127.0.0.1',
        'port': server.port,
        'authMode': 'oauth',
        'resourceUrl': 'https://atlas.example.test',
        'authorizationServers': ['https://auth.example.test'],
        'introspectionUrl': 'https://auth.example.test/introspect',
        'tunnelEnabled': false,
      }),
    );
    final service = McpConnectorAutostartService(
      repoRoot: temp,
      configFile: configFile,
      logFile: File(p.join(temp.path, '.local', 'runs', 'autostart.log')),
    );

    final result = await service.startIfConfigured();

    expect(result.enabled, isFalse);
    expect(result.gatewayStarted, isFalse);
    expect(result.message, contains('current-policy projection boundary'));
  });
}

const _testRemoteTools = <String>[
  'list_projects',
  'get_project_status',
  'atlas.workload_snapshot',
  'atlas.project_planning_context',
];

Future<File> _writeTestPolicy(Directory temp) async {
  final file = File(
    p.join(temp.path, '.local', 'atlas_mcp_remote_disclosure.json'),
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'schema': 'project_atlas.remote_disclosure_policy.v1',
      'projects': <Object?>[],
    }),
  );
  return file;
}

Map<String, Object?> _healthyMetadata({
  required bool policyMatches,
  List<String> allowedTools = _testRemoteTools,
  Map<String, Object?> auth = const {'type': 'bearer', 'mode': 'static-dev'},
}) => {
  'name': 'Project Atlas MCP Gateway',
  'profile': 'remote_readonly',
  'projectionSchema': 'project_atlas.remote_projection.v1',
  'denyByDefault': true,
  'disclosurePolicyLoaded': true,
  'disclosurePolicyMatches': policyMatches,
  'allowedTools': allowedTools,
  'auth': auth,
};
