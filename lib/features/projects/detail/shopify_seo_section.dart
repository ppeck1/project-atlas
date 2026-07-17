import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../services/shopify_seo_analyzer.dart';
import '../../../services/shopify_seo_review_service.dart';
import '../../../shared/models/app_state.dart';
import '../../../shared/models/app_state_scope.dart';
import '../../../shared/theme/atlas_colors.dart';
import 'project_detail_atoms.dart';

// Extracted from project_detail_screen.dart (C3 tranche 2).

class ShopifySeoSection extends StatefulWidget {
  final String projectId;

  const ShopifySeoSection({
    super.key,
    required this.projectId,
  });

  @override
  State<ShopifySeoSection> createState() => _ShopifySeoSectionState();
}

class _ShopifySeoSectionState extends State<ShopifySeoSection> {
  ShopifySeoReviewSnapshot? _snapshot;
  final Set<String> _selected = {};
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _filter = 'all';
  String _sort = 'lowest_score';
  AppState? _loadedState;
  String? _loadedProjectId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ShopifySeoSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      _snapshot = null;
      _selected.clear();
      _loading = true;
      _error = null;
      _loadedProjectId = null;
      _loadIfNeeded(force: true);
    }
  }

  void _loadIfNeeded({bool force = false}) {
    final state = AppStateScope.of(context);
    if (!force &&
        identical(_loadedState, state) &&
        _loadedProjectId == widget.projectId) {
      return;
    }
    _loadedState = state;
    _loadedProjectId = widget.projectId;
    unawaited(_load(state: state, projectId: widget.projectId));
  }

  Future<void> _load({
    required AppState state,
    required String projectId,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await state.getLatestShopifySeoReview(projectId);
      if (!mounted ||
          widget.projectId != projectId ||
          !identical(_loadedState, state)) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
        _loading = false;
      });
    } catch (error) {
      if (!mounted ||
          widget.projectId != projectId ||
          !identical(_loadedState, state)) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _seed() async {
    setState(() => _busy = true);
    try {
      final snapshot = await AppStateScope.of(
        context,
      ).seedExampleShopifySeoReview(widget.projectId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
      });
    } catch (error) {
      _showSnack('Shopify SEO seed failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importJson() async {
    final state = AppStateScope.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final raw = await File(path).readAsString();
      final snapshot = ShopifySeoReviewSnapshot.decode(raw);
      await state.saveShopifySeoReviewSnapshot(
        projectId: widget.projectId,
        snapshot: snapshot,
      );
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _selected
          ..clear()
          ..addAll(defaultShopifySeoProductSelection(snapshot));
      });
    } catch (error) {
      _showSnack('Shopify SEO import failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueSelected() async {
    final state = AppStateScope.of(context);
    final snapshot = _snapshot;
    if (snapshot == null || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final projectId = widget.projectId;
      final count = await state.queueShopifySeoProductBatches(
        projectId: projectId,
        snapshot: snapshot,
        productIds: Set<String>.of(_selected),
      );
      await _load(state: state, projectId: projectId);
      _showSnack(
        'Queued $count Shopify SEO product batch${count == 1 ? '' : 'es'}.',
      );
    } catch (error) {
      _showSnack('Queue failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(String format) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final export = ShopifySeoAnalyzer.buildExport(snapshot);
    final extension = switch (format) {
      'json' => 'json',
      'csv' => 'csv',
      _ => 'md',
    };
    final text = switch (format) {
      'json' => export.json,
      'csv' => export.csv,
      _ => export.markdown,
    };
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Shopify SEO review',
      fileName: 'shopify-seo-review-${snapshot.shopDomain}.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (path == null) return;
    await File(path).writeAsString(text);
    _showSnack('Exported Shopify SEO review $extension.');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _ShopifySeoEmptyState(
        message: 'Could not load Shopify SEO review data.',
        detail: _error!,
        busy: _busy,
        onSeed: _seed,
        onImport: _importJson,
      );
    }
    if (snapshot == null) {
      return _ShopifySeoEmptyState(
        message: 'No Shopify SEO review snapshot yet.',
        detail:
            'Seed a plug-and-play Example Store snapshot or import a JSON product export. Admin API sync can feed this same review table later.',
        busy: _busy,
        onSeed: _seed,
        onImport: _importJson,
      );
    }

    final analyses = ShopifySeoAnalyzer.analyzeSnapshot(snapshot);
    final products = _filteredProducts(snapshot.products, analyses);
    final selectableIds = snapshot.products
        .where((product) => product.status != 'queued')
        .map((product) => product.id)
        .toSet();
    final allSelected =
        selectableIds.isNotEmpty && selectableIds.every(_selected.contains);
    final avgScore = analyses.isEmpty
        ? 0
        : (analyses.values.map((a) => a.score).reduce((a, b) => a + b) /
                  analyses.length)
              .round();
    final critical = analyses.values.fold<int>(
      0,
      (sum, analysis) => sum + analysis.criticalCount,
    );
    final warnings = analyses.values.fold<int>(
      0,
      (sum, analysis) => sum + analysis.warningCount,
    );
    final missingMeta = analyses.values
        .where(
          (analysis) => analysis.issues.any(
            (issue) => issue.id == 'missing_meta_description',
          ),
        )
        .length;
    final missingAlt = snapshot.products.fold<int>(
      0,
      (sum, product) =>
          sum +
          product.images
              .where((image) => (image.alt ?? '').trim().isEmpty)
              .length,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            MiniPill('Shop', snapshot.shopDomain),
            MiniPill('Products', '${snapshot.products.length}'),
            MiniPill('Avg score', '$avgScore'),
            MiniPill('Critical', '$critical'),
            MiniPill('Warnings', '$warnings'),
            MiniPill('Missing meta', '$missingMeta'),
            MiniPill('Missing alt', '$missingAlt'),
            MiniPill('Queued', '${snapshot.queuedCount}'),
            MiniPill('Synced', compactDateTime(snapshot.syncedAt)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _seed,
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: const Text('Seed sample'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _importJson,
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Import JSON'),
            ),
            PopupMenuButton<String>(
              tooltip: 'Export review',
              onSelected: _busy ? null : _export,
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'json', child: Text('Export JSON')),
                PopupMenuItem(value: 'csv', child: Text('Export CSV')),
                PopupMenuItem(
                  value: 'markdown',
                  child: Text('Export Markdown'),
                ),
              ],
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export'),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy || selectableIds.isEmpty
                  ? null
                  : () {
                      setState(() {
                        if (allSelected) {
                          _selected.removeAll(selectableIds);
                        } else {
                          _selected.addAll(selectableIds);
                        }
                      });
                    },
              icon: Icon(
                allSelected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
              ),
              label: Text(allSelected ? 'Clear products' : 'Select products'),
            ),
            FilledButton.icon(
              onPressed: _busy || _selected.isEmpty ? null : _queueSelected,
              icon: const Icon(Icons.playlist_add_check, size: 16),
              label: Text('Queue ${_selected.length} product batches'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              value: _filter,
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All')),
                DropdownMenuItem(value: 'critical', child: Text('Critical')),
                DropdownMenuItem(
                  value: 'missing_meta',
                  child: Text('Missing title/meta'),
                ),
                DropdownMenuItem(
                  value: 'missing_alt',
                  child: Text('Missing alt text'),
                ),
                DropdownMenuItem(
                  value: 'thin',
                  child: Text('Thin description'),
                ),
                DropdownMenuItem(value: 'low_score', child: Text('Low score')),
                DropdownMenuItem(
                  value: 'not_queued',
                  child: Text('Not queued'),
                ),
                DropdownMenuItem(value: 'queued', child: Text('Queued')),
              ],
              onChanged: (value) => setState(() => _filter = value ?? 'all'),
            ),
            DropdownButton<String>(
              value: _sort,
              items: const [
                DropdownMenuItem(
                  value: 'lowest_score',
                  child: Text('Lowest score'),
                ),
                DropdownMenuItem(
                  value: 'critical_first',
                  child: Text('Most critical'),
                ),
                DropdownMenuItem(value: 'title', child: Text('Product title')),
                DropdownMenuItem(
                  value: 'updated',
                  child: Text('Recently updated'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _sort = value ?? 'lowest_score'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.criticalCount > 0,
              ),
              child: const Text('Select critical'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.issues.any(
                  (issue) =>
                      issue.id == 'missing_meta_description' ||
                      issue.id == 'missing_seo_title',
                ),
              ),
              child: const Text('Select missing meta'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => product.images.any(
                  (image) => (image.alt ?? '').trim().isEmpty,
                ),
              ),
              child: const Text('Select missing alt'),
            ),
            TextButton(
              onPressed: () => _selectMatching(
                snapshot.products,
                analyses,
                (product, analysis) => analysis.score < 70,
              ),
              child: const Text('Select low score'),
            ),
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final product in products) ...[
          _ShopifySeoProductCard(
            product: product,
            analysis: analyses[product.id]!,
            proposalSeed: ShopifySeoAnalyzer.generateProposalSeed(
              product,
              analysis: analyses[product.id],
              shopDomain: snapshot.shopDomain,
              brandName: snapshot.resolvedBrandName,
            ),
            selected: _selected.contains(product.id),
            selectable: product.status != 'queued',
            onSelected: (value) {
              setState(() {
                if (value) {
                  _selected.add(product.id);
                } else {
                  _selected.remove(product.id);
                }
              });
            },
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  void _selectMatching(
    List<ShopifySeoProduct> products,
    Map<String, ShopifySeoAnalysis> analyses,
    bool Function(ShopifySeoProduct product, ShopifySeoAnalysis analysis) match,
  ) {
    setState(() {
      _selected
        ..clear()
        ..addAll(
          products
              .where((product) => product.status != 'queued')
              .where((product) => match(product, analyses[product.id]!))
              .map((product) => product.id),
        );
    });
  }

  List<ShopifySeoProduct> _filteredProducts(
    List<ShopifySeoProduct> products,
    Map<String, ShopifySeoAnalysis> analyses,
  ) {
    final filtered = products.where((product) {
      final analysis = analyses[product.id]!;
      return switch (_filter) {
        'critical' => analysis.criticalCount > 0,
        'missing_meta' => analysis.issues.any(
          (issue) =>
              issue.id == 'missing_meta_description' ||
              issue.id == 'missing_seo_title',
        ),
        'missing_alt' => product.images.any(
          (image) => (image.alt ?? '').trim().isEmpty,
        ),
        'thin' => analysis.issues.any(
          (issue) => issue.id == 'thin_description',
        ),
        'low_score' => analysis.score < 70,
        'not_queued' => product.status != 'queued',
        'queued' => product.status == 'queued',
        _ => true,
      };
    }).toList();
    filtered.sort((a, b) {
      final aa = analyses[a.id]!;
      final bb = analyses[b.id]!;
      return switch (_sort) {
        'critical_first' => bb.criticalCount.compareTo(aa.criticalCount),
        'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        'updated' => (b.updatedAt ?? '').compareTo(a.updatedAt ?? ''),
        _ => aa.score.compareTo(bb.score),
      };
    });
    return filtered;
  }
}

class _ShopifySeoEmptyState extends StatelessWidget {
  final String message;
  final String detail;
  final bool busy;
  final VoidCallback onSeed;
  final VoidCallback onImport;

  const _ShopifySeoEmptyState({
    required this.message,
    required this.detail,
    required this.busy,
    required this.onSeed,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            detail,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : onSeed,
                icon: const Icon(Icons.inventory_2_outlined, size: 16),
                label: const Text('Seed sample'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : onImport,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Import JSON'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShopifySeoProductCard extends StatelessWidget {
  final ShopifySeoProduct product;
  final ShopifySeoAnalysis analysis;
  final ShopifySeoProposalSeed proposalSeed;
  final bool selected;
  final bool selectable;
  final ValueChanged<bool> onSelected;

  const _ShopifySeoProductCard({
    required this.product,
    required this.analysis,
    required this.proposalSeed,
    required this.selected,
    required this.selectable,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AtlasColors>()!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.panel.withAlpha(0x33),
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: selectable
                ? (value) => onSelected(value ?? false)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      product.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    MiniPill('Status', product.status.replaceAll('_', ' ')),
                    MiniPill('Score', '${analysis.score}/100'),
                    MiniPill('Critical', '${analysis.criticalCount}'),
                    MiniPill('Warnings', '${analysis.warningCount}'),
                    if ((product.productType ?? '').isNotEmpty)
                      MiniPill('Type', product.productType!),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '/products/${product.handle}',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 10),
                _SeoFieldRow(
                  label: 'Current title',
                  value: product.currentSeoTitle,
                  fallback: 'Missing',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Current meta',
                  value: product.currentMetaDescription,
                  fallback: 'Missing',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Proposed title',
                  value:
                      product.proposedSeoTitle ?? proposalSeed.proposedSeoTitle,
                  fallback: 'Not staged yet',
                  showCount: true,
                ),
                _SeoFieldRow(
                  label: 'Proposed meta',
                  value:
                      product.proposedMetaDescription ??
                      proposalSeed.proposedMetaDescription,
                  fallback: 'Not staged yet',
                  showCount: true,
                ),
                if (analysis.issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final issue in analysis.issues.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '${issue.severity}: ${issue.message}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text(
                      'Details',
                      style: TextStyle(fontSize: 13),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            MiniPill(
                              'Snippet',
                              '${analysis.breakdown.searchSnippet}/35',
                            ),
                            MiniPill(
                              'Content',
                              '${analysis.breakdown.content}/25',
                            ),
                            MiniPill(
                              'Images',
                              '${analysis.breakdown.imageAltText}/15',
                            ),
                            MiniPill(
                              'URL/tax',
                              '${analysis.breakdown.urlAndTaxonomy}/10',
                            ),
                            MiniPill(
                              'Merchant',
                              '${analysis.breakdown.merchantDataReadiness}/15',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final issue in analysis.issues)
                        _ShopifyIssueRow(issue: issue),
                      if (proposalSeed.warnings.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final warning in proposalSeed.warnings)
                          Text(
                            'Risk note: $warning',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFFFCC80),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeoFieldRow extends StatelessWidget {
  final String label;
  final String? value;
  final String fallback;
  final bool showCount;

  const _SeoFieldRow({
    required this.label,
    required this.value,
    required this.fallback,
    this.showCount = false,
  });

  @override
  Widget build(BuildContext context) {
    final raw = value?.trim();
    final text = raw?.isNotEmpty == true ? raw! : fallback;
    final muted = value?.trim().isNotEmpty != true;
    final display = showCount && !muted ? '$text (${text.length})' : text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
          Expanded(
            child: Text(
              display,
              style: TextStyle(
                fontSize: 12,
                color: muted ? const Color(0x99FFFFFF) : Colors.white70,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopifyIssueRow extends StatelessWidget {
  final ShopifySeoIssue issue;

  const _ShopifyIssueRow({required this.issue});

  @override
  Widget build(BuildContext context) {
    final color = switch (issue.severity) {
      'critical' => const Color(0xFFFF8A80),
      'warning' => const Color(0xFFFFCC80),
      _ => Colors.white60,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${issue.severity.toUpperCase()} · ${issue.field}',
            style: TextStyle(fontSize: 11, color: color),
          ),
          Text(
            issue.message,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          Text(
            issue.suggestedAction,
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}
