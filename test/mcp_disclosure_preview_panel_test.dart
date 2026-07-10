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
    expect(find.text('Project Atlas (project-atlas)'), findsOneWidget);
    expect(find.text('Overall: unverified'), findsOneWidget);
    expect(find.text('Gateway: metadata matched'), findsOneWidget);
    expect(find.textContaining('atlas.read'), findsOneWidget);
    expect(find.textContaining('abc123def456'), findsOneWidget);
    for (final tool in mcpRemoteTools) {
      expect(find.text(tool), findsOneWidget);
    }

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

    await tester.tap(find.byTooltip('Refresh disclosure preview'));
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
  approvedProjects: const [
    McpDisclosureProject(alias: 'project-atlas', label: 'Project Atlas'),
  ],
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
