import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../services/project_summary_models.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';
import 'summary_run_provenance.dart';

class ProjectAiPanelModel {
  final String projectId;
  final bool expanded;
  final bool includeLibrary;
  final bool summaryLoading;
  final String? summaryText;
  final ProjectSummaryOutcome? summaryOutcome;
  final DateTime? generatedAt;
  final ProjectSummaryEvidencePacket? evidencePacket;
  final bool evidenceLoading;
  const ProjectAiPanelModel({
    required this.projectId,
    required this.expanded,
    required this.includeLibrary,
    required this.summaryLoading,
    required this.summaryText,
    required this.summaryOutcome,
    required this.generatedAt,
    required this.evidencePacket,
    required this.evidenceLoading,
  });
}

class ProjectAiPanelActions {
  final VoidCallback onToggle;
  final ValueChanged<bool> onToggleLibrary;
  final VoidCallback onGenerate;

  const ProjectAiPanelActions({
    required this.onToggle,
    required this.onToggleLibrary,
    required this.onGenerate,
  });
}

class ProjectAiPanel extends StatelessWidget {
  final ProjectAiPanelModel model;
  final ProjectAiPanelActions actions;

  const ProjectAiPanel({super.key, required this.model, required this.actions});

  String get projectId => model.projectId;
  bool get expanded => model.expanded;
  bool get includeLibrary => model.includeLibrary;
  bool get summaryLoading => model.summaryLoading;
  String? get summaryText => model.summaryText;
  ProjectSummaryOutcome? get summaryOutcome => model.summaryOutcome;
  DateTime? get generatedAt => model.generatedAt;
  ProjectSummaryEvidencePacket? get evidencePacket => model.evidencePacket;
  bool get evidenceLoading => model.evidenceLoading;
  VoidCallback get onToggle => actions.onToggle;
  ValueChanged<bool> get onToggleLibrary => actions.onToggleLibrary;
  VoidCallback get onGenerate => actions.onGenerate;

  String _formatAge(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final hasContent = summaryOutcome != null || summaryText != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primary.withAlpha(15),
        border: Border.all(color: colors.primary.withAlpha(51)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'AI Project Assistant',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.primary,
                        fontSize: 14,
                      ),
                    ),
                    if (generatedAt != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatAge(generatedAt!),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white24,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => onToggleLibrary(!includeLibrary),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: includeLibrary,
                            onChanged: (v) => onToggleLibrary(v ?? false),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Include Library',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onToggle,
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white38,
                    ),
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 12),
            _EvidencePacketPreview(
              packet: evidencePacket,
              loading: evidenceLoading,
              includeLibrary: includeLibrary,
            ),
            const SizedBox(height: 12),
            if (summaryLoading)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Generating…',
                    style: TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ],
              )
            else if (!hasContent)
              FilledButton.icon(
                onPressed: onGenerate,
                icon: const Icon(Icons.psychology, size: 16),
                label: const Text('Generate Summary'),
              )
            else if (summaryOutcome?.hasStructured == true)
              _StructuredSummaryView(
                projectId: projectId,
                result: summaryOutcome!.structured!,
                documentPaths: summaryOutcome!.documentPaths,
                onRegenerate: onGenerate,
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      summaryText ?? summaryOutcome?.rawOutput ?? '',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onGenerate,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Regenerate'),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.primary,
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            SummaryRunProvenance(projectId: projectId),
          ],
        ],
      ),
    );
  }
}

// ─── Structured summary renderer ─────────────────────────────────────────────

class _EvidencePacketPreview extends StatelessWidget {
  final ProjectSummaryEvidencePacket? packet;
  final bool loading;
  final bool includeLibrary;

  const _EvidencePacketPreview({
    required this.packet,
    required this.loading,
    required this.includeLibrary,
  });

  String _chars(int value) {
    if (value >= 10000) return '${(value / 1000).round()}k';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  String _categoryLabel(String? value) =>
      (value == null || value.trim().isEmpty)
      ? 'other'
      : value.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    final currentPacket = packet;
    final docs = currentPacket?.documents ?? const <ProjectSummaryContextDoc>[];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 15, color: colors.primary),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Evidence packet',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (currentPacket != null)
                Wrap(
                  spacing: 6,
                  children: [
                    MiniPill(
                      'Docs',
                      '${currentPacket.includedDocumentCount}/${currentPacket.suppliedDocumentCount}',
                    ),
                    MiniPill(
                      'Excerpt',
                      _chars(currentPacket.totalExcerptChars),
                    ),
                  ],
                ),
            ],
          ),
          if (!loading) ...[
            const SizedBox(height: 8),
            if (currentPacket == null)
              const Text(
                'No packet loaded.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              )
            else if (!includeLibrary)
              Text(
                'Library disabled (${currentPacket.suppliedDocumentCount} linked document${currentPacket.suppliedDocumentCount == 1 ? '' : 's'} available).',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              )
            else if (docs.isEmpty)
              const Text(
                'No linked Library documents.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              )
            else ...[
              if (currentPacket.warnings.isNotEmpty) ...[
                ...currentPacket.warnings
                    .take(3)
                    .map(
                      (warning) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 13,
                              color: Colors.amberAccent,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                warning,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                if (currentPacket.warnings.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      '+${currentPacket.warnings.length - 3} more warning(s)',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                const SizedBox(height: 2),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: docs.take(6).map((doc) {
                  final reason = doc.selectionReason ?? 'linked document';
                  final category = _categoryLabel(doc.evidenceCategory);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 30,
                          child: Text(
                            '#${doc.rank ?? '-'}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                doc.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '$category - $reason - ${_chars(doc.excerptChars)} chars',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _StructuredSummaryView extends StatelessWidget {
  final String projectId;
  final ProjectSummaryResult result;
  final Map<String, String?> documentPaths;
  final VoidCallback onRegenerate;

  const _StructuredSummaryView({
    required this.projectId,
    required this.result,
    required this.documentPaths,
    required this.onRegenerate,
  });

  static const _body = TextStyle(
    fontSize: 13,
    color: Color(0xDEFFFFFF),
    height: 1.55,
  );
  static const _sub = TextStyle(
    fontSize: 12,
    color: Color(0x8AFFFFFF),
    height: 1.5,
  );

  Widget _section(BuildContext context, String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).extension<AtlasColors>()!.primary,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  Widget _bullets(List<String> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: items
        .map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(color: Color(0x8AFFFFFF))),
                Expanded(child: Text(t, style: _body)),
              ],
            ),
          ),
        )
        .toList(),
  );

  Widget _numbered(List<String> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: List.generate(
      items.length,
      (i) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              child: Text(
                '${i + 1}.',
                style: const TextStyle(color: Color(0x8AFFFFFF)),
              ),
            ),
            Expanded(child: Text(items[i], style: _body)),
          ],
        ),
      ),
    ),
  );

  Future<void> _openInExplorer(BuildContext context, String path) async {
    try {
      // /select, highlights the file in Explorer on Windows
      await Process.start('explorer.exe', ['/select,', path]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open Explorer: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = result;
    final colors = Theme.of(context).extension<AtlasColors>()!;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF79A7FF).withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Goal
          if (s.goal.isNotEmpty) _section(context, 'Goal', _bullets(s.goal)),

          // Current State
          if (s.currentState.isNotEmpty)
            _section(
              context,
              'Current State',
              Text(s.currentState, style: _body),
            ),

          // Ownership
          if (s.ownership.isNotEmpty)
            _section(
              context,
              'Ownership / Active Work',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: s.ownership
                    .map(
                      (o) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              o.person,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xDEFFFFFF),
                              ),
                            ),
                            ...o.work.map(
                              (w) => Padding(
                                padding: const EdgeInsets.only(
                                  left: 12,
                                  top: 2,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '– ',
                                      style: TextStyle(
                                        color: Color(0x8AFFFFFF),
                                      ),
                                    ),
                                    Expanded(child: Text(w, style: _sub)),
                                  ],
                                ),
                              ),
                            ),
                            if (o.basis != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 12,
                                  top: 2,
                                ),
                                child: Text(
                                  'Basis: ${o.basis}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0x61FFFFFF),
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),

          // Relevant Library Docs
          if (s.relevantDocuments.isNotEmpty)
            _section(
              context,
              'Relevant Library Docs',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: s.relevantDocuments.map((doc) {
                  final storedPath = documentPaths[doc.documentId];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          doc.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xDEFFFFFF),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(doc.reason, style: _sub),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () {
                                context.go(
                                  libraryRouteForProject(
                                    projectId,
                                    entryType: 'document',
                                    entryId: doc.documentId,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.library_books, size: 13),
                              label: const Text('Open in Library'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: colors.primary,
                                side: BorderSide(
                                  color: colors.primary.withAlpha(80),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (storedPath != null && storedPath.isNotEmpty)
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _openInExplorer(context, storedPath),
                                icon: const Icon(Icons.folder_open, size: 13),
                                label: const Text('Show in Explorer'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0x8AFFFFFF),
                                  side: BorderSide(
                                    color: colors.line.withAlpha(200),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  textStyle: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),

          // Blockers / Risks
          if (s.blockersAndRisks.isNotEmpty)
            _section(context, 'Blockers / Risks', _bullets(s.blockersAndRisks)),

          // Next Actions
          if (s.nextActions.isNotEmpty)
            _section(
              context,
              'Next Practical Actions',
              _numbered(s.nextActions),
            ),

          // Confidence / Gaps
          if (s.confidence.isNotEmpty)
            _section(
              context,
              'Confidence / Gaps',
              Text(
                s.confidence,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0x61FFFFFF),
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
            ),

          // Regenerate
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Regenerate'),
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                padding: EdgeInsets.zero,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
