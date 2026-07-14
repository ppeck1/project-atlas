import 'dart:convert';

import 'package:flutter/material.dart';

import '../../services/mcp_disclosure_preview_service.dart';

typedef McpDisclosurePreviewLoader = Future<McpDisclosurePreview> Function();

class McpDisclosurePreviewPanel extends StatefulWidget {
  final McpDisclosurePreviewLoader? loader;
  final McpLocalProjectIdsReader? localProjectIdsReader;
  final McpLocalProjectsReader? localProjectsReader;

  const McpDisclosurePreviewPanel({
    super.key,
    this.loader,
    this.localProjectIdsReader,
    this.localProjectsReader,
  });

  @override
  State<McpDisclosurePreviewPanel> createState() =>
      _McpDisclosurePreviewPanelState();
}

class _McpDisclosurePreviewPanelState extends State<McpDisclosurePreviewPanel> {
  McpDisclosurePreview? _preview;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    McpDisclosurePreview preview;
    try {
      final loader = widget.loader;
      preview = loader != null
          ? await loader()
          : await McpDisclosurePreviewService(
              localProjectIdsReader: widget.localProjectIdsReader,
              localProjectsReader: widget.localProjectsReader,
            ).inspect();
    } catch (_) {
      preview = McpDisclosurePreview.unavailable(
        overallState: 'attention',
        configState: 'unreadable',
      );
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Remote MCP disclosure',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Local-only preview. It never starts the gateway or tunnel.',
                        style: TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _loading ? null : _refresh,
                  tooltip: 'Refresh disclosure preview',
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (preview == null)
              const LinearProgressIndicator()
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StateChip(
                    label: 'Overall: ${_words(preview.overallState)}',
                    state: preview.overallState,
                  ),
                  _StateChip(
                    label: 'Config: ${_words(preview.configState)}',
                    state: preview.configState,
                  ),
                  _StateChip(
                    label: 'Policy: ${_words(preview.policyState)}',
                    state: preview.policyState,
                  ),
                  _StateChip(
                    label: 'Gateway: ${_words(preview.gatewayState)}',
                    state: preview.gatewayState,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _FactRows(preview: preview),
              const SizedBox(height: 16),
              const Text(
                'Local inventory versus remote disclosure',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'A project can be registered locally but absent remotely because '
                'the connector is deny-by-default.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              const SizedBox(height: 8),
              _VisibilityFacts(preview: preview),
              const SizedBox(height: 16),
              Text(
                'Portfolio inventory tier (${preview.inventoryProjects.length})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (preview.inventoryProjects.isEmpty)
                const Text(
                  'None. The remote boundary is deny-all.',
                  style: TextStyle(color: Colors.white60),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final project in preview.inventoryProjects)
                      Chip(label: Text('${project.label} (${project.alias})')),
                  ],
                ),
              const SizedBox(height: 12),
              Text(
                'Detail-approved tier (${preview.detailProjects.length})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (preview.detailProjects.isEmpty)
                const Text(
                  'None. Detailed project reads are deny-all.',
                  style: TextStyle(color: Colors.white60),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final project in preview.detailProjects)
                      Chip(label: Text('${project.label} (${project.alias})')),
                  ],
                ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Eligible, not enrolled (${preview.eligibleNotEnrolledProjects.length})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Local-only candidate labels. Review every label and alias before writing policy v2.',
                  style: TextStyle(fontSize: 11),
                ),
                children: [
                  if (preview.eligibleNotEnrolledProjects.isEmpty)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('No eligible unenrolled projects.'),
                    )
                  else
                    for (final candidate in preview.eligibleNotEnrolledProjects)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Text(
                            candidate.requiresReview
                                ? '${candidate.displayTitle} - review required (${candidate.unsafeReason ?? 'alias unavailable'})'
                                : '${candidate.displayTitle} (${candidate.proposedAlias})',
                            style: TextStyle(
                              fontSize: 12,
                              color: candidate.requiresReview
                                  ? Colors.orangeAccent
                                  : null,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
              if (preview.titleDriftAliases.isNotEmpty)
                Text(
                  'Title drift requires review: ${preview.titleDriftAliases.join(', ')}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
              if (preview.missingTitleFingerprintAliases.isNotEmpty)
                Text(
                  'Approval baseline missing: ${preview.missingTitleFingerprintAliases.join(', ')}',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'Exact remote tool boundary and redacted samples',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'Samples are synthetic safe shapes, never live response bodies.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
              for (final contract in preview.contracts)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  title: Text(
                    contract.tool,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    '${contract.disclosedFields.length} disclosed field groups',
                    style: const TextStyle(fontSize: 11),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final field in contract.disclosedFields)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text('- $field'),
                            ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              const JsonEncoder.withIndent(
                                '  ',
                              ).convert(contract.sample),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recent disclosure audit - ${_words(preview.auditState)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (preview.malformedAuditEvents > 0)
                    Text(
                      '${preview.malformedAuditEvents} rejected row(s)',
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (preview.recentAuditEvents.isEmpty)
                const Text(
                  'No current-policy metadata events are available.',
                  style: TextStyle(color: Colors.white60),
                )
              else
                for (final event in preview.recentAuditEvents.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${_shortTimestamp(event.timestamp)} - ${event.tool} - '
                      '${event.projectAlias ?? 'no project'} - '
                      '${event.decision}/${event.outcome} - '
                      '${event.items} item(s), ${event.responseBytes} B, '
                      '${event.durationMs} ms',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              const SizedBox(height: 8),
              const Text(
                'Active executable identity is reported as unverified because the '
                'current gateway metadata does not attest its process binary.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VisibilityFacts extends StatelessWidget {
  final McpDisclosurePreview preview;

  const _VisibilityFacts({required this.preview});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        _Fact(label: 'Disclosure policy', value: _words(preview.policyMode)),
        _Fact(
          label: 'Local inventory',
          value: preview.inventoryState == 'readable'
              ? '${preview.registeredProjects} registered'
              : _words(preview.inventoryState),
        ),
        _Fact(
          label: 'Current policy',
          value:
              '${preview.inventoryProjects.length} inventory - '
              '${preview.detailProjects.length} detail',
        ),
        _Fact(
          label: 'Candidate inventory',
          value:
              '${preview.candidateInventoryProjects} project(s) - '
              '${preview.inventoryPageCount} page(s) - '
              '${preview.estimatedInventoryResponseBytes} B first page',
        ),
        _Fact(
          label: 'Unresolved entries',
          value:
              '${preview.unresolvedOrRemoteIneligibleEntries} unresolved or '
              'remote-ineligible',
        ),
        _Fact(
          label: 'Review warnings',
          value:
              '${preview.unsafeCandidateLabels} unsafe label(s) - '
              '${preview.aliasCollisionCount} alias adjustment(s) - '
              '${preview.titleDriftAliases.length} title drift - '
              '${preview.missingTitleFingerprintAliases.length} missing baseline',
        ),
        _Fact(
          label: 'Activation',
          value: preview.restartRequired
              ? 'policy restart required'
              : 'gateway policy identity matched',
        ),
      ],
    );
  }
}

class _FactRows extends StatelessWidget {
  final McpDisclosurePreview preview;

  const _FactRows({required this.preview});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        _Fact(
          label: 'Policy',
          value:
              '${preview.policySchema} - SHA-256 '
              '${preview.policyFingerprint ?? 'unavailable'}...',
        ),
        _Fact(
          label: 'OAuth',
          value:
              '${preview.authMode} - ${preview.scope} - '
              '${preview.issuerCount} issuer(s) - ${preview.verifierMode}',
        ),
        _Fact(
          label: 'Boundary checks',
          value:
              'tools ${_yesNo(preview.exactToolBoundary)} - '
              'policy ${_yesNo(preview.policyMatches)} - '
              'authority ${_yesNo(preview.oauthAuthorityMatches)}',
        ),
        _Fact(
          label: 'Transport',
          value: preview.tunnelConfigured
              ? 'tunnel configured; not started by preview'
              : 'tunnel disabled',
        ),
        _Fact(label: 'Active binary', value: _words(preview.activeBinaryState)),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 310,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white54,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final String label;
  final String state;

  const _StateChip({required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'valid' ||
      'metadata_matched' ||
      'contained' ||
      'readable' => Colors.greenAccent,
      'attention' || 'identity_mismatch' || 'invalid' => Colors.orangeAccent,
      'missing' || 'disabled' || 'off' => Colors.blueGrey,
      _ => Colors.amberAccent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }
}

String _words(String value) => value.replaceAll('_', ' ');
String _yesNo(bool value) => value ? 'match' : 'no';

String _shortTimestamp(DateTime timestamp) {
  final utc = timestamp.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}Z';
}
