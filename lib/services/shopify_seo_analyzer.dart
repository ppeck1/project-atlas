import 'dart:convert';

import 'shopify_seo_review_service.dart';

const shopifySeoAnalysisSchema = 'shopify_seo_analysis_v1';
const minTitleChars = 25;
const preferredTitleMaxChars = 60;
const minMetaChars = 70;
const preferredMetaMaxChars = 160;
const preferredAltMaxChars = 125;

class ShopifySeoAnalysis {
  final int score;
  final ShopifySeoScoreBreakdown breakdown;
  final List<ShopifySeoIssue> issues;
  final List<String> strengths;

  const ShopifySeoAnalysis({
    required this.score,
    required this.breakdown,
    required this.issues,
    required this.strengths,
  });

  int get criticalCount =>
      issues.where((issue) => issue.severity == 'critical').length;
  int get warningCount =>
      issues.where((issue) => issue.severity == 'warning').length;
  int get infoCount => issues.where((issue) => issue.severity == 'info').length;

  Map<String, Object?> toJson() => {
    'schema': shopifySeoAnalysisSchema,
    'score': score,
    'breakdown': breakdown.toJson(),
    'issues': issues.map((issue) => issue.toJson()).toList(),
    'strengths': strengths,
  };
}

class ShopifySeoScoreBreakdown {
  final int searchSnippet;
  final int content;
  final int imageAltText;
  final int urlAndTaxonomy;
  final int merchantDataReadiness;

  const ShopifySeoScoreBreakdown({
    required this.searchSnippet,
    required this.content,
    required this.imageAltText,
    required this.urlAndTaxonomy,
    required this.merchantDataReadiness,
  });

  int get total =>
      searchSnippet +
      content +
      imageAltText +
      urlAndTaxonomy +
      merchantDataReadiness;

  Map<String, Object?> toJson() => {
    'searchSnippet': searchSnippet,
    'content': content,
    'imageAltText': imageAltText,
    'urlAndTaxonomy': urlAndTaxonomy,
    'merchantDataReadiness': merchantDataReadiness,
  };
}

class ShopifySeoIssue {
  final String id;
  final String severity;
  final String category;
  final String field;
  final String message;
  final String evidence;
  final String suggestedAction;

  const ShopifySeoIssue({
    required this.id,
    required this.severity,
    required this.category,
    required this.field,
    required this.message,
    required this.evidence,
    required this.suggestedAction,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'severity': severity,
    'category': category,
    'field': field,
    'message': message,
    'evidence': evidence,
    'suggestedAction': suggestedAction,
  };
}

class ShopifySeoProposalSeed {
  final String proposedSeoTitle;
  final String proposedMetaDescription;
  final String proposedDescriptionOutline;
  final List<ShopifySeoAltTextProposal> proposedAltText;
  final List<String> proposedTags;
  final List<String> warnings;

  const ShopifySeoProposalSeed({
    required this.proposedSeoTitle,
    required this.proposedMetaDescription,
    required this.proposedDescriptionOutline,
    required this.proposedAltText,
    required this.proposedTags,
    required this.warnings,
  });

  Map<String, Object?> toJson() => {
    'proposedSeoTitle': proposedSeoTitle,
    'proposedMetaDescription': proposedMetaDescription,
    'proposedDescriptionOutline': proposedDescriptionOutline,
    'proposedAltText': proposedAltText.map((item) => item.toJson()).toList(),
    'proposedTags': proposedTags,
    'warnings': warnings,
  };
}

class ShopifySeoAltTextProposal {
  final String? imageId;
  final int? position;
  final String alt;
  final String evidence;

  const ShopifySeoAltTextProposal({
    this.imageId,
    this.position,
    required this.alt,
    required this.evidence,
  });

  Map<String, Object?> toJson() => {
    'imageId': imageId,
    'position': position,
    'alt': alt,
    'evidence': evidence,
  };
}

class ShopifySeoReviewExport {
  final String json;
  final String csv;
  final String markdown;

  const ShopifySeoReviewExport({
    required this.json,
    required this.csv,
    required this.markdown,
  });
}

class ShopifySeoAnalyzer {
  static Map<String, ShopifySeoAnalysis> analyzeSnapshot(
    ShopifySeoReviewSnapshot snapshot,
  ) {
    final duplicateMeta = _duplicateValues(
      snapshot.products.map((p) => p.currentMetaDescription),
    );
    final duplicateDescriptions = _duplicateValues(
      snapshot.products.map((p) => _plainText(p.currentDescription)),
    );
    return {
      for (final product in snapshot.products)
        product.id: analyzeProduct(
          product,
          duplicateMetaDescriptions: duplicateMeta,
          duplicateDescriptions: duplicateDescriptions,
          collectionDataAvailable: snapshot.products.any(
            (p) => p.collections.isNotEmpty,
          ),
        ),
    };
  }

  static ShopifySeoAnalysis analyzeProduct(
    ShopifySeoProduct product, {
    Set<String> duplicateMetaDescriptions = const {},
    Set<String> duplicateDescriptions = const {},
    bool collectionDataAvailable = false,
  }) {
    final issues = <ShopifySeoIssue>[];
    final strengths = <String>[];
    _snippetIssues(product, duplicateMetaDescriptions, issues, strengths);
    _contentIssues(product, duplicateDescriptions, issues, strengths);
    _imageIssues(product, issues, strengths);
    _urlTaxonomyIssues(product, collectionDataAvailable, issues, strengths);
    _merchantIssues(product, issues, strengths);
    final breakdown = ShopifySeoScoreBreakdown(
      searchSnippet: _score(35, issues, 'snippet'),
      content: _score(25, issues, 'content'),
      imageAltText: _score(15, issues, 'image'),
      urlAndTaxonomy: _score(10, issues, 'url', also: {'taxonomy'}),
      merchantDataReadiness: _score(15, issues, 'merchant'),
    );
    return ShopifySeoAnalysis(
      score: breakdown.total.clamp(0, 100),
      breakdown: breakdown,
      issues: issues,
      strengths: strengths,
    );
  }

  static ShopifySeoProposalSeed generateProposalSeed(
    ShopifySeoProduct product, {
    ShopifySeoAnalysis? analysis,
    required String shopDomain,
    String? brandName,
  }) {
    final brand =
        _clean(brandName) ?? _brandFromDomain(shopDomain) ?? 'Sinternet Cult';
    final productType = _clean(product.productType);
    final titleBase = _dedupeWords(product.title);
    final seoTitle =
        productType == null ||
            product.title.toLowerCase().contains(productType.toLowerCase())
        ? '$titleBase | $brand'
        : '$titleBase - $productType | $brand';
    final descriptionParts = <String>[
      titleBase,
      if (productType != null) productType.toLowerCase(),
      if (product.tags.isNotEmpty)
        product.tags
            .take(3)
            .where((tag) => !_genericTags.contains(tag))
            .join(', '),
    ].where((part) => part.trim().isNotEmpty).toList();
    final descriptor = descriptionParts.join(' - ');
    final meta = descriptor.isEmpty
        ? 'Shop ${product.title} from $brand.'
        : 'Shop ${product.title} from $brand, a $descriptor for online-culture style.';
    final outline = [
      'Lead with what the product is: ${product.title}.',
      if (productType != null) 'Mention product type: $productType.',
      if (product.tags.isNotEmpty)
        'Use available style/use-case terms only: ${product.tags.take(5).join(', ')}.',
      'Avoid claims about materials, shipping speed, authenticity, origin, or exclusivity unless imported data supports them.',
    ].join('\n');
    final alt = product.images
        .map(
          (image) => ShopifySeoAltTextProposal(
            imageId: image.id,
            position: image.position,
            alt: _limit(
              '$titleBase${productType == null ? '' : ' $productType'}',
              preferredAltMaxChars,
            ),
            evidence: 'Uses imported product title/type only.',
          ),
        )
        .toList(growable: false);
    final tags = <String>{
      ...product.tags,
      if (productType != null) productType.toLowerCase(),
      brand.toLowerCase(),
    }.where((tag) => tag.trim().isNotEmpty).take(12).toList(growable: false);
    final warnings = <String>[
      if (_plainText(product.currentDescription).length < 80 ||
          product.images.isEmpty ||
          product.variants.isEmpty)
        'Imported data is thin; keep proposal factual and avoid rich dropship claims.',
      for (final issue in (analysis ?? analyzeProduct(product)).issues)
        if (issue.id == 'unsupported_claims') issue.message,
    ];
    return ShopifySeoProposalSeed(
      proposedSeoTitle: _limit(seoTitle, preferredTitleMaxChars),
      proposedMetaDescription: _limit(meta, preferredMetaMaxChars),
      proposedDescriptionOutline: outline,
      proposedAltText: alt,
      proposedTags: tags,
      warnings: warnings,
    );
  }

  static ShopifySeoReviewExport buildExport(ShopifySeoReviewSnapshot snapshot) {
    final analyses = analyzeSnapshot(snapshot);
    final json = const JsonEncoder.withIndent('  ').convert({
      'schema': 'shopify_seo_review_export_v1',
      'snapshot': snapshot.toJson(),
      'analysis': analyses.map(
        (id, analysis) => MapEntry(id, analysis.toJson()),
      ),
      'proposalSeeds': {
        for (final product in snapshot.products)
          product.id: generateProposalSeed(
            product,
            analysis: analyses[product.id],
            shopDomain: snapshot.shopDomain,
            brandName: snapshot.resolvedBrandName,
          ).toJson(),
      },
    });
    final csv = _csv(snapshot, analyses);
    final markdown = _markdown(snapshot, analyses);
    return ShopifySeoReviewExport(json: json, csv: csv, markdown: markdown);
  }

  static void _snippetIssues(
    ShopifySeoProduct product,
    Set<String> duplicates,
    List<ShopifySeoIssue> issues,
    List<String> strengths,
  ) {
    final title = _clean(product.currentSeoTitle);
    final meta = _clean(product.currentMetaDescription);
    if (title == null) {
      issues.add(
        _issue(
          'missing_seo_title',
          'critical',
          'snippet',
          'seo.title',
          'Missing SEO title.',
          'No SEO title was imported.',
          'Write a concise product-specific SEO title.',
        ),
      );
    } else {
      if (title.length < minTitleChars) {
        issues.add(
          _issue(
            'seo_title_short',
            'warning',
            'snippet',
            'seo.title',
            'SEO title has preview risk because it is probably too short.',
            '${title.length} chars: "$title"',
            'Add brand or product differentiator.',
          ),
        );
      }
      if (title.length > preferredTitleMaxChars) {
        issues.add(
          _issue(
            'seo_title_long',
            'warning',
            'snippet',
            'seo.title',
            'SEO title has preview risk because it is probably too long.',
            '${title.length} chars.',
            'Shorten while preserving product identity.',
          ),
        );
      }
      if (_normalize(title) == _normalize(product.title)) {
        issues.add(
          _issue(
            'seo_title_duplicates_product_title',
            'warning',
            'snippet',
            'seo.title',
            'SEO title duplicates product title without brand or differentiator.',
            title,
            'Add brand or product type without keyword stuffing.',
          ),
        );
      }
      if (_keywordStuffed(title)) {
        issues.add(
          _issue(
            'seo_title_keyword_stuffed',
            'warning',
            'snippet',
            'seo.title',
            'SEO title appears keyword-stuffed.',
            title,
            'Use natural product wording and remove repeated terms.',
          ),
        );
      }
      strengths.add('SEO title present.');
    }
    if (meta == null) {
      issues.add(
        _issue(
          'missing_meta_description',
          'critical',
          'snippet',
          'seo.description',
          'Missing meta description.',
          'No meta description was imported.',
          'Write a human-readable product snippet.',
        ),
      );
    } else {
      if (meta.length < minMetaChars) {
        issues.add(
          _issue(
            'meta_description_short',
            'warning',
            'snippet',
            'seo.description',
            'Meta description has snippet risk because it is probably too short.',
            '${meta.length} chars.',
            'Add product type, audience, and clear buyer-facing detail.',
          ),
        );
      }
      if (meta.length > preferredMetaMaxChars) {
        issues.add(
          _issue(
            'meta_description_long',
            'warning',
            'snippet',
            'seo.description',
            'Meta description has snippet risk because it is probably too long.',
            '${meta.length} chars.',
            'Trim to the clearest product-specific summary.',
          ),
        );
      }
      if (duplicates.contains(_normalize(meta))) {
        issues.add(
          _issue(
            'duplicate_meta_description',
            'warning',
            'snippet',
            'seo.description',
            'Meta description duplicates another product.',
            meta,
            'Write a product-specific snippet.',
          ),
        );
      }
      if (_keywordList(meta)) {
        issues.add(
          _issue(
            'meta_description_keyword_list',
            'warning',
            'snippet',
            'seo.description',
            'Meta description is only a keyword list.',
            meta,
            'Rewrite as a readable sentence.',
          ),
        );
      }
      final type = _clean(product.productType);
      if (type != null && !meta.toLowerCase().contains(type.toLowerCase())) {
        issues.add(
          _issue(
            'meta_missing_product_type',
            'info',
            'snippet',
            'seo.description',
            'Meta description does not mention product type.',
            'Product type: $type',
            'Mention the product type naturally.',
          ),
        );
      }
      strengths.add('Meta description present.');
    }
  }

  static void _contentIssues(
    ShopifySeoProduct product,
    Set<String> duplicates,
    List<ShopifySeoIssue> issues,
    List<String> strengths,
  ) {
    final plain = _plainText(product.currentDescription);
    if (plain.isEmpty) {
      issues.add(
        _issue(
          'missing_description',
          'critical',
          'content',
          'body_html',
          'Missing product description.',
          'No body/description text was imported.',
          'Add buyer-facing product description.',
        ),
      );
      return;
    }
    if (plain.length < 90) {
      issues.add(
        _issue(
          'thin_description',
          'warning',
          'content',
          'body_html',
          'Product description has thin content risk after HTML stripping.',
          '${plain.length} chars.',
          'Expand with factual buyer-facing product details.',
        ),
      );
    }
    if (duplicates.contains(_normalize(plain))) {
      issues.add(
        _issue(
          'boilerplate_description',
          'warning',
          'content',
          'body_html',
          'Product description appears copied across products.',
          plain,
          'Make the description product-specific.',
        ),
      );
    }
    if (!_hasBuyerDetail(plain)) {
      issues.add(
        _issue(
          'missing_buyer_details',
          'warning',
          'content',
          'body_html',
          'Description lacks buyer-facing details.',
          plain,
          'Describe fit, style, use case, or visual design using imported data only.',
        ),
      );
    }
    final type = _clean(product.productType);
    if (type != null && !plain.toLowerCase().contains(type.toLowerCase())) {
      issues.add(
        _issue(
          'description_missing_product_type',
          'info',
          'content',
          'body_html',
          'Description lacks product type/aesthetic/use-case terms.',
          'Product type: $type',
          'Mention product type naturally.',
        ),
      );
    }
    if (_unsupportedClaims(plain)) {
      issues.add(
        _issue(
          'unsupported_claims',
          'critical',
          'governance',
          'body_html',
          'Description contains claims that may be unsupported by imported data.',
          plain,
          'Remove or verify shipping, health, affiliation, material, origin, authenticity, or exclusivity claims.',
        ),
      );
    }
    strengths.add('Product description present.');
  }

  static void _imageIssues(
    ShopifySeoProduct product,
    List<ShopifySeoIssue> issues,
    List<String> strengths,
  ) {
    if (product.images.isEmpty) {
      issues.add(
        _issue(
          'missing_images',
          'critical',
          'image',
          'images',
          'Product has no images.',
          'No image/media rows were imported.',
          'Add at least one product image before rich SEO work.',
        ),
      );
      return;
    }
    final alts = <String>[];
    for (final image in product.images) {
      final alt = _clean(image.alt);
      if (alt == null) {
        issues.add(
          _issue(
            'missing_image_alt',
            'warning',
            'image',
            'images.alt',
            'Image is missing alt text.',
            'Image ${image.id ?? image.position ?? ''}',
            'Add concise visible-product alt text.',
          ),
        );
      } else {
        alts.add(_normalize(alt));
        if (alt.length > preferredAltMaxChars) {
          issues.add(
            _issue(
              'image_alt_long',
              'warning',
              'image',
              'images.alt',
              'Image alt text is long for practical Shopify use.',
              '${alt.length} chars.',
              'Keep alt text under about 125 characters.',
            ),
          );
        }
        if (_genericAlt.contains(_normalize(alt))) {
          issues.add(
            _issue(
              'generic_image_alt',
              'warning',
              'image',
              'images.alt',
              'Image alt text is too generic.',
              alt,
              'Describe the visible product more specifically.',
            ),
          );
        }
      }
    }
    if (_duplicateValues(alts).isNotEmpty) {
      issues.add(
        _issue(
          'duplicate_image_alt',
          'info',
          'image',
          'images.alt',
          'Multiple images use the same alt text.',
          alts.join(', '),
          'Use image-specific alt text where images differ.',
        ),
      );
    }
    strengths.add('Product image data present.');
  }

  static void _urlTaxonomyIssues(
    ShopifySeoProduct product,
    bool collectionDataAvailable,
    List<ShopifySeoIssue> issues,
    List<String> strengths,
  ) {
    final handle = _clean(product.handle);
    if (handle == null) {
      issues.add(
        _issue(
          'missing_handle',
          'critical',
          'url',
          'handle',
          'Missing handle.',
          'No product handle was imported.',
          'Set a readable product URL handle.',
        ),
      );
    } else {
      if (RegExp(r'(^|[-_])[a-f0-9]{8,}($|[-_])').hasMatch(handle) ||
          RegExp(r'\d{5,}').hasMatch(handle)) {
        issues.add(
          _issue(
            'random_handle',
            'warning',
            'url',
            'handle',
            'Handle appears to contain random IDs or low-information slug parts.',
            handle,
            'Use readable product words in the handle.',
          ),
        );
      }
      final titleWords = _meaningfulWords(product.title);
      final handleWords = _meaningfulWords(handle.replaceAll('-', ' '));
      if (titleWords.isNotEmpty &&
          titleWords.intersection(handleWords).isEmpty) {
        issues.add(
          _issue(
            'handle_missing_product_words',
            'warning',
            'url',
            'handle',
            'Handle does not contain meaningful product words.',
            handle,
            'Align handle with product title.',
          ),
        );
      }
    }
    if (_clean(product.productType) == null) {
      issues.add(
        _issue(
          'missing_product_type',
          'warning',
          'taxonomy',
          'product_type',
          'Missing product type.',
          'No product type imported.',
          'Add Shopify product type for grouping and snippets.',
        ),
      );
    }
    if (_clean(product.vendor) == null) {
      issues.add(
        _issue(
          'missing_vendor',
          'warning',
          'taxonomy',
          'vendor',
          'Missing vendor.',
          'No vendor imported.',
          'Add vendor/brand data.',
        ),
      );
    }
    if (product.tags.isEmpty) {
      issues.add(
        _issue(
          'missing_tags',
          'warning',
          'taxonomy',
          'tags',
          'Missing tags.',
          'No tags imported.',
          'Add useful non-generic product tags.',
        ),
      );
    } else if (product.tags.every(
      (tag) => _genericTags.contains(_normalize(tag)),
    )) {
      issues.add(
        _issue(
          'generic_tags',
          'info',
          'taxonomy',
          'tags',
          'Tags are too generic.',
          product.tags.join(', '),
          'Add product-specific style/use-case tags.',
        ),
      );
    }
    if (collectionDataAvailable && product.collections.isEmpty) {
      issues.add(
        _issue(
          'missing_collections',
          'info',
          'taxonomy',
          'collections',
          'Product is not assigned to a collection in imported data.',
          'Collection data exists elsewhere in import.',
          'Review collection assignment.',
        ),
      );
    }
    strengths.add('URL/taxonomy data partially available.');
  }

  static void _merchantIssues(
    ShopifySeoProduct product,
    List<ShopifySeoIssue> issues,
    List<String> strengths,
  ) {
    if (product.variants.isEmpty) {
      issues.add(
        _issue(
          'missing_variants',
          'warning',
          'merchant',
          'variants',
          'No variant data imported for merchant/schema readiness.',
          'variants[] empty.',
          'Import variant price/SKU/availability data when available.',
        ),
      );
    }
    for (final variant in product.variants) {
      if (_clean(variant.price) == null) {
        issues.add(
          _issue(
            'missing_variant_price',
            'warning',
            'merchant',
            'variants.price',
            'Variant price is missing.',
            variant.title ?? variant.id ?? '',
            'Import price for future Merchant Center/schema readiness.',
          ),
        );
      }
      if (_clean(variant.sku) == null) {
        issues.add(
          _issue(
            'missing_variant_sku',
            'info',
            'merchant',
            'variants.sku',
            'Variant SKU is missing.',
            variant.title ?? variant.id ?? '',
            'Add SKU if available.',
          ),
        );
      }
      if (_clean(variant.barcode) == null) {
        issues.add(
          _issue(
            'missing_variant_barcode',
            'info',
            'merchant',
            'variants.barcode',
            'Variant barcode/GTIN is missing.',
            variant.title ?? variant.id ?? '',
            'Add GTIN/barcode if available.',
          ),
        );
      }
      if (variant.availableForSale == null) {
        issues.add(
          _issue(
            'missing_availability',
            'warning',
            'merchant',
            'variants.availableForSale',
            'Availability-like signal is missing.',
            variant.title ?? variant.id ?? '',
            'Import availability for future merchant readiness.',
          ),
        );
      }
      if (product.variants.length > 1 &&
          _clean(variant.option1) == null &&
          _clean(variant.option2) == null &&
          _clean(variant.option3) == null) {
        issues.add(
          _issue(
            'missing_variant_options',
            'info',
            'merchant',
            'variants.options',
            'Variant option names are missing.',
            variant.title ?? variant.id ?? '',
            'Import option values for variant clarity.',
          ),
        );
      }
    }
    if (product.images.isEmpty) {
      issues.add(
        _issue(
          'merchant_missing_image',
          'critical',
          'merchant',
          'images',
          'Missing product image for merchant/schema readiness.',
          'No image imported.',
          'Add image data before Merchant Center work.',
        ),
      );
    }
    final title = _clean(product.currentSeoTitle);
    if (title != null &&
        !_meaningfulWords(
          product.title,
        ).intersection(_meaningfulWords(title)).isNotEmpty) {
      issues.add(
        _issue(
          'title_handle_seo_mismatch',
          'warning',
          'merchant',
          'seo.title',
          'Product title, handle, and SEO title appear mismatched.',
          'Product: ${product.title}; SEO title: $title; handle: ${product.handle}',
          'Align product identity across title, handle, and SEO title.',
        ),
      );
    }
    strengths.add('Merchant readiness checked without theme/schema edits.');
  }

  static int _score(
    int max,
    List<ShopifySeoIssue> issues,
    String category, {
    Set<String> also = const {},
  }) {
    final cats = {category, ...also};
    final penalty = issues
        .where((issue) => cats.contains(issue.category))
        .fold<int>(
          0,
          (sum, issue) =>
              sum +
              switch (issue.severity) {
                'critical' => 12,
                'warning' => 6,
                _ => 2,
              },
        );
    return (max - penalty).clamp(0, max);
  }

  static ShopifySeoIssue _issue(
    String id,
    String severity,
    String category,
    String field,
    String message,
    String evidence,
    String suggestedAction,
  ) => ShopifySeoIssue(
    id: id,
    severity: severity,
    category: category,
    field: field,
    message: message,
    evidence: evidence,
    suggestedAction: suggestedAction,
  );
}

String _csv(
  ShopifySeoReviewSnapshot snapshot,
  Map<String, ShopifySeoAnalysis> analyses,
) {
  final rows = <List<String>>[
    [
      'product_id',
      'handle',
      'title',
      'status',
      'score',
      'critical_issues',
      'warning_issues',
      'current_seo_title',
      'current_meta_description',
      'proposed_seo_title',
      'proposed_meta_description',
      'missing_alt_count',
      'thin_description',
      'queued',
    ],
    for (final product in snapshot.products)
      [
        product.id,
        product.handle,
        product.title,
        product.status,
        '${analyses[product.id]?.score ?? 0}',
        '${analyses[product.id]?.criticalCount ?? 0}',
        '${analyses[product.id]?.warningCount ?? 0}',
        product.currentSeoTitle ?? '',
        product.currentMetaDescription ?? '',
        product.proposedSeoTitle ?? '',
        product.proposedMetaDescription ?? '',
        '${product.images.where((image) => _clean(image.alt) == null).length}',
        '${analyses[product.id]?.issues.any((i) => i.id == 'thin_description') ?? false}',
        '${product.status == 'queued'}',
      ],
  ];
  return rows.map((row) => row.map(_csvCell).join(',')).join('\n');
}

String _markdown(
  ShopifySeoReviewSnapshot snapshot,
  Map<String, ShopifySeoAnalysis> analyses,
) {
  final b = StringBuffer()
    ..writeln('# Shopify SEO Review')
    ..writeln()
    ..writeln('- Shop: ${snapshot.shopDomain}')
    ..writeln('- Products: ${snapshot.products.length}')
    ..writeln();
  for (final product in snapshot.products) {
    final analysis = analyses[product.id]!;
    b
      ..writeln('## ${product.title}')
      ..writeln()
      ..writeln('- Handle: `${product.handle}`')
      ..writeln('- Status: `${product.status}`')
      ..writeln('- SEO score: ${analysis.score}/100')
      ..writeln('- Critical issues: ${analysis.criticalCount}')
      ..writeln('- Warnings: ${analysis.warningCount}')
      ..writeln()
      ..writeln('Top issues:');
    for (final issue in analysis.issues.take(5)) {
      b.writeln('- ${issue.severity}: ${issue.message}');
    }
    b.writeln();
  }
  return b.toString();
}

String _csvCell(String value) {
  final escaped = value.replaceAll('"', '""');
  return RegExp(r'[",\n]').hasMatch(escaped) ? '"$escaped"' : escaped;
}

Set<String> _duplicateValues(Iterable<String?> values) {
  final seen = <String>{};
  final dupes = <String>{};
  for (final value in values) {
    final normalized = _normalize(value ?? '');
    if (normalized.isEmpty) continue;
    if (!seen.add(normalized)) dupes.add(normalized);
  }
  return dupes;
}

String _plainText(String? html) => (html ?? '')
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _clean(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

bool _keywordStuffed(String value) {
  final words = _meaningfulWords(value).toList();
  if (words.length < 5) return false;
  final counts = <String, int>{};
  for (final word in words) {
    counts[word] = (counts[word] ?? 0) + 1;
  }
  return counts.values.any((count) => count >= 3);
}

bool _keywordList(String value) {
  if (!value.contains(',')) return false;
  final sentenceSignals = RegExp(
    r'\b(the|for|with|from|shop|made)\b',
    caseSensitive: false,
  );
  return !sentenceSignals.hasMatch(value) && value.split(',').length >= 4;
}

bool _hasBuyerDetail(String value) {
  final lower = value.toLowerCase();
  return [
    'wear',
    'fit',
    'style',
    'graphic',
    'soft',
    'display',
    'use',
    'gift',
    'hoodie',
    'tee',
    'shirt',
    'poster',
  ].any(lower.contains);
}

bool _unsupportedClaims(String value) {
  final lower = value.toLowerCase();
  return [
    'guaranteed delivery',
    'cures ',
    'heals ',
    'official ',
    'licensed ',
    '100% cotton',
    'made in usa',
    'authentic ',
    'exclusive ',
  ].any(lower.contains);
}

Set<String> _meaningfulWords(String value) => _normalize(value)
    .split(' ')
    .where((word) => word.length > 2 && !_stopWords.contains(word))
    .toSet();

String _dedupeWords(String value) {
  final seen = <String>{};
  final words = value.split(RegExp(r'\s+'));
  return [
    for (final word in words)
      if (seen.add(word.toLowerCase())) word,
  ].join(' ');
}

String _limit(String value, int max) =>
    value.length <= max ? value : value.substring(0, max).trimRight();

String? _brandFromDomain(String domain) {
  final host = domain
      .toLowerCase()
      .replaceFirst(RegExp(r'^https?://'), '')
      .split('/')
      .first
      .replaceFirst(RegExp(r'^www\.'), '');
  final stem = host.split('.').first;
  if (stem == 'sinternetcult') return 'Sinternet Cult';
  if (stem.isEmpty) return null;
  return stem
      .split(RegExp(r'[-_]+'))
      .map(
        (part) =>
            part.isEmpty ? part : part[0].toUpperCase() + part.substring(1),
      )
      .join(' ');
}

const _stopWords = {'the', 'and', 'for', 'with', 'from', 'this', 'that'};

const _genericAlt = {'image', 'product', 'shirt', 'photo', 'picture'};
const _genericTags = {'shirt', 'product', 'apparel', 'clothing', 'dropship'};
