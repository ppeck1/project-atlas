import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'mcp_connector_autostart_service.dart';

const mcpDisclosurePreviewSchema =
    'project_atlas.operator_disclosure_preview.v2';
const _policySchema = 'project_atlas.remote_disclosure_policy.v1';
const _projectionSchema = 'project_atlas.remote_projection.v1';
const _policyMode = 'deny_by_default';
const _policyDigestHeader = 'X-Project-Atlas-Policy-Digest';
const _maxConfigBytes = 64 * 1024;
const _maxPolicyBytes = 64 * 1024;
const _maxAuditBytes = 1024 * 1024;
const _maxAuditLines = 500;
const _maxAuditLineBytes = 4 * 1024;
const _maxRecentEvents = 25;
const _maxHttpBytes = 32 * 1024;
const _maxProjects = 64;
const _maxDisplayNumber = 0x7fffffff;

const mcpRemoteTools = <String>[
  'list_projects',
  'get_project_status',
  'atlas.workload_snapshot',
  'atlas.project_planning_context',
];

const _knownAuditTools = <String>{
  ...mcpRemoteTools,
  'tools/list',
  'unrecognized',
};
const _knownAuditOutcomes = <String>{
  'ok',
  'tool_not_allowed',
  'invalid_params',
  'invalid_visibility_context',
  'invalid_upstream_shape',
  'invalid_upstream_json',
  'not_found',
  'response_too_large',
  'upstream_error',
  'local_identifier_exposed',
};

const _allowedConfigKeys = <String>{
  'enabled',
  'pythonPath',
  'gatewayScriptPath',
  'projectAtlasExePath',
  'disclosurePolicyPath',
  'host',
  'port',
  'authMode',
  'resourceUrl',
  'authorizationServers',
  'scope',
  'jwksUrl',
  'introspectionUrl',
  'allowedOrigins',
  'tunnelEnabled',
  'tunnelClientPath',
  'tunnelProfile',
  'tunnelProfileDir',
};

const _auditKeys = <String>{
  'ts',
  'correlationId',
  'tool',
  'projectAlias',
  'decision',
  'projectionSchema',
  'policyDigest',
  'items',
  'responseBytes',
  'durationMs',
  'outcome',
};

typedef McpPreviewJsonReader =
    Future<Map<String, Object?>?> Function(
      Uri uri,
      Map<String, String> headers,
    );

typedef McpLocalProjectIdsReader = Future<Set<String>> Function();

class McpDisclosureProject {
  final String alias;
  final String label;

  const McpDisclosureProject({required this.alias, required this.label});

  Map<String, Object?> toJson() => {'alias': alias, 'label': label};
}

class McpDisclosureAuditEvent {
  final DateTime timestamp;
  final String tool;
  final String? projectAlias;
  final String decision;
  final String outcome;
  final int items;
  final int responseBytes;
  final int durationMs;

  const McpDisclosureAuditEvent({
    required this.timestamp,
    required this.tool,
    required this.projectAlias,
    required this.decision,
    required this.outcome,
    required this.items,
    required this.responseBytes,
    required this.durationMs,
  });

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'tool': tool,
    if (projectAlias != null) 'projectAlias': projectAlias,
    'decision': decision,
    'outcome': outcome,
    'items': items,
    'responseBytes': responseBytes,
    'durationMs': durationMs,
  };
}

class McpDisclosureContract {
  final String tool;
  final List<String> disclosedFields;
  final Map<String, Object?> sample;

  const McpDisclosureContract({
    required this.tool,
    required this.disclosedFields,
    required this.sample,
  });

  Map<String, Object?> toJson() => {
    'tool': tool,
    'disclosedFields': disclosedFields,
    'sample': sample,
  };
}

class McpDisclosurePreview {
  final String overallState;
  final String configState;
  final String policyState;
  final String policySchema;
  final String? policyFingerprint;
  final String policyMode;
  final List<McpDisclosureProject> approvedProjects;
  final String inventoryState;
  final int registeredProjects;
  final int policyApprovedProjects;
  final int remotelyVisibleProjects;
  final int notAllowlistedProjects;
  final int unresolvedOrRemoteIneligibleEntries;
  final String gatewayState;
  final String activeBinaryState;
  final String authMode;
  final String verifierMode;
  final String scope;
  final int issuerCount;
  final bool tunnelConfigured;
  final bool exactToolBoundary;
  final bool policyMatches;
  final bool scopeMatches;
  final bool oauthAuthorityMatches;
  final String auditState;
  final int malformedAuditEvents;
  final bool auditTruncated;
  final List<McpDisclosureAuditEvent> recentAuditEvents;
  final List<McpDisclosureContract> contracts;

  const McpDisclosurePreview({
    required this.overallState,
    required this.configState,
    required this.policyState,
    required this.policySchema,
    required this.policyFingerprint,
    required this.policyMode,
    required this.approvedProjects,
    required this.inventoryState,
    required this.registeredProjects,
    required this.policyApprovedProjects,
    required this.remotelyVisibleProjects,
    required this.notAllowlistedProjects,
    required this.unresolvedOrRemoteIneligibleEntries,
    required this.gatewayState,
    required this.activeBinaryState,
    required this.authMode,
    required this.verifierMode,
    required this.scope,
    required this.issuerCount,
    required this.tunnelConfigured,
    required this.exactToolBoundary,
    required this.policyMatches,
    required this.scopeMatches,
    required this.oauthAuthorityMatches,
    required this.auditState,
    required this.malformedAuditEvents,
    required this.auditTruncated,
    required this.recentAuditEvents,
    required this.contracts,
  });

  Map<String, Object?> toJson() => {
    'schema': mcpDisclosurePreviewSchema,
    'overallState': overallState,
    'configState': configState,
    'policyState': policyState,
    'policySchema': policySchema,
    if (policyFingerprint != null) 'policyFingerprint': policyFingerprint,
    'policyMode': policyMode,
    'inventoryState': inventoryState,
    'registeredProjects': registeredProjects,
    'policyApprovedProjects': policyApprovedProjects,
    'remotelyVisibleProjects': remotelyVisibleProjects,
    'notAllowlistedProjects': notAllowlistedProjects,
    'unresolvedOrRemoteIneligibleEntries': unresolvedOrRemoteIneligibleEntries,
    'approvedProjects': approvedProjects.map((item) => item.toJson()).toList(),
    'gateway': {
      'state': gatewayState,
      'activeBinaryState': activeBinaryState,
      'authMode': authMode,
      'verifierMode': verifierMode,
      'scope': scope,
      'issuerCount': issuerCount,
      'tunnelConfigured': tunnelConfigured,
      'exactToolBoundary': exactToolBoundary,
      'policyMatches': policyMatches,
      'scopeMatches': scopeMatches,
      'oauthAuthorityMatches': oauthAuthorityMatches,
    },
    'audit': {
      'state': auditState,
      'malformedEvents': malformedAuditEvents,
      'truncated': auditTruncated,
      'recentEvents': recentAuditEvents.map((item) => item.toJson()).toList(),
    },
    'contracts': contracts.map((item) => item.toJson()).toList(),
  };

  factory McpDisclosurePreview.unavailable({
    required String overallState,
    required String configState,
    String policyState = 'not_checked',
  }) {
    return McpDisclosurePreview(
      overallState: overallState,
      configState: configState,
      policyState: policyState,
      policySchema: _policySchema,
      policyFingerprint: null,
      policyMode: _policyMode,
      approvedProjects: const [],
      inventoryState: 'not_checked',
      registeredProjects: 0,
      policyApprovedProjects: 0,
      remotelyVisibleProjects: 0,
      notAllowlistedProjects: 0,
      unresolvedOrRemoteIneligibleEntries: 0,
      gatewayState: 'not_checked',
      activeBinaryState: 'not_checked',
      authMode: 'unavailable',
      verifierMode: 'unavailable',
      scope: 'unavailable',
      issuerCount: 0,
      tunnelConfigured: false,
      exactToolBoundary: false,
      policyMatches: false,
      scopeMatches: false,
      oauthAuthorityMatches: false,
      auditState: 'not_checked',
      malformedAuditEvents: 0,
      auditTruncated: false,
      recentAuditEvents: const [],
      contracts: _contracts('approved-alias', 'Approved project'),
    );
  }
}

class _PolicySnapshot {
  final String digest;
  final List<McpDisclosureProject> projects;
  final Set<String> localProjectIds;

  const _PolicySnapshot({
    required this.digest,
    required this.projects,
    required this.localProjectIds,
  });
}

class _InventorySnapshot {
  final String state;
  final int registeredProjects;
  final int policyApprovedProjects;
  final int remotelyVisibleProjects;
  final int notAllowlistedProjects;
  final int unresolvedOrRemoteIneligibleEntries;

  const _InventorySnapshot({
    required this.state,
    required this.registeredProjects,
    required this.policyApprovedProjects,
    required this.remotelyVisibleProjects,
    required this.notAllowlistedProjects,
    required this.unresolvedOrRemoteIneligibleEntries,
  });
}

class _AuditSnapshot {
  final String state;
  final int malformed;
  final bool truncated;
  final List<McpDisclosureAuditEvent> events;

  const _AuditSnapshot({
    required this.state,
    required this.malformed,
    required this.truncated,
    required this.events,
  });
}

class _GatewaySnapshot {
  final String state;
  final bool exactTools;
  final bool policyMatches;
  final bool scopeMatches;
  final bool oauthAuthorityMatches;

  const _GatewaySnapshot({
    required this.state,
    required this.exactTools,
    required this.policyMatches,
    required this.scopeMatches,
    required this.oauthAuthorityMatches,
  });
}

class McpDisclosurePreviewService {
  final Directory repoRoot;
  final File configFile;
  final McpPreviewJsonReader _jsonReader;
  final McpLocalProjectIdsReader? _localProjectIdsReader;

  McpDisclosurePreviewService({
    Directory? repoRoot,
    File? configFile,
    McpPreviewJsonReader? jsonReader,
    McpLocalProjectIdsReader? localProjectIdsReader,
  }) : repoRoot = repoRoot ?? Directory.current,
       configFile =
           configFile ??
           File(
             p.join(
               (repoRoot ?? Directory.current).path,
               '.local',
               'atlas_mcp_connector_autostart.json',
             ),
           ),
       _jsonReader = jsonReader ?? _readJson,
       _localProjectIdsReader = localProjectIdsReader;

  Future<McpDisclosurePreview> inspect() async {
    if (!await configFile.exists()) {
      return McpDisclosurePreview.unavailable(
        overallState: 'off',
        configState: 'missing',
      );
    }

    final configBytes = await _boundedBytes(configFile, _maxConfigBytes);
    if (configBytes == null) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'too_large_or_unreadable',
      );
    }

    final configJson = _decodeObject(configBytes);
    if (configJson == null || !_validConfigShape(configJson)) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'invalid',
      );
    }
    final config = McpConnectorAutostartConfig.fromJson(configJson);
    if (!config.enabled) {
      return McpDisclosurePreview.unavailable(
        overallState: 'off',
        configState: 'disabled',
      );
    }
    if (!_validEnabledConfig(config)) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'invalid',
      );
    }

    final policyFile = File(_resolve(config.disclosurePolicyPath));
    if (!_isExpectedPolicyPath(policyFile.path)) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'valid',
        policyState: 'invalid_location',
      );
    }
    if (!await policyFile.exists()) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'valid',
        policyState: 'missing',
      );
    }
    final policyBytes = await _boundedBytes(policyFile, _maxPolicyBytes);
    if (policyBytes == null) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'valid',
        policyState: 'too_large_or_unreadable',
      );
    }
    final policy = _parsePolicy(policyBytes);
    if (policy == null) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'valid',
        policyState: 'invalid',
      );
    }

    final inventory = await _inspectInventory(policy);
    final gateway = await _inspectGateway(config, policy.digest);
    final auditFile = File(
      p.join(
        policyFile.parent.path,
        'runs',
        'atlas-mcp-disclosure-audit.jsonl',
      ),
    );
    final audit = await _readAudit(
      auditFile,
      policy.digest,
      policy.projects.map((item) => item.alias).toSet(),
    );
    final alias = policy.projects.isEmpty
        ? 'approved-alias'
        : policy.projects.first.alias;
    final label = policy.projects.isEmpty
        ? 'Approved project'
        : policy.projects.first.label;
    final verifierMode = config.jwksUrl != null ? 'jwks' : 'introspection';
    final auditNeedsAttention =
        audit.state == 'too_large_or_unreadable' ||
        audit.state == 'unreadable' ||
        audit.malformed > 0;
    final overallState =
        gateway.state == 'identity_mismatch' ||
            auditNeedsAttention ||
            inventory.state == 'unreadable'
        ? 'attention'
        : 'unverified';

    return McpDisclosurePreview(
      overallState: overallState,
      configState: 'valid',
      policyState: 'valid',
      policySchema: _policySchema,
      policyFingerprint: policy.digest.substring(0, 12),
      policyMode: _policyMode,
      approvedProjects: policy.projects,
      inventoryState: inventory.state,
      registeredProjects: inventory.registeredProjects,
      policyApprovedProjects: inventory.policyApprovedProjects,
      remotelyVisibleProjects: inventory.remotelyVisibleProjects,
      notAllowlistedProjects: inventory.notAllowlistedProjects,
      unresolvedOrRemoteIneligibleEntries:
          inventory.unresolvedOrRemoteIneligibleEntries,
      gatewayState: gateway.state,
      activeBinaryState: 'unverified',
      authMode: config.authMode,
      verifierMode: verifierMode,
      scope: config.scope,
      issuerCount: config.authorizationServers.length,
      tunnelConfigured: config.tunnelEnabled,
      exactToolBoundary: gateway.exactTools,
      policyMatches: gateway.policyMatches,
      scopeMatches: gateway.scopeMatches,
      oauthAuthorityMatches: gateway.oauthAuthorityMatches,
      auditState: audit.state,
      malformedAuditEvents: audit.malformed,
      auditTruncated: audit.truncated,
      recentAuditEvents: audit.events,
      contracts: _contracts(alias, label),
    );
  }

  Future<_InventorySnapshot> _inspectInventory(_PolicySnapshot policy) async {
    final reader = _localProjectIdsReader;
    if (reader == null) {
      return _InventorySnapshot(
        state: 'not_checked',
        registeredProjects: 0,
        policyApprovedProjects: policy.localProjectIds.length,
        remotelyVisibleProjects: 0,
        notAllowlistedProjects: 0,
        unresolvedOrRemoteIneligibleEntries: 0,
      );
    }
    try {
      final registeredIds = Set<String>.unmodifiable(await reader());
      final remotelyVisible = policy.localProjectIds
          .where(registeredIds.contains)
          .length;
      return _InventorySnapshot(
        state: 'readable',
        registeredProjects: registeredIds.length,
        policyApprovedProjects: policy.localProjectIds.length,
        remotelyVisibleProjects: remotelyVisible,
        notAllowlistedProjects: registeredIds.length - remotelyVisible,
        unresolvedOrRemoteIneligibleEntries:
            policy.localProjectIds.length - remotelyVisible,
      );
    } catch (_) {
      return _InventorySnapshot(
        state: 'unreadable',
        registeredProjects: 0,
        policyApprovedProjects: policy.localProjectIds.length,
        remotelyVisibleProjects: 0,
        notAllowlistedProjects: 0,
        unresolvedOrRemoteIneligibleEntries: 0,
      );
    }
  }

  Future<_GatewaySnapshot> _inspectGateway(
    McpConnectorAutostartConfig config,
    String policyDigest,
  ) async {
    if (!_isLoopbackHost(config.host) ||
        config.port < 1 ||
        config.port > 65535) {
      return const _GatewaySnapshot(
        state: 'invalid_endpoint',
        exactTools: false,
        policyMatches: false,
        scopeMatches: false,
        oauthAuthorityMatches: false,
      );
    }
    final metadataUri = _loopbackUri(
      config.host,
      config.port,
      '/.well-known/project-atlas-mcp',
    );
    final oauthUri = _loopbackUri(
      config.host,
      config.port,
      '/.well-known/oauth-protected-resource',
    );
    if (metadataUri == null || oauthUri == null) {
      return const _GatewaySnapshot(
        state: 'invalid_endpoint',
        exactTools: false,
        policyMatches: false,
        scopeMatches: false,
        oauthAuthorityMatches: false,
      );
    }

    final metadata = await _jsonReader(metadataUri, {
      _policyDigestHeader: policyDigest,
    });
    if (metadata == null) {
      return const _GatewaySnapshot(
        state: 'offline',
        exactTools: false,
        policyMatches: false,
        scopeMatches: false,
        oauthAuthorityMatches: false,
      );
    }
    final tools = metadata['allowedTools'];
    final exactTools =
        tools is List &&
        tools.length == mcpRemoteTools.length &&
        tools.every((item) => item is String) &&
        tools.cast<String>().toSet().containsAll(mcpRemoteTools);
    final auth = metadata['auth'];
    final authMatches =
        auth is Map &&
        auth['type'] == 'oauth2' &&
        auth['mode'] == 'oauth' &&
        auth['scope'] == config.scope;
    final scopeMatches = authMatches && config.scope == 'atlas.read';
    final policyMatches = metadata['disclosurePolicyMatches'] == true;
    final baseMatches =
        metadata['name'] == 'Project Atlas MCP Gateway' &&
        metadata['profile'] == 'remote_readonly' &&
        metadata['projectionSchema'] == _projectionSchema &&
        metadata['denyByDefault'] == true &&
        metadata['disclosurePolicyLoaded'] == true;
    var oauthAuthorityMatches = false;
    if (baseMatches && exactTools && authMatches) {
      final oauth = await _jsonReader(oauthUri, const {});
      oauthAuthorityMatches = oauth != null && _oauthMatches(oauth, config);
    }
    final trusted =
        baseMatches &&
        exactTools &&
        policyMatches &&
        scopeMatches &&
        oauthAuthorityMatches;
    return _GatewaySnapshot(
      state: trusted ? 'metadata_matched' : 'identity_mismatch',
      exactTools: exactTools,
      policyMatches: policyMatches,
      scopeMatches: scopeMatches,
      oauthAuthorityMatches: oauthAuthorityMatches,
    );
  }

  static bool _oauthMatches(
    Map<String, Object?> metadata,
    McpConnectorAutostartConfig config,
  ) {
    if (_normalizeUrl(metadata['resource']) !=
        _normalizeUrl(config.resourceUrl)) {
      return false;
    }
    final servers = _stringSet(
      metadata['authorization_servers'],
    )?.map(_normalizeUrl).toSet();
    final expectedServers = config.authorizationServers
        .map(_normalizeUrl)
        .toSet();
    if (servers == null ||
        servers.length != expectedServers.length ||
        !servers.containsAll(expectedServers)) {
      return false;
    }
    final scopes = _stringSet(metadata['scopes_supported']);
    if (scopes == null ||
        scopes.length != 1 ||
        !scopes.contains(config.scope)) {
      return false;
    }
    if (config.jwksUrl != null) {
      return _normalizeUrl(metadata['jwks_uri']) ==
              _normalizeUrl(config.jwksUrl) &&
          !metadata.containsKey('introspection_endpoint');
    }
    return _normalizeUrl(metadata['introspection_endpoint']) ==
            _normalizeUrl(config.introspectionUrl) &&
        !metadata.containsKey('jwks_uri');
  }

  Future<_AuditSnapshot> _readAudit(
    File file,
    String policyDigest,
    Set<String> approvedAliases,
  ) async {
    if (!await file.exists()) {
      return const _AuditSnapshot(
        state: 'missing',
        malformed: 0,
        truncated: false,
        events: [],
      );
    }
    int length;
    try {
      length = await file.length();
    } catch (_) {
      return const _AuditSnapshot(
        state: 'too_large_or_unreadable',
        malformed: 0,
        truncated: true,
        events: [],
      );
    }
    if (length == 0) {
      return const _AuditSnapshot(
        state: 'no_events',
        malformed: 0,
        truncated: false,
        events: [],
      );
    }
    final bytes = await _boundedBytes(file, _maxAuditBytes);
    if (bytes == null) {
      return const _AuditSnapshot(
        state: 'too_large_or_unreadable',
        malformed: 0,
        truncated: true,
        events: [],
      );
    }
    String raw;
    try {
      raw = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      return const _AuditSnapshot(
        state: 'unreadable',
        malformed: 1,
        truncated: false,
        events: [],
      );
    }
    final partial = raw.isNotEmpty && !raw.endsWith('\n');
    final allLines = const LineSplitter().convert(raw);
    final truncated = allLines.length > _maxAuditLines;
    final lines = allLines.length > _maxAuditLines
        ? allLines.sublist(allLines.length - _maxAuditLines)
        : allLines;
    var malformed = 0;
    final events = <McpDisclosureAuditEvent>[];
    for (var index = 0; index < lines.length; index += 1) {
      if (partial && index == lines.length - 1) continue;
      final line = lines[index];
      if (utf8.encode(line).length > _maxAuditLineBytes) {
        malformed += 1;
        continue;
      }
      final event = _parseAuditEvent(line, policyDigest, approvedAliases);
      if (event == null) {
        malformed += 1;
      } else {
        events.add(event);
      }
    }
    final recent = events.length > _maxRecentEvents
        ? events.sublist(events.length - _maxRecentEvents)
        : events;
    return _AuditSnapshot(
      state: partial || malformed > 0 ? 'partial' : 'readable',
      malformed: malformed,
      truncated: truncated || partial,
      events: recent.reversed.toList(growable: false),
    );
  }

  static McpDisclosureAuditEvent? _parseAuditEvent(
    String line,
    String policyDigest,
    Set<String> approvedAliases,
  ) {
    Map<String, Object?>? row;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) row = decoded;
    } catch (_) {
      return null;
    }
    if (row == null || !_sameKeys(row.keys.toSet(), _auditKeys)) return null;
    final timestampText = row['ts'];
    final timestamp = timestampText is String
        ? DateTime.tryParse(timestampText)
        : null;
    final tool = row['tool'];
    final alias = row['projectAlias'];
    final decision = row['decision'];
    final outcome = row['outcome'];
    final correlationId = row['correlationId'];
    if (timestamp == null ||
        !timestamp.isUtc ||
        correlationId is! String ||
        !_uuidPattern.hasMatch(correlationId) ||
        tool is! String ||
        !_knownAuditTools.contains(tool) ||
        (alias != null &&
            (alias is! String || !approvedAliases.contains(alias))) ||
        decision is! String ||
        !const {'allowed', 'denied'}.contains(decision) ||
        outcome is! String ||
        !_knownAuditOutcomes.contains(outcome) ||
        row['projectionSchema'] != _projectionSchema ||
        row['policyDigest'] != policyDigest) {
      return null;
    }
    final items = _safeAuditNumber(row['items']);
    final responseBytes = _safeAuditNumber(row['responseBytes']);
    final durationMs = _safeAuditNumber(row['durationMs']);
    if (items == null || responseBytes == null || durationMs == null)
      return null;
    return McpDisclosureAuditEvent(
      timestamp: timestamp,
      tool: tool,
      projectAlias: alias as String?,
      decision: decision,
      outcome: outcome,
      items: items,
      responseBytes: responseBytes,
      durationMs: durationMs,
    );
  }

  static int? _safeAuditNumber(Object? value) {
    if (value is! int || value < 0 || value > _maxDisplayNumber) return null;
    return value;
  }

  static _PolicySnapshot? _parsePolicy(List<int> bytes) {
    final decoded = _decodeObject(bytes);
    if (decoded == null ||
        !_sameKeys(decoded.keys.toSet(), const {'schema', 'projects'}) ||
        decoded['schema'] != _policySchema) {
      return null;
    }
    final rows = decoded['projects'];
    if (rows is! List || rows.length > _maxProjects) return null;
    final aliases = <String>{};
    final localIds = <String>{};
    final projects = <McpDisclosureProject>[];
    for (final rawRow in rows) {
      if (rawRow is! Map ||
          !rawRow.keys.every((key) => key is String) ||
          !rawRow.keys.cast<String>().toSet().containsAll(const {
            'projectId',
            'alias',
          }) ||
          !rawRow.keys.cast<String>().toSet().every(
            const {'projectId', 'alias', 'label'}.contains,
          )) {
        return null;
      }
      final localId = rawRow['projectId'];
      final alias = rawRow['alias'];
      final label = rawRow['label'] ?? alias;
      if (localId is! String ||
          localId.trim().length < 8 ||
          localId.length > 128 ||
          localId.codeUnits.any((unit) => unit < 32) ||
          alias is! String ||
          !_aliasPattern.hasMatch(alias) ||
          label is! String ||
          !_labelPattern.hasMatch(label) ||
          alias == localId ||
          label == localId ||
          !localIds.add(localId) ||
          !aliases.add(alias)) {
        return null;
      }
      projects.add(McpDisclosureProject(alias: alias, label: label));
    }
    return _PolicySnapshot(
      digest: sha256.convert(bytes).toString(),
      projects: List.unmodifiable(projects),
      localProjectIds: Set.unmodifiable(localIds),
    );
  }

  static bool _validConfigShape(Map<String, Object?> json) {
    if (!json.keys.every(_allowedConfigKeys.contains)) return false;
    for (final key in const {
      'pythonPath',
      'gatewayScriptPath',
      'projectAtlasExePath',
      'disclosurePolicyPath',
      'host',
      'authMode',
      'resourceUrl',
      'scope',
      'jwksUrl',
      'introspectionUrl',
      'tunnelClientPath',
      'tunnelProfile',
      'tunnelProfileDir',
    }) {
      if (json.containsKey(key) && json[key] is! String) return false;
    }
    for (final key in const {'authorizationServers', 'allowedOrigins'}) {
      final value = json[key];
      if (value != null &&
          (value is! List || value.any((item) => item is! String))) {
        return false;
      }
    }
    if (json.containsKey('enabled') && json['enabled'] is! bool) return false;
    if (json.containsKey('tunnelEnabled') && json['tunnelEnabled'] is! bool) {
      return false;
    }
    if (json.containsKey('port') && json['port'] is! int) return false;
    return true;
  }

  static bool _validEnabledConfig(McpConnectorAutostartConfig config) {
    if (!_isLoopbackHost(config.host) ||
        config.port < 1 ||
        config.port > 65535) {
      return false;
    }
    if (config.authMode != 'oauth' ||
        config.scope != 'atlas.read' ||
        config.resourceUrl == null ||
        config.authorizationServers.isEmpty ||
        (config.jwksUrl == null) == (config.introspectionUrl == null)) {
      return false;
    }
    return true;
  }

  bool _isExpectedPolicyPath(String path) {
    final normalized = p.normalize(path);
    final expected = p.normalize(
      p.join(repoRoot.path, '.local', 'atlas_mcp_remote_disclosure.json'),
    );
    return p.equals(normalized, expected);
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    return const {'127.0.0.1', 'localhost', '::1'}.contains(normalized);
  }

  static Uri? _loopbackUri(String host, int port, String path) {
    if (!_isLoopbackHost(host) || port < 1 || port > 65535) return null;
    final uri = Uri(scheme: 'http', host: host, port: port, path: path);
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
    return uri;
  }

  String _resolve(String value) {
    final normalized = value.replaceAll('/', p.separator);
    return p.isAbsolute(normalized)
        ? p.normalize(normalized)
        : p.normalize(p.join(repoRoot.path, normalized));
  }

  static Future<List<int>?> _boundedBytes(File file, int maximum) async {
    try {
      final length = await file.length();
      if (length < 1 || length > maximum) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _decodeObject(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static bool _sameKeys(Set<String> actual, Set<String> expected) {
    return actual.length == expected.length && actual.containsAll(expected);
  }

  static Set<String>? _stringSet(Object? value) {
    if (value is! List || value.any((item) => item is! String)) return null;
    return value.cast<String>().toSet();
  }

  static String _normalizeUrl(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  static Future<Map<String, Object?>?> _readJson(
    Uri uri,
    Map<String, String> headers,
  ) async {
    if (uri.scheme != 'http' ||
        !_isLoopbackHost(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const {
          '/.well-known/project-atlas-mcp',
          '/.well-known/oauth-protected-resource',
        }.contains(uri.path)) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.isRedirect ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 2))) {
        bytes.addAll(chunk);
        if (bytes.length > _maxHttpBytes) return null;
      }
      return _decodeObject(bytes);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

final _aliasPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final _labelPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._()\-]{0,79}$');
final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

List<McpDisclosureContract> _contracts(String alias, String label) {
  final project = <String, Object?>{
    'projectId': alias,
    'title': label,
    'status': 'active',
    'phase': 'build',
    'priority': 'normal',
    'workItems': {'active': 0, 'blocked': 0},
    'records': {'documents': 0, 'media': 0, 'risks': 0, 'decisions': 0},
    'freshness': {
      'status': 'unknown',
      'confidence': 'low',
      'staleReasons': <Object?>[],
      'attentionReasons': <Object?>[],
      'planningActionRequired': false,
    },
    'needsAttention': false,
  };
  final card = <String, Object?>{
    'projectId': alias,
    'projectTitle': label,
    'kind': 'work_item',
    'readiness': 'ready',
    'boardGroup': 'ready',
    'size': 'small',
    'risk': 'low_code',
    'suggestedActor': 'codex',
    'verificationNeeded': 'tests',
    'priority': 'normal',
    'status': 'next',
    'stale': false,
    'staleReasons': <Object?>[],
    'originKind': 'manual',
  };
  return [
    McpDisclosureContract(
      tool: 'list_projects',
      disclosedFields: const [
        'schema',
        'projects[].projectId (approved alias)',
        'projects[].title (approved label)',
        'projects[].status/phase/priority',
        'projects[].workItems/records/freshness/needsAttention',
        'page.offset/limit/returned/totalApproved/hasMore',
      ],
      sample: {
        'schema': _projectionSchema,
        'projects': [project],
        'page': {
          'offset': 0,
          'limit': 10,
          'returned': 1,
          'totalApproved': 1,
          'hasMore': false,
        },
      },
    ),
    McpDisclosureContract(
      tool: 'get_project_status',
      disclosedFields: const [
        'schema',
        'project.projectId (approved alias)',
        'project.title (approved label)',
        'project.status/phase/priority',
        'project.workItems/records/freshness/needsAttention',
      ],
      sample: {'schema': _projectionSchema, 'project': project},
    ),
    McpDisclosureContract(
      tool: 'atlas.workload_snapshot',
      disclosedFields: const [
        'schema/generatedAt/scope',
        'counts and returned caps',
        'executionCandidates[]',
        'planningCandidateItems[]',
        'reviewNeededItems[]',
        'bounded structured card classifications only',
      ],
      sample: {
        'schema': _projectionSchema,
        'generatedAt': 'redacted-timestamp',
        'scope': {'projectId': alias, 'title': label},
        'counts': {
          'total': 1,
          'ready': 1,
          'blocked': 0,
          'reviewNeeded': 0,
          'stale': 0,
          'importedChecklist': 0,
        },
        'executionCandidates': [card],
        'planningCandidateItems': <Object?>[],
        'reviewNeededItems': <Object?>[],
        'returned': {'execution': 1, 'planning': 0, 'review': 0},
        'truncated': false,
      },
    ),
    McpDisclosureContract(
      tool: 'atlas.project_planning_context',
      disclosedFields: const [
        'schema/generatedAt',
        'project approved identity and structured status',
        'workload counts and bounded structured cards',
        'safeConstraints',
        'verification requirements (no commands)',
        'integrityNotice',
      ],
      sample: {
        'schema': _projectionSchema,
        'generatedAt': 'redacted-timestamp',
        'project': project,
        'workload': {
          'counts': {'total': 0, 'ready': 0, 'blocked': 0},
          'executionCandidates': <Object?>[],
          'planningCandidateItems': <Object?>[],
          'reviewNeededItems': <Object?>[],
          'blockedItems': <Object?>[],
          'truncated': false,
        },
        'safeConstraints': {
          'readOnly': true,
          'commandsWithheld': true,
          'freeTextWithheld': true,
        },
        'verification': {'required': true},
        'integrityNotice':
            'Only operator-approved structured fields are shown.',
      },
    ),
  ];
}
