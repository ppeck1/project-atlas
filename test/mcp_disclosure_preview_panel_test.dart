import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/features/settings/mcp_disclosure_preview_panel.dart';
import 'package:project_atlas/services/mcp_disclosure_preview_service.dart';

void main() {
  testWidgets('renders the safe remote disclosure preview and refreshes', (
    tester,
  ) async {
    var loads = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 1000,
              child: McpDisclosurePreviewPanel(
                loader: () async {
                  loads += 1;
                  return _preview();
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.text('Remote MCP disclosure'), findsOneWidget);
    expect(find.text('Project Atlas (project-atlas)'), findsNWidgets(2));
    expect(find.text('Overall: unverified'), findsOneWidget);
    expect(find.text('Gateway: metadata matched'), findsOneWidget);
    expect(find.textContaining('atlas.read'), findsOneWidget);
    expect(find.textContaining('abc123def456'), findsOneWidget);
    expect(find.text('deny by default'), findsOneWidget);
    expect(find.text('49 registered'), findsOneWidget);
    expect(find.text('2 inventory - 2 detail'), findsOneWidget);
    expect(
      find.text('49 project(s) - 1 page(s) - 12000 B first page'),
      findsOneWidget,
    );
    expect(find.text('0 unresolved or remote-ineligible'), findsOneWidget);
    expect(
      find.text(
        '1 unsafe label(s) - 0 alias adjustment(s) - 0 title drift - 0 missing baseline',
      ),
      findsOneWidget,
    );
    expect(find.text('gateway policy identity matched'), findsOneWidget);
    for (final tool in mcpRemoteTools) {
      expect(find.text(tool), findsOneWidget);
    }

    final candidateHeader = find.text('Eligible, not enrolled (2)');
    await tester.ensureVisible(candidateHeader);
    await tester.tap(candidateHeader);
    await tester.pumpAndSettle();

    final renderedText = tester.allWidgets
        .whereType<Text>()
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    for (final forbidden in const [
      'local-private-id',
      r'C:\private',
      'https://tenant.example/',
      'https://resource.example/mcp',
      'full-policy-digest-sentinel',
      'correlation-id-sentinel',
      'payload-sentinel',
    ]) {
      expect(renderedText, isNot(contains(forbidden)));
    }
    expect(renderedText, isNot(contains('Spoof\u202EName\n')));
    expect(renderedText, contains(r'Spoof\u{202e}Name\u{000a}'));

    final refresh = find.byTooltip('Refresh disclosure preview');
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(loads, 2);
  });
}

McpDisclosurePreview _preview() => McpDisclosurePreview(
  overallState: 'unverified',
  configState: 'valid',
  policyState: 'valid',
  policySchema: 'project_atlas.remote_disclosure_policy.v1',
  policyFingerprint: 'abc123def456',
  policyMode: 'deny_by_default',
  approvedProjects: const [
    McpDisclosureProject(alias: 'project-atlas', label: 'Project Atlas'),
    McpDisclosureProject(
      alias: 'project-capsule',
      label: 'New Project Capsule Template',
    ),
  ],
  eligibleNotEnrolledProjects: const [
    McpDisclosureCandidate(
      title: 'Candidate Project',
      proposedAlias: 'candidate-project',
      unsafeReason: null,
      sourceTitleFingerprint:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    ),
    McpDisclosureCandidate(
      title: 'Spoof\u202EName\n',
      proposedAlias: null,
      unsafeReason: 'bidi_control',
      sourceTitleFingerprint:
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    ),
  ],
  titleDriftAliases: const [],
  missingTitleFingerprintAliases: const [],
  inventoryState: 'readable',
  registeredProjects: 49,
  policyApprovedProjects: 2,
  remotelyVisibleProjects: 2,
  notAllowlistedProjects: 47,
  unresolvedOrRemoteIneligibleEntries: 0,
  candidateInventoryProjects: 49,
  candidateDetailProjects: 2,
  inventoryPageCount: 1,
  estimatedInventoryResponseBytes: 12000,
  aliasCollisionCount: 0,
  unsafeCandidateLabels: 1,
  restartRequired: false,
  gatewayState: 'metadata_matched',
  activeBinaryState: 'unverified',
  authMode: 'oauth',
  verifierMode: 'jwks',
  scope: 'atlas.read',
  issuerCount: 1,
  tunnelConfigured: true,
  exactToolBoundary: true,
  policyMatches: true,
  scopeMatches: true,
  oauthAuthorityMatches: true,
  auditState: 'readable',
  malformedAuditEvents: 0,
  auditTruncated: false,
  recentAuditEvents: [
    McpDisclosureAuditEvent(
      timestamp: DateTime.utc(2026, 7, 10, 12),
      tool: 'list_projects',
      projectAlias: 'project-atlas',
      decision: 'allowed',
      outcome: 'ok',
      items: 1,
      responseBytes: 512,
      durationMs: 8,
    ),
  ],
  contracts: [
    for (final tool in mcpRemoteTools)
      McpDisclosureContract(
        tool: tool,
        disclosedFields: const ['schema', 'approved aliases only'],
        sample: const {
          'schema': 'project_atlas.remote_projection.v1',
          'projectId': 'project-atlas',
        },
      ),
  ],
);
