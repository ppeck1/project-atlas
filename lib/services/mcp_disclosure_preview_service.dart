import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'mcp_connector_autostart_service.dart';

const mcpDisclosurePreviewSchema =
    'project_atlas.operator_disclosure_preview.v2';
const _policySchemaV1 = 'project_atlas.remote_disclosure_policy.v1';
const _policySchemaV2 = 'project_atlas.remote_disclosure_policy.v2';
const _projectionSchema = 'project_atlas.remote_projection.v1';
const _inventorySchema = 'project_atlas.remote_project_inventory.v3';
const _statusSchema = 'project_atlas.remote_project_status.v2';
const _workloadSchema = 'project_atlas.remote_workload_snapshot.v2';
const _planningSchema = 'project_atlas.remote_planning_context.v2';
const _policyMode = 'deny_by_default';
const _policyDigestHeader = 'X-Project-Atlas-Policy-Digest';
const _maxConfigBytes = 64 * 1024;
const _maxPolicyBytes = 128 * 1024;
const _maxAuditBytes = 1024 * 1024;
const _maxAuditLines = 500;
const _maxAuditLineBytes = 4 * 1024;
const _maxRecentEvents = 25;
const _maxHttpBytes = 32 * 1024;
const _maxInventoryProjects = 256;
const _maxDetailProjects = 64;
const _inventoryPageSize = 64;
const _maxDisplayNumber = 0x7fffffff;
const _attentionProjectStatuses = <String>{
  'stale',
  'needs_update',
  'needs_review',
  'local_only',
  'public_mismatch',
  'blocked',
};
const _planningSignalReasons = <String>{
  'blocked_work_items',
  'high_priority_without_active_work',
  'capsule_errors',
  'project_status_stale',
  'project_status_needs_update',
  'project_status_needs_review',
  'project_status_local_only',
  'project_status_public_mismatch',
  'project_status_blocked',
};

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
typedef McpLocalProjectsReader = Future<List<McpLocalProjectRecord>> Function();

class McpLocalProjectRecord {
  final String localId;
  final String title;
  final String status;
  final String? phase;
  final String? priority;
  final String freshnessStatus;
  final int activeWorkItems;
  final int blockedWorkItems;
  final int blocksProgressWorkItems;
  final bool needsAttention;
  final List<String> staleReasons;
  final List<String> attentionReasons;

  const McpLocalProjectRecord({
    required this.localId,
    required this.title,
    required this.status,
    required this.phase,
    required this.priority,
    required this.freshnessStatus,
    required this.activeWorkItems,
    required this.blockedWorkItems,
    required this.blocksProgressWorkItems,
    required this.needsAttention,
    this.staleReasons = const [],
    this.attentionReasons = const [],
  });
}

class McpDisclosureProject {
  final String alias;
  final String label;
  final bool inventoryEnabled;
  final bool detailEnabled;

  const McpDisclosureProject({
    required this.alias,
    required this.label,
    this.inventoryEnabled = true,
    this.detailEnabled = true,
  });

  Map<String, Object?> toJson() => {
    'alias': alias,
    'label': label,
    'access': [if (inventoryEnabled) 'inventory', if (detailEnabled) 'detail'],
  };
}

class McpDisclosureCandidate {
  final String title;
  final String? proposedAlias;
  final String? unsafeReason;
  final String sourceTitleFingerprint;

  const McpDisclosureCandidate({
    required this.title,
    required this.proposedAlias,
    required this.unsafeReason,
    required this.sourceTitleFingerprint,
  });

  bool get requiresReview => unsafeReason != null || proposedAlias == null;

  String get displayTitle => requiresReview ? _visibleText(title) : title;
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
  final List<McpDisclosureCandidate> eligibleNotEnrolledProjects;
  final List<String> titleDriftAliases;
  final List<String> missingTitleFingerprintAliases;
  final String inventoryState;
  final int registeredProjects;
  final int policyApprovedProjects;
  final int remotelyVisibleProjects;
  final int notAllowlistedProjects;
  final int unresolvedOrRemoteIneligibleEntries;
  final int candidateInventoryProjects;
  final int candidateDetailProjects;
  final int inventoryPageCount;
  final int estimatedInventoryResponseBytes;
  final int aliasCollisionCount;
  final int unsafeCandidateLabels;
  final bool restartRequired;
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
    required this.eligibleNotEnrolledProjects,
    required this.titleDriftAliases,
    required this.missingTitleFingerprintAliases,
    required this.inventoryState,
    required this.registeredProjects,
    required this.policyApprovedProjects,
    required this.remotelyVisibleProjects,
    required this.notAllowlistedProjects,
    required this.unresolvedOrRemoteIneligibleEntries,
    required this.candidateInventoryProjects,
    required this.candidateDetailProjects,
    required this.inventoryPageCount,
    required this.estimatedInventoryResponseBytes,
    required this.aliasCollisionCount,
    required this.unsafeCandidateLabels,
    required this.restartRequired,
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

  List<McpDisclosureProject> get inventoryProjects => approvedProjects
      .where((project) => project.inventoryEnabled)
      .toList(growable: false);

  List<McpDisclosureProject> get detailProjects => approvedProjects
      .where((project) => project.detailEnabled)
      .toList(growable: false);

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
    'candidateInventoryProjects': candidateInventoryProjects,
    'candidateDetailProjects': candidateDetailProjects,
    'inventoryPageCount': inventoryPageCount,
    'estimatedInventoryResponseBytes': estimatedInventoryResponseBytes,
    'aliasCollisionCount': aliasCollisionCount,
    'unsafeCandidateLabels': unsafeCandidateLabels,
    'titleDriftAliases': titleDriftAliases,
    'missingTitleFingerprintAliases': missingTitleFingerprintAliases,
    'restartRequired': restartRequired,
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
      policySchema: _policySchemaV1,
      policyFingerprint: null,
      policyMode: _policyMode,
      approvedProjects: const [],
      eligibleNotEnrolledProjects: const [],
      titleDriftAliases: const [],
      missingTitleFingerprintAliases: const [],
      inventoryState: 'not_checked',
      registeredProjects: 0,
      policyApprovedProjects: 0,
      remotelyVisibleProjects: 0,
      notAllowlistedProjects: 0,
      unresolvedOrRemoteIneligibleEntries: 0,
      candidateInventoryProjects: 0,
      candidateDetailProjects: 0,
      inventoryPageCount: 0,
      estimatedInventoryResponseBytes: 0,
      aliasCollisionCount: 0,
      unsafeCandidateLabels: 0,
      restartRequired: false,
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
  final String schema;
  final String digest;
  final List<McpDisclosureProject> projects;
  final List<_PolicyEntry> entries;
  final Set<String> localProjectIds;

  const _PolicySnapshot({
    required this.schema,
    required this.digest,
    required this.projects,
    required this.entries,
    required this.localProjectIds,
  });
}

class _PolicyEntry {
  final String localId;
  final McpDisclosureProject project;
  final String? sourceTitleFingerprint;

  const _PolicyEntry({
    required this.localId,
    required this.project,
    required this.sourceTitleFingerprint,
  });
}

class _PolicyParseOutcome {
  final String state;
  final _PolicySnapshot? policy;

  const _PolicyParseOutcome(this.state, [this.policy]);
}

class _InventorySnapshot {
  final String state;
  final int registeredProjects;
  final int policyApprovedProjects;
  final int remotelyVisibleProjects;
  final int notAllowlistedProjects;
  final int unresolvedOrRemoteIneligibleEntries;
  final List<McpDisclosureCandidate> candidates;
  final List<String> titleDriftAliases;
  final List<String> missingTitleFingerprintAliases;
  final int candidateInventoryProjects;
  final int candidateDetailProjects;
  final int pageCount;
  final int estimatedResponseBytes;
  final int aliasCollisionCount;
  final int unsafeCandidateLabels;

  const _InventorySnapshot({
    required this.state,
    required this.registeredProjects,
    required this.policyApprovedProjects,
    required this.remotelyVisibleProjects,
    required this.notAllowlistedProjects,
    required this.unresolvedOrRemoteIneligibleEntries,
    required this.candidates,
    required this.titleDriftAliases,
    required this.missingTitleFingerprintAliases,
    required this.candidateInventoryProjects,
    required this.candidateDetailProjects,
    required this.pageCount,
    required this.estimatedResponseBytes,
    required this.aliasCollisionCount,
    required this.unsafeCandidateLabels,
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
  final McpLocalProjectsReader? _localProjectsReader;

  McpDisclosurePreviewService({
    Directory? repoRoot,
    File? configFile,
    McpPreviewJsonReader? jsonReader,
    McpLocalProjectIdsReader? localProjectIdsReader,
    McpLocalProjectsReader? localProjectsReader,
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
       _localProjectIdsReader = localProjectIdsReader,
       _localProjectsReader = localProjectsReader;

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
    final parseOutcome = _parsePolicy(policyBytes);
    final policy = parseOutcome.policy;
    if (policy == null) {
      return McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'valid',
        policyState: parseOutcome.state,
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
            inventory.state != 'readable' ||
            inventory.titleDriftAliases.isNotEmpty ||
            inventory.missingTitleFingerprintAliases.isNotEmpty ||
            inventory.unresolvedOrRemoteIneligibleEntries > 0
        ? 'attention'
        : 'unverified';

    return McpDisclosurePreview(
      overallState: overallState,
      configState: 'valid',
      policyState: 'valid',
      policySchema: policy.schema,
      policyFingerprint: policy.digest.substring(0, 12),
      policyMode: _policyMode,
      approvedProjects: policy.projects,
      eligibleNotEnrolledProjects: inventory.candidates,
      titleDriftAliases: inventory.titleDriftAliases,
      missingTitleFingerprintAliases: inventory.missingTitleFingerprintAliases,
      inventoryState: inventory.state,
      registeredProjects: inventory.registeredProjects,
      policyApprovedProjects: inventory.policyApprovedProjects,
      remotelyVisibleProjects: inventory.remotelyVisibleProjects,
      notAllowlistedProjects: inventory.notAllowlistedProjects,
      unresolvedOrRemoteIneligibleEntries:
          inventory.unresolvedOrRemoteIneligibleEntries,
      candidateInventoryProjects: inventory.candidateInventoryProjects,
      candidateDetailProjects: inventory.candidateDetailProjects,
      inventoryPageCount: inventory.pageCount,
      estimatedInventoryResponseBytes: inventory.estimatedResponseBytes,
      aliasCollisionCount: inventory.aliasCollisionCount,
      unsafeCandidateLabels: inventory.unsafeCandidateLabels,
      restartRequired: !gateway.policyMatches,
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
    final richReader = _localProjectsReader;
    if (richReader != null) {
      try {
        final records = List<McpLocalProjectRecord>.unmodifiable(
          await richReader(),
        );
        final byId = {for (final record in records) record.localId: record};
        final enrolledIds = policy.localProjectIds;
        final resolvedEntries = policy.entries
            .where((entry) => byId.containsKey(entry.localId))
            .toList(growable: false);
        final titleDriftAliases = <String>[];
        final missingTitleFingerprintAliases = <String>[];
        for (final entry in resolvedEntries) {
          final currentTitle = byId[entry.localId]!.title;
          final fingerprint = entry.sourceTitleFingerprint;
          if (fingerprint != null) {
            if (_sourceTitleFingerprint(currentTitle) != fingerprint) {
              titleDriftAliases.add(entry.project.alias);
            }
          } else if (policy.schema == _policySchemaV1) {
            if (currentTitle != entry.project.label) {
              titleDriftAliases.add(entry.project.alias);
            }
          } else {
            missingTitleFingerprintAliases.add(entry.project.alias);
          }
        }
        titleDriftAliases.sort();
        missingTitleFingerprintAliases.sort();
        final usedAliases = policy.projects
            .map((project) => project.alias)
            .toSet();
        final forbiddenLocalIds = records
            .map((record) => record.localId)
            .toSet();
        var aliasCollisions = 0;
        final candidates = <McpDisclosureCandidate>[];
        final candidateRecords =
            records
                .where((record) => !enrolledIds.contains(record.localId))
                .toList(growable: false)
              ..sort((a, b) {
                final titleCompare = a.title.toLowerCase().compareTo(
                  b.title.toLowerCase(),
                );
                return titleCompare != 0
                    ? titleCompare
                    : a.localId.compareTo(b.localId);
              });
        for (final record in candidateRecords) {
          final unsafeReason =
              forbiddenLocalIds.any(
                (localId) =>
                    record.title == localId ||
                    (localId.length >= 8 && record.title.contains(localId)),
              )
              ? 'label_matches_local_id'
              : _unsafeLabelReason(record.title);
          String? alias;
          if (unsafeReason == null) {
            final proposal = _proposeAlias(
              record.title,
              usedAliases,
              forbiddenLocalIds,
            );
            alias = proposal.alias;
            aliasCollisions += proposal.collisionAdjustments;
            if (alias != null) usedAliases.add(alias);
          }
          candidates.add(
            McpDisclosureCandidate(
              title: record.title,
              proposedAlias: alias,
              unsafeReason: unsafeReason,
              sourceTitleFingerprint: _sourceTitleFingerprint(record.title),
            ),
          );
        }
        final safeCandidates = candidates
            .where((candidate) => !candidate.requiresReview)
            .toList(growable: false);
        final candidateInventoryProjects =
            policy.projects
                .where((project) => project.inventoryEnabled)
                .length +
            safeCandidates.length;
        final candidateDetailProjects = policy.projects
            .where((project) => project.detailEnabled)
            .length;
        final projectedRows = <Map<String, Object?>>[];
        for (final entry in resolvedEntries) {
          if (!entry.project.inventoryEnabled) continue;
          projectedRows.add(_inventoryRow(byId[entry.localId]!, entry.project));
        }
        for (var index = 0; index < candidates.length; index += 1) {
          final candidate = candidates[index];
          if (candidate.requiresReview) continue;
          projectedRows.add(
            _inventoryRow(
              candidateRecords[index],
              McpDisclosureProject(
                alias: candidate.proposedAlias!,
                label: candidate.title,
                detailEnabled: false,
              ),
            ),
          );
        }
        projectedRows.sort(
          (a, b) =>
              (a['projectId']! as String).compareTo(b['projectId']! as String),
        );
        final firstPage = projectedRows.take(_inventoryPageSize).toList();
        final total = projectedRows.length;
        final inventoryDto = <String, Object?>{
          'schema': _inventorySchema,
          'projects': firstPage,
          'page': {
            'offset': 0,
            'limit': _inventoryPageSize,
            'returned': firstPage.length,
            'total': total,
            'truncated': total > _inventoryPageSize,
            'nextOffset': total > _inventoryPageSize
                ? _inventoryPageSize
                : null,
          },
          'disclosure': {
            'scope': 'operator_approved_portfolio_inventory',
            'denyByDefault': true,
            'absenceDoesNotProveUnregistered': true,
            'detailsRequireSeparateApproval': true,
          },
        };
        return _InventorySnapshot(
          state: candidates.any((candidate) => candidate.requiresReview)
              ? 'review_required'
              : 'readable',
          registeredProjects: records.length,
          policyApprovedProjects: policy.localProjectIds.length,
          remotelyVisibleProjects: resolvedEntries.length,
          notAllowlistedProjects: candidateRecords.length,
          unresolvedOrRemoteIneligibleEntries:
              policy.localProjectIds.length - resolvedEntries.length,
          candidates: List.unmodifiable(candidates),
          titleDriftAliases: List.unmodifiable(titleDriftAliases),
          missingTitleFingerprintAliases: List.unmodifiable(
            missingTitleFingerprintAliases,
          ),
          candidateInventoryProjects: candidateInventoryProjects,
          candidateDetailProjects: candidateDetailProjects,
          pageCount: candidateInventoryProjects == 0
              ? 0
              : (candidateInventoryProjects / _inventoryPageSize).ceil(),
          estimatedResponseBytes: _canonicalJsonBytes(inventoryDto),
          aliasCollisionCount: aliasCollisions,
          unsafeCandidateLabels: candidates
              .where((candidate) => candidate.unsafeReason != null)
              .length,
        );
      } catch (_) {
        return _emptyInventorySnapshot(state: 'unreadable', policy: policy);
      }
    }
    final reader = _localProjectIdsReader;
    if (reader == null) {
      return _emptyInventorySnapshot(state: 'not_checked', policy: policy);
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
        candidates: const [],
        titleDriftAliases: const [],
        missingTitleFingerprintAliases: const [],
        candidateInventoryProjects: remotelyVisible,
        candidateDetailProjects: policy.projects
            .where((project) => project.detailEnabled)
            .length,
        pageCount: remotelyVisible == 0
            ? 0
            : (remotelyVisible / _inventoryPageSize).ceil(),
        estimatedResponseBytes: 0,
        aliasCollisionCount: 0,
        unsafeCandidateLabels: 0,
      );
    } catch (_) {
      return _emptyInventorySnapshot(state: 'unreadable', policy: policy);
    }
  }

  static _InventorySnapshot _emptyInventorySnapshot({
    required String state,
    required _PolicySnapshot policy,
  }) => _InventorySnapshot(
    state: state,
    registeredProjects: 0,
    policyApprovedProjects: policy.localProjectIds.length,
    remotelyVisibleProjects: 0,
    notAllowlistedProjects: 0,
    unresolvedOrRemoteIneligibleEntries: 0,
    candidates: const [],
    titleDriftAliases: const [],
    missingTitleFingerprintAliases: const [],
    candidateInventoryProjects: policy.projects
        .where((project) => project.inventoryEnabled)
        .length,
    candidateDetailProjects: policy.projects
        .where((project) => project.detailEnabled)
        .length,
    pageCount: 0,
    estimatedResponseBytes: 0,
    aliasCollisionCount: 0,
    unsafeCandidateLabels: 0,
  );

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

  static _PolicyParseOutcome _parsePolicy(List<int> bytes) {
    final decoded = _decodeObject(bytes);
    if (decoded == null ||
        !_sameKeys(decoded.keys.toSet(), const {'schema', 'projects'})) {
      return const _PolicyParseOutcome('invalid_root');
    }
    final schema = decoded['schema'];
    if (!const {_policySchemaV1, _policySchemaV2}.contains(schema)) {
      return const _PolicyParseOutcome('unsupported_schema');
    }
    final rows = decoded['projects'];
    if (rows is! List) return const _PolicyParseOutcome('invalid_projects');
    final maxProjects = schema == _policySchemaV1
        ? _maxDetailProjects
        : _maxInventoryProjects;
    if (rows.length > maxProjects) {
      return _PolicyParseOutcome(
        schema == _policySchemaV1
            ? 'detail_capacity_exceeded'
            : 'inventory_capacity_exceeded',
      );
    }
    final aliases = <String>{};
    final localIds = <String>{};
    final projects = <McpDisclosureProject>[];
    final entries = <_PolicyEntry>[];
    var detailProjects = 0;
    for (final rawRow in rows) {
      if (rawRow is! Map || !rawRow.keys.every((key) => key is String)) {
        return const _PolicyParseOutcome('invalid_entry');
      }
      final keys = rawRow.keys.cast<String>().toSet();
      final validShape = schema == _policySchemaV1
          ? keys.containsAll(const {'projectId', 'alias'}) &&
                keys.every(const {'projectId', 'alias', 'label'}.contains)
          : keys.containsAll(const {'projectId', 'alias', 'label', 'access'}) &&
                keys.every(
                  const {
                    'projectId',
                    'alias',
                    'label',
                    'access',
                    'sourceTitleFingerprint',
                  }.contains,
                );
      if (!validShape) return const _PolicyParseOutcome('invalid_entry');
      final localId = rawRow['projectId'];
      final alias = rawRow['alias'];
      final label = rawRow['label'] ?? alias;
      late final Set<String> access;
      if (schema == _policySchemaV1) {
        access = const {'inventory', 'detail'};
      } else {
        final rawAccess = rawRow['access'];
        if (rawAccess is! List ||
            rawAccess.isEmpty ||
            rawAccess.any((item) => item is! String) ||
            rawAccess.cast<String>().toSet().length != rawAccess.length) {
          return const _PolicyParseOutcome('invalid_access');
        }
        access = rawAccess.cast<String>().toSet();
        if (!access.contains('inventory') ||
            !access.every(const {'inventory', 'detail'}.contains)) {
          return const _PolicyParseOutcome('invalid_access');
        }
      }
      if (localId is! String ||
          localId.trim().length < 8 ||
          localId.length > 128 ||
          localId.codeUnits.any((unit) => unit < 32)) {
        return const _PolicyParseOutcome('invalid_local_id');
      }
      if (alias is! String || !_aliasPattern.hasMatch(alias)) {
        return const _PolicyParseOutcome('invalid_alias');
      }
      if (label is! String ||
          !_labelPattern.hasMatch(label) ||
          _tokenShapePattern.hasMatch(label)) {
        return const _PolicyParseOutcome('unsafe_label');
      }
      if (alias == localId || label == localId) {
        return const _PolicyParseOutcome('local_identifier_exposure');
      }
      if (!localIds.add(localId)) {
        return const _PolicyParseOutcome('duplicate_local_id');
      }
      if (!aliases.add(alias)) {
        return const _PolicyParseOutcome('duplicate_alias');
      }
      final sourceTitleFingerprint = rawRow['sourceTitleFingerprint'];
      if (sourceTitleFingerprint != null &&
          (sourceTitleFingerprint is! String ||
              !_sourceTitleFingerprintPattern.hasMatch(
                sourceTitleFingerprint,
              ))) {
        return const _PolicyParseOutcome('invalid_source_title_fingerprint');
      }
      final project = McpDisclosureProject(
        alias: alias,
        label: label,
        detailEnabled: access.contains('detail'),
      );
      if (project.detailEnabled) detailProjects += 1;
      projects.add(project);
      entries.add(
        _PolicyEntry(
          localId: localId,
          project: project,
          sourceTitleFingerprint: sourceTitleFingerprint as String?,
        ),
      );
    }
    for (final project in projects) {
      for (final localId in localIds) {
        if (project.alias == localId ||
            project.label == localId ||
            (localId.length >= 8 &&
                (project.alias.contains(localId) ||
                    project.label.contains(localId)))) {
          return const _PolicyParseOutcome('local_identifier_exposure');
        }
      }
    }
    if (detailProjects > _maxDetailProjects) {
      return const _PolicyParseOutcome('detail_capacity_exceeded');
    }
    return _PolicyParseOutcome(
      'valid',
      _PolicySnapshot(
        schema: schema! as String,
        digest: sha256.convert(bytes).toString(),
        projects: List.unmodifiable(projects),
        entries: List.unmodifiable(entries),
        localProjectIds: Set.unmodifiable(localIds),
      ),
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

class _AliasProposal {
  final String? alias;
  final int collisionAdjustments;

  const _AliasProposal(this.alias, this.collisionAdjustments);
}

_AliasProposal _proposeAlias(
  String title,
  Set<String> usedAliases,
  Set<String> forbiddenLocalIds,
) {
  bool conflicts(String alias) =>
      usedAliases.contains(alias) ||
      forbiddenLocalIds.any(
        (localId) =>
            alias == localId ||
            (localId.length >= 8 && alias.contains(localId)),
      );

  var base = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) return const _AliasProposal(null, 0);
  if (base.length > 63)
    base = base.substring(0, 63).replaceFirst(RegExp(r'-+$'), '');
  if (!conflicts(base)) return _AliasProposal(base, 0);
  final baseContainsLocalId = forbiddenLocalIds.any(
    (localId) =>
        base == localId || (localId.length >= 8 && base.contains(localId)),
  );
  var suffix = 2;
  while (!baseContainsLocalId && suffix < 10_000) {
    final suffixText = '-$suffix';
    final prefixLength = 63 - suffixText.length;
    final prefix = base.length > prefixLength
        ? base.substring(0, prefixLength).replaceFirst(RegExp(r'-+$'), '')
        : base;
    final candidate = '$prefix$suffixText';
    if (_aliasPattern.hasMatch(candidate) && !conflicts(candidate)) {
      return _AliasProposal(candidate, 1);
    }
    suffix += 1;
  }
  suffix = 1;
  while (suffix < 10_000) {
    final candidate = suffix == 1 ? 'portfolio-item' : 'portfolio-item-$suffix';
    if (!conflicts(candidate)) return _AliasProposal(candidate, 1);
    suffix += 1;
  }
  return const _AliasProposal(null, 1);
}

String? _unsafeLabelReason(String title) {
  if (title.codeUnits.any((unit) => unit < 32 || unit == 127)) {
    return 'control_character';
  }
  if (RegExp(r'[\u202A-\u202E\u2066-\u2069]').hasMatch(title)) {
    return 'bidi_control';
  }
  if (!_labelPattern.hasMatch(title)) return 'label_format';
  if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(title)) {
    return 'email_like';
  }
  if (title.contains('://') || title.toLowerCase().startsWith('www.')) {
    return 'url_like';
  }
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(title)) return 'path_like';
  if (RegExp(r'^[0-9a-fA-F]{20,}$').hasMatch(title) ||
      RegExp(r'^[A-Za-z0-9_-]{32,}$').hasMatch(title)) {
    return 'token_like';
  }
  return null;
}

String _sourceTitleFingerprint(String title) =>
    sha256.convert(utf8.encode(title)).toString();

String _visibleText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0x20 && rune <= 0x7e) {
      buffer.writeCharCode(rune);
    } else {
      buffer.write('\\u{${rune.toRadixString(16).padLeft(4, '0')}}');
    }
  }
  return buffer.toString();
}

Map<String, Object?> _inventoryRow(
  McpLocalProjectRecord record,
  McpDisclosureProject project,
) {
  final freshnessStatus = _safePreviewEnum(record.freshnessStatus, const {
    'current',
    'stale',
    'unknown',
  });
  final status = _safePreviewEnum(record.status, const {
    'active',
    'stale',
    'needs_update',
    'needs_review',
    'local_only',
    'public_mismatch',
    'paused',
    'blocked',
    'completed',
  });
  final reasons = {...record.staleReasons, ...record.attentionReasons};
  final planningActionRequired =
      record.needsAttention ||
      _attentionProjectStatuses.contains(status) ||
      record.attentionReasons.any(_planningSignalReasons.contains) ||
      record.blocksProgressWorkItems > 0;
  final dataRefreshRequired =
      freshnessStatus != 'current' ||
      record.staleReasons.isNotEmpty ||
      record.attentionReasons.any(
        (reason) => !_planningSignalReasons.contains(reason),
      );
  final severity =
      record.blocksProgressWorkItems > 0 ||
          status == 'blocked' ||
          reasons.contains('blocked_work_items') ||
          reasons.contains('capsule_errors')
      ? 'high'
      : planningActionRequired
      ? 'medium'
      : freshnessStatus == 'unknown'
      ? 'medium'
      : dataRefreshRequired
      ? 'low'
      : 'none';
  final reasonClasses = <String>[
    if (_attentionProjectStatuses.contains(status) ||
        reasons.any((reason) => reason.startsWith('project_status_')))
      'lifecycle',
    if (record.blocksProgressWorkItems > 0 ||
        reasons.contains('blocked_work_items') ||
        reasons.contains('high_priority_without_active_work'))
      'workload',
    if (reasons.any(
      (reason) =>
          reason.startsWith('missing_local_') ||
          reason.startsWith('linked_registry_') ||
          reason.startsWith('invalid_local_') ||
          reason.startsWith('old_local_') ||
          reason == 'local_dirty_state',
    ))
      'local_evidence',
    if (reasons.any(
      (reason) => reason.startsWith('github_') || reason == 'old_github_check',
    ))
      'remote_evidence',
    if (reasons.any((reason) => reason.startsWith('capsule_'))) 'capsule',
    if (freshnessStatus == 'stale') 'freshness_stale',
    if (freshnessStatus == 'unknown') 'freshness_unknown',
  ]..sort();
  return {
    'projectId': project.alias,
    'title': project.label,
    'status': status,
    'phase': _safePreviewEnum(record.phase, const {
      'idea',
      'design',
      'build',
      'test',
      'ship',
      'stabilize',
    }),
    'priority': _safePreviewEnum(record.priority, const {
      'low',
      'normal',
      'high',
      'urgent',
    }),
    'needsAttention': record.needsAttention,
    'freshness': {'status': freshnessStatus},
    'signals': {
      'planningActionRequired': planningActionRequired,
      'dataRefreshRequired': dataRefreshRequired,
      'severity': severity,
      'reasonClasses': reasonClasses,
    },
    'workItems': {
      'active': record.activeWorkItems,
      'blocked': record.blockedWorkItems,
      'blocksProgress': record.blocksProgressWorkItems,
    },
    'detailsAvailable': project.detailEnabled,
  };
}

String _safePreviewEnum(Object? value, Set<String> allowed) =>
    value is String && allowed.contains(value) ? value : 'unknown';

int _canonicalJsonBytes(Object? value) {
  Object? canonicalize(Object? item) {
    if (item is Map) {
      final result = SplayTreeMap<String, Object?>();
      for (final entry in item.entries) {
        if (entry.key is! String) continue;
        result[entry.key as String] = canonicalize(entry.value);
      }
      return result;
    }
    if (item is List) return item.map(canonicalize).toList(growable: false);
    return item;
  }

  return utf8.encode(jsonEncode(canonicalize(value))).length;
}

final _aliasPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');
final _labelPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._()\-]{0,79}$');
final _tokenShapePattern = RegExp(r'^(?:[0-9a-fA-F]{20,}|[A-Za-z0-9_-]{32,})$');
final _sourceTitleFingerprintPattern = RegExp(r'^[0-9a-f]{64}$');
final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

List<McpDisclosureContract> _contracts(String alias, String label) {
  final inventoryProject = <String, Object?>{
    'projectId': alias,
    'title': label,
    'status': 'active',
    'phase': 'build',
    'priority': 'normal',
    'needsAttention': false,
    'freshness': {'status': 'current'},
    'signals': {
      'planningActionRequired': false,
      'dataRefreshRequired': false,
      'severity': 'none',
      'reasonClasses': <Object?>[],
    },
    'workItems': {'active': 0, 'blocked': 0, 'blocksProgress': 0},
    'detailsAvailable': true,
  };
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
      'dataRefreshRequired': false,
    },
    'signals': {
      'planningActionRequired': false,
      'dataRefreshRequired': false,
      'severity': 'none',
      'reasonClasses': <Object?>[],
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
        'projects[].workItems/freshness.status/signals/needsAttention',
        'projects[].detailsAvailable',
        'page.offset/limit/returned/total/truncated/nextOffset',
      ],
      sample: {
        'schema': _inventorySchema,
        'projects': [inventoryProject],
        'page': {
          'offset': 0,
          'limit': 64,
          'returned': 1,
          'total': 1,
          'truncated': false,
          'nextOffset': null,
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
      sample: {'schema': _statusSchema, 'project': project},
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
        'schema': _workloadSchema,
        'generatedAt': '2026-07-14T00:00:00Z',
        'scope': {'projectId': alias, 'title': label},
        'counts': {
          'total': 1,
          'ready': 1,
          'blocked': 0,
          'reviewNeeded': 0,
          'stale': 0,
          'importedChecklist': 0,
          'workItems': 1,
          'llmQueueItems': 0,
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
        'schema': _planningSchema,
        'generatedAt': '2026-07-14T00:00:00Z',
        'project': project,
        'workload': {
          'counts': {
            'total': 0,
            'ready': 0,
            'blocked': 0,
            'workItems': 0,
            'llmQueueItems': 0,
          },
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
