import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_atlas/services/mcp_disclosure_preview_service.dart';

void main() {
  test(
    'builds an alias-only preview from the exact hardened boundary',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final policyDigest = sha256.convert(fixture.policyBytes).toString();
      final calls = <Uri>[];

      final preview = await McpDisclosurePreviewService(
        repoRoot: fixture.root,
        configFile: fixture.configFile,
        localProjectIdsReader: () async => const {
          _Fixture.localId,
          'local-hidden-project-id-one',
          'local-hidden-project-id-two',
        },
        jsonReader: (uri, headers) async {
          calls.add(uri);
          if (uri.path == '/.well-known/project-atlas-mcp') {
            expect(headers['X-Project-Atlas-Policy-Digest'], policyDigest);
            return _gatewayMetadata();
          }
          return _oauthMetadata();
        },
      ).inspect();

      expect(preview.configState, 'valid');
      expect(preview.policyState, 'valid');
      expect(preview.gatewayState, 'metadata_matched');
      expect(preview.activeBinaryState, 'unverified');
      expect(preview.overallState, 'unverified');
      expect(preview.exactToolBoundary, isTrue);
      expect(preview.policyMatches, isTrue);
      expect(preview.oauthAuthorityMatches, isTrue);
      expect(preview.contracts.map((item) => item.tool), mcpRemoteTools);
      expect(preview.approvedProjects.single.alias, 'project-atlas');
      expect(preview.approvedProjects.single.label, 'Project Atlas');
      expect(preview.policyMode, 'deny_by_default');
      expect(preview.inventoryState, 'readable');
      expect(preview.registeredProjects, 3);
      expect(preview.policyApprovedProjects, 1);
      expect(preview.remotelyVisibleProjects, 1);
      expect(preview.notAllowlistedProjects, 2);
      expect(preview.unresolvedOrRemoteIneligibleEntries, 0);
      expect(preview.recentAuditEvents.single.outcome, 'ok');
      expect(calls, hasLength(2));

      final serialized = jsonEncode(preview.toJson());
      for (final forbidden in [
        _Fixture.localId,
        'local-hidden-project-id-one',
        'local-hidden-project-id-two',
        _Fixture.secretPath,
        'https://tenant-sentinel.example/',
        'https://resource-sentinel.example/mcp',
        policyDigest,
        'correlation-sentinel',
        'arguments-sentinel',
        'payload-sentinel',
      ]) {
        expect(serialized, isNot(contains(forbidden)));
      }
      expect(serialized, contains(policyDigest.substring(0, 12)));
    },
  );

  test(
    'reports unresolved policy entries without exposing local IDs',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      final preview = await McpDisclosurePreviewService(
        repoRoot: fixture.root,
        configFile: fixture.configFile,
        localProjectIdsReader: () async => const {
          'registered-private-project-id',
        },
        jsonReader: (uri, headers) async =>
            uri.path.contains('oauth') ? _oauthMetadata() : _gatewayMetadata(),
      ).inspect();

      expect(preview.registeredProjects, 1);
      expect(preview.policyApprovedProjects, 1);
      expect(preview.remotelyVisibleProjects, 0);
      expect(preview.notAllowlistedProjects, 1);
      expect(preview.unresolvedOrRemoteIneligibleEntries, 1);
      final serialized = jsonEncode(preview.toJson());
      expect(serialized, isNot(contains(_Fixture.localId)));
      expect(serialized, isNot(contains('registered-private-project-id')));
    },
  );

  test('marks an unreadable local inventory for operator attention', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    final preview = await McpDisclosurePreviewService(
      repoRoot: fixture.root,
      configFile: fixture.configFile,
      localProjectIdsReader: () => throw StateError('database unavailable'),
      jsonReader: (uri, headers) async =>
          uri.path.contains('oauth') ? _oauthMetadata() : _gatewayMetadata(),
    ).inspect();

    expect(preview.overallState, 'attention');
    expect(preview.inventoryState, 'unreadable');
    expect(preview.policyApprovedProjects, 1);
  });

  test('rejects a non-loopback config without issuing a request', () async {
    final fixture = await _Fixture.create(host: 'attacker.example');
    addTearDown(fixture.dispose);
    var calls = 0;

    final preview = await McpDisclosurePreviewService(
      repoRoot: fixture.root,
      configFile: fixture.configFile,
      jsonReader: (uri, headers) async {
        calls += 1;
        return null;
      },
    ).inspect();

    expect(preview.overallState, 'attention');
    expect(preview.configState, 'invalid');
    expect(preview.policyState, 'not_checked');
    expect(calls, 0);
  });

  test('rejects a policy path outside the repo local directory', () async {
    final outside = await Directory.systemTemp.createTemp(
      'atlas_preview_outside_',
    );
    addTearDown(() => outside.delete(recursive: true));
    final outsideLocal = Directory(p.join(outside.path, '.local'))
      ..createSync();
    final outsidePolicy =
        File(p.join(outsideLocal.path, 'atlas_mcp_remote_disclosure.json'))
          ..writeAsStringSync(
            jsonEncode({
              'schema': 'project_atlas.remote_disclosure_policy.v1',
              'projects': [
                {
                  'projectId': _Fixture.localId,
                  'alias': 'outside-repo',
                  'label': 'Outside Repo',
                },
              ],
            }),
          );
    final fixture = await _Fixture.create(
      disclosurePolicyPath: outsidePolicy.path,
    );
    addTearDown(fixture.dispose);
    var calls = 0;

    final preview = await McpDisclosurePreviewService(
      repoRoot: fixture.root,
      configFile: fixture.configFile,
      jsonReader: (uri, headers) async {
        calls += 1;
        return null;
      },
    ).inspect();

    expect(preview.overallState, 'attention');
    expect(preview.configState, 'valid');
    expect(preview.policyState, 'invalid_location');
    expect(preview.approvedProjects, isEmpty);
    expect(calls, 0);
  });

  test(
    'drops locally injected audit fields and reports a partial audit',
    () async {
      final fixture = await _Fixture.create(invalidAudit: true);
      addTearDown(fixture.dispose);

      final preview = await McpDisclosurePreviewService(
        repoRoot: fixture.root,
        configFile: fixture.configFile,
        jsonReader: (uri, headers) async =>
            uri.path.contains('oauth') ? _oauthMetadata() : _gatewayMetadata(),
      ).inspect();

      expect(preview.auditState, 'partial');
      expect(preview.malformedAuditEvents, 1);
      expect(preview.recentAuditEvents, isEmpty);
      expect(jsonEncode(preview.toJson()), isNot(contains('payload-sentinel')));
    },
  );

  test('missing and disabled configs remain safely off', () async {
    final root = await Directory.systemTemp.createTemp(
      'atlas_preview_missing_',
    );
    addTearDown(() => root.delete(recursive: true));
    final missing = await McpDisclosurePreviewService(repoRoot: root).inspect();
    expect(missing.overallState, 'off');
    expect(missing.configState, 'missing');

    final fixture = await _Fixture.create(enabled: false);
    addTearDown(fixture.dispose);
    final disabled = await McpDisclosurePreviewService(
      repoRoot: fixture.root,
      configFile: fixture.configFile,
    ).inspect();
    expect(disabled.overallState, 'off');
    expect(disabled.configState, 'disabled');
  });

  test(
    'oversized config fails closed before policy or network reads',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'atlas_preview_large_',
      );
      addTearDown(() => root.delete(recursive: true));
      final local = Directory(p.join(root.path, '.local'))..createSync();
      final config = File(
        p.join(local.path, 'atlas_mcp_connector_autostart.json'),
      )..writeAsStringSync(List.filled(64 * 1024 + 1, 'x').join());
      var calls = 0;

      final preview = await McpDisclosurePreviewService(
        repoRoot: root,
        configFile: config,
        jsonReader: (uri, headers) async {
          calls += 1;
          return null;
        },
      ).inspect();

      expect(preview.overallState, 'attention');
      expect(preview.configState, 'too_large_or_unreadable');
      expect(calls, 0);
    },
  );
}

Map<String, Object?> _gatewayMetadata() => {
  'name': 'Project Atlas MCP Gateway',
  'transport': 'streamable-http',
  'mcpEndpoint': '/mcp',
  'auth': {'type': 'oauth2', 'mode': 'oauth', 'scope': 'atlas.read'},
  'profile': 'remote_readonly',
  'projectionSchema': 'project_atlas.remote_projection.v1',
  'denyByDefault': true,
  'disclosurePolicyLoaded': true,
  'disclosurePolicyMatches': true,
  'allowedTools': mcpRemoteTools,
};

Map<String, Object?> _oauthMetadata() => {
  'resource': 'https://resource-sentinel.example/mcp',
  'authorization_servers': ['https://tenant-sentinel.example/'],
  'scopes_supported': ['atlas.read'],
  'jwks_uri': 'https://tenant-sentinel.example/.well-known/jwks.json',
};

class _Fixture {
  static const localId = 'local-private-project-id-sentinel';
  static const secretPath = r'C:\private-sentinel\project_atlas.exe';

  final Directory root;
  final File configFile;
  final List<int> policyBytes;

  const _Fixture({
    required this.root,
    required this.configFile,
    required this.policyBytes,
  });

  static Future<_Fixture> create({
    bool enabled = true,
    String host = '127.0.0.1',
    bool invalidAudit = false,
    String? disclosurePolicyPath,
  }) async {
    final root = await Directory.systemTemp.createTemp('atlas_preview_');
    final local = Directory(p.join(root.path, '.local'))..createSync();
    final runs = Directory(p.join(local.path, 'runs'))..createSync();
    final policy = {
      'schema': 'project_atlas.remote_disclosure_policy.v1',
      'projects': [
        {
          'projectId': localId,
          'alias': 'project-atlas',
          'label': 'Project Atlas',
        },
      ],
    };
    final policyBytes = utf8.encode(jsonEncode(policy));
    final policyFile = File(
      p.join(local.path, 'atlas_mcp_remote_disclosure.json'),
    )..writeAsBytesSync(policyBytes);
    final configFile =
        File(
          p.join(local.path, 'atlas_mcp_connector_autostart.json'),
        )..writeAsStringSync(
          jsonEncode({
            'enabled': enabled,
            'pythonPath': 'python',
            'gatewayScriptPath': r'C:\private-sentinel\atlas_mcp_gateway.py',
            'projectAtlasExePath': secretPath,
            'disclosurePolicyPath': disclosurePolicyPath ?? policyFile.path,
            'host': host,
            'port': 4874,
            'authMode': 'oauth',
            'resourceUrl': 'https://resource-sentinel.example/mcp',
            'authorizationServers': ['https://tenant-sentinel.example/'],
            'scope': 'atlas.read',
            'jwksUrl': 'https://tenant-sentinel.example/.well-known/jwks.json',
            'allowedOrigins': ['https://chatgpt.com'],
            'tunnelEnabled': true,
            'tunnelClientPath': r'C:\private-sentinel\tunnel.exe',
            'tunnelProfile': 'project-atlas',
            'tunnelProfileDir': r'C:\private-sentinel\profiles',
          }),
        );
    final digest = sha256.convert(policyBytes).toString();
    final audit = {
      'ts': '2026-07-10T12:00:00.000Z',
      'correlationId': '123e4567-e89b-42d3-a456-426614174000',
      'tool': 'list_projects',
      'projectAlias': 'project-atlas',
      'decision': 'allowed',
      'projectionSchema': 'project_atlas.remote_projection.v1',
      'policyDigest': digest,
      'items': 1,
      'responseBytes': 512,
      'durationMs': 8,
      'outcome': 'ok',
      if (invalidAudit) 'payload': 'payload-sentinel',
    };
    File(
      p.join(runs.path, 'atlas-mcp-disclosure-audit.jsonl'),
    ).writeAsStringSync('${jsonEncode(audit)}\n');
    return _Fixture(
      root: root,
      configFile: configFile,
      policyBytes: policyBytes,
    );
  }

  Future<void> dispose() => root.delete(recursive: true);
}
