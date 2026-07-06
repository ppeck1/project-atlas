import 'dart:convert';

import 'shopify_seo_analyzer.dart';

const shopifySeoReviewDraftKind = 'shopify_seo_review';

class ShopifySeoReviewSnapshot {
  final String shopDomain;
  final String source;
  final DateTime syncedAt;
  final List<ShopifySeoProduct> products;

  const ShopifySeoReviewSnapshot({
    required this.shopDomain,
    required this.source,
    required this.syncedAt,
    required this.products,
  });

  int get needsReviewCount =>
      products.where((product) => product.status == 'needs_review').length;
  int get stagedCount =>
      products.where((product) => product.status == 'staged').length;
  int get queuedCount =>
      products.where((product) => product.status == 'queued').length;
  int get approvedCount =>
      products.where((product) => product.status == 'approved').length;

  Map<String, Object?> toJson() => {
    'schema': 'shopify_seo_review_snapshot_v2',
    'shopDomain': shopDomain,
    'source': source,
    'syncedAt': syncedAt.toIso8601String(),
    'products': products.map((product) => product.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  String summaryMarkdown() {
    final analyses = ShopifySeoAnalyzer.analyzeSnapshot(this);
    final avg = analyses.isEmpty
        ? 0
        : (analyses.values.map((item) => item.score).reduce((a, b) => a + b) /
                  analyses.length)
              .round();
    final critical = analyses.values.fold<int>(
      0,
      (sum, analysis) =>
          sum + analysis.issues.where((i) => i.severity == 'critical').length,
    );
    final warnings = analyses.values.fold<int>(
      0,
      (sum, analysis) =>
          sum + analysis.issues.where((i) => i.severity == 'warning').length,
    );
    return [
      'Shopify SEO review snapshot',
      '',
      '- shop: $shopDomain',
      '- source: $source',
      '- syncedAt: ${syncedAt.toIso8601String()}',
      '- products: ${products.length}',
      '- averageScore: $avg',
      '- criticalIssues: $critical',
      '- warningIssues: $warnings',
      '- needsReview: $needsReviewCount',
      '- staged: $stagedCount',
      '- queued: $queuedCount',
      '- approved: $approvedCount',
    ].join('\n');
  }

  ShopifySeoReviewSnapshot markQueued(Set<String> productIds) {
    if (productIds.isEmpty) return this;
    return ShopifySeoReviewSnapshot(
      shopDomain: shopDomain,
      source: source,
      syncedAt: DateTime.now(),
      products: products
          .map(
            (product) => productIds.contains(product.id)
                ? product.copyWith(status: 'queued')
                : product,
          )
          .toList(growable: false),
    );
  }

  static ShopifySeoReviewSnapshot decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return fromJson({
        'shopDomain': 'sinternetcult.com',
        'source': 'imported_json',
        'syncedAt': DateTime.now().toIso8601String(),
        'products': decoded,
      });
    }
    if (decoded is! Map) {
      throw const FormatException('Shopify SEO review JSON must be an object.');
    }
    return fromJson(decoded.map((key, value) => MapEntry('$key', value)));
  }

  static ShopifySeoReviewSnapshot fromJson(Map<String, Object?> json) {
    final productsRaw = json['products'];
    if (productsRaw is! List) {
      throw const FormatException('Shopify SEO review requires products[].');
    }
    return ShopifySeoReviewSnapshot(
      shopDomain: stringValue(json['shopDomain']) ?? 'sinternetcult.com',
      source: stringValue(json['source']) ?? 'shopify_admin_api_stub',
      syncedAt:
          DateTime.tryParse(stringValue(json['syncedAt']) ?? '') ??
          DateTime.now(),
      products: productsRaw
          .whereType<Map>()
          .map(
            (product) => ShopifySeoProduct.fromJson(
              product.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false),
    );
  }

  static ShopifySeoReviewSnapshot sampleSinternetCult() {
    final now = DateTime.now();
    return ShopifySeoReviewSnapshot(
      shopDomain: 'sinternetcult.com',
      source: 'shopify_admin_api_stub',
      syncedAt: now,
      products: const [
        ShopifySeoProduct(
          id: 'gid://shopify/Product/demo-001',
          handle: 'internet-cult-core-tee',
          title: 'Internet Cult Core Tee',
          status: 'needs_review',
          productType: 'Apparel',
          vendor: 'Sinternet Cult',
          tags: ['streetwear', 'tee', 'dropship'],
          collections: ['Tees'],
          currentSeoTitle: '',
          currentMetaDescription: '',
          currentDescription:
              'Graphic tee for the extremely online and spiritually unwell.',
          proposedSeoTitle: 'Internet Cult Core Tee | Sinternet Cult',
          proposedMetaDescription:
              'Shop the Internet Cult Core Tee from Sinternet Cult, a graphic streetwear shirt for extremely online chaos.',
          proposedDescription:
              'A graphic tee for extremely online streetwear fans, built as a first SEO review placeholder until Shopify sync is connected.',
          images: [
            ShopifySeoImage(
              id: 'demo-img-001',
              src:
                  'https://sinternetcult.com/products/internet-cult-core-tee.png',
              alt: '',
              width: 1200,
              height: 1200,
              position: 1,
            ),
          ],
          variants: [
            ShopifySeoVariant(
              id: 'demo-var-001',
              title: 'Default Title',
              sku: '',
              price: '29.99',
              availableForSale: true,
            ),
          ],
          issueNotes: [
            'Missing SEO title',
            'Missing meta description',
            'Description needs buyer-facing keywords',
          ],
        ),
        ShopifySeoProduct(
          id: 'gid://shopify/Product/demo-002',
          handle: 'doomscroll-recovery-hoodie',
          title: 'Doomscroll Recovery Hoodie',
          status: 'needs_review',
          productType: 'Apparel',
          vendor: 'Sinternet Cult',
          tags: ['hoodie', 'streetwear', 'comfort'],
          collections: ['Hoodies'],
          currentSeoTitle: 'Doomscroll Hoodie',
          currentMetaDescription: '',
          currentDescription:
              'Soft hoodie for logging off without actually logging off.',
          proposedSeoTitle: 'Doomscroll Recovery Hoodie | Sinternet Cult',
          proposedMetaDescription:
              'A soft graphic hoodie for internet culture, comfort, and late-night scrolling recovery.',
          proposedDescription:
              'A comfort-first graphic hoodie with internet culture styling and search-ready copy for streetwear shoppers.',
          images: [
            ShopifySeoImage(
              id: 'demo-img-002',
              src:
                  'https://sinternetcult.com/products/doomscroll-recovery-hoodie.png',
              alt: 'Doomscroll Recovery Hoodie',
              width: 1200,
              height: 1200,
              position: 1,
            ),
          ],
          variants: [
            ShopifySeoVariant(
              id: 'demo-var-002',
              title: 'Default Title',
              sku: 'SC-HOODIE-001',
              price: '54.99',
              availableForSale: true,
            ),
          ],
          issueNotes: [
            'Meta description missing',
            'SEO title can include brand',
          ],
        ),
      ],
    );
  }
}

class ShopifySeoProduct {
  final String id;
  final String handle;
  final String title;
  final String status;
  final String? productType;
  final String? vendor;
  final List<String> tags;
  final String? currentSeoTitle;
  final String? currentMetaDescription;
  final String? currentDescription;
  final String? proposedSeoTitle;
  final String? proposedMetaDescription;
  final String? proposedDescription;
  final List<String> issueNotes;
  final List<ShopifySeoImage> images;
  final List<ShopifySeoVariant> variants;
  final List<String> collections;
  final String? onlineStoreUrl;
  final String? canonicalUrl;
  final String? publishedAt;
  final String? updatedAt;

  const ShopifySeoProduct({
    required this.id,
    required this.handle,
    required this.title,
    required this.status,
    this.productType,
    this.vendor,
    this.tags = const [],
    this.currentSeoTitle,
    this.currentMetaDescription,
    this.currentDescription,
    this.proposedSeoTitle,
    this.proposedMetaDescription,
    this.proposedDescription,
    this.issueNotes = const [],
    this.images = const [],
    this.variants = const [],
    this.collections = const [],
    this.onlineStoreUrl,
    this.canonicalUrl,
    this.publishedAt,
    this.updatedAt,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'handle': handle,
    'title': title,
    'status': status,
    'productType': productType,
    'vendor': vendor,
    'tags': tags,
    'currentSeoTitle': currentSeoTitle,
    'currentMetaDescription': currentMetaDescription,
    'currentDescription': currentDescription,
    'proposedSeoTitle': proposedSeoTitle,
    'proposedMetaDescription': proposedMetaDescription,
    'proposedDescription': proposedDescription,
    'issueNotes': issueNotes,
    'images': images.map((image) => image.toJson()).toList(),
    'variants': variants.map((variant) => variant.toJson()).toList(),
    'collections': collections,
    'onlineStoreUrl': onlineStoreUrl,
    'canonicalUrl': canonicalUrl,
    'publishedAt': publishedAt,
    'updatedAt': updatedAt,
  };

  Map<String, Object?> toBatchContext({required String shopDomain}) {
    final analysis = ShopifySeoAnalyzer.analyzeProduct(this);
    final proposalSeed = ShopifySeoAnalyzer.generateProposalSeed(
      this,
      analysis: analysis,
      shopDomain: shopDomain,
    );
    return {
      'source': 'shopify_seo_review',
      'approvalUnit': 'product',
      'shopDomain': shopDomain,
      'product': toJson(),
      'seoAnalysis': analysis.toJson(),
      'proposalSeed': proposalSeed.toJson(),
      'requiredOutputSchema': {
        'seoTitle': 'string',
        'metaDescription': 'string',
        'bodyHtml': 'string',
        'imageAltText': <Object?>[],
        'tags': <Object?>[],
        'evidence': <Object?>[],
        'riskNotes': <Object?>[],
      },
      'allowedFields': [
        'seo.title',
        'seo.description',
        'body_html',
        'tags',
        'images.alt',
      ],
      'forbiddenFields': [
        'price',
        'inventory',
        'variants',
        'vendor',
        'product_type',
        'status',
        'published_scope',
      ],
      'writePolicy': 'stage_only_until_user_approved',
    };
  }

  ShopifySeoProduct copyWith({String? status}) => ShopifySeoProduct(
    id: id,
    handle: handle,
    title: title,
    status: status ?? this.status,
    productType: productType,
    vendor: vendor,
    tags: tags,
    currentSeoTitle: currentSeoTitle,
    currentMetaDescription: currentMetaDescription,
    currentDescription: currentDescription,
    proposedSeoTitle: proposedSeoTitle,
    proposedMetaDescription: proposedMetaDescription,
    proposedDescription: proposedDescription,
    issueNotes: issueNotes,
    images: images,
    variants: variants,
    collections: collections,
    onlineStoreUrl: onlineStoreUrl,
    canonicalUrl: canonicalUrl,
    publishedAt: publishedAt,
    updatedAt: updatedAt,
  );

  static ShopifySeoProduct fromJson(Map<String, Object?> json) {
    final node = _firstMap(json['node']) ?? json;
    final id =
        stringValue(node['id']) ??
        stringValue(node['admin_graphql_api_id']) ??
        stringValue(node['legacyResourceId']);
    final handle = stringValue(node['handle']);
    final title = stringValue(node['title']);
    if ((id == null || id.isEmpty) &&
        (handle == null || handle.isEmpty) &&
        (title == null || title.isEmpty)) {
      throw const FormatException('Product requires id, handle, or title.');
    }
    final seoMap = _firstMap(node['seo']);
    final proposalMap = _firstMap(node['proposal']);
    final description =
        stringValue(node['currentDescription']) ??
        stringValue(node['body_html']) ??
        stringValue(node['bodyHtml']) ??
        stringValue(node['descriptionHtml']) ??
        stringValue(node['description']);
    return ShopifySeoProduct(
      id: id ?? handle ?? title!,
      handle: handle ?? _slug(title ?? id!),
      title: title ?? handle ?? id!,
      status: stringValue(node['status']) ?? 'needs_review',
      productType:
          stringValue(node['productType']) ?? stringValue(node['product_type']),
      vendor: stringValue(node['vendor']),
      tags: stringList(node['tags']),
      currentSeoTitle:
          stringValue(node['currentSeoTitle']) ??
          stringValue(seoMap?['title']) ??
          stringValue(node['metafields_global_title_tag']),
      currentMetaDescription:
          stringValue(node['currentMetaDescription']) ??
          stringValue(seoMap?['description']) ??
          stringValue(node['metafields_global_description_tag']),
      currentDescription: description,
      proposedSeoTitle:
          stringValue(node['proposedSeoTitle']) ??
          stringValue(proposalMap?['seoTitle']),
      proposedMetaDescription:
          stringValue(node['proposedMetaDescription']) ??
          stringValue(proposalMap?['metaDescription']),
      proposedDescription:
          stringValue(node['proposedDescription']) ??
          stringValue(proposalMap?['description']),
      issueNotes: stringList(node['issueNotes']),
      images: _decodeImages(node),
      variants: _decodeVariants(node),
      collections: _decodeCollections(node),
      onlineStoreUrl:
          stringValue(node['onlineStoreUrl']) ??
          stringValue(node['online_store_url']),
      canonicalUrl:
          stringValue(node['canonicalUrl']) ?? stringValue(node['url']),
      publishedAt:
          stringValue(node['publishedAt']) ?? stringValue(node['published_at']),
      updatedAt:
          stringValue(node['updatedAt']) ?? stringValue(node['updated_at']),
    );
  }
}

class ShopifySeoImage {
  final String? id;
  final String? src;
  final String? alt;
  final int? width;
  final int? height;
  final int? position;

  const ShopifySeoImage({
    this.id,
    this.src,
    this.alt,
    this.width,
    this.height,
    this.position,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'src': src,
    'alt': alt,
    'width': width,
    'height': height,
    'position': position,
  };

  static ShopifySeoImage fromJson(Map<String, Object?> json) {
    final imageMap = _firstMap(json['image']);
    final mediaMap = _firstMap(json['media']);
    return ShopifySeoImage(
      id: stringValue(json['id']),
      src:
          stringValue(json['src']) ??
          stringValue(json['url']) ??
          stringValue(json['originalSrc']) ??
          stringValue(json['transformedSrc']) ??
          stringValue(mediaMap?['previewImage']) ??
          stringValue(imageMap?['src']),
      alt:
          stringValue(json['alt']) ??
          stringValue(json['altText']) ??
          stringValue(imageMap?['alt']) ??
          stringValue(imageMap?['altText']) ??
          stringValue(mediaMap?['alt']),
      width: intValue(json['width']),
      height: intValue(json['height']),
      position: intValue(json['position']),
    );
  }
}

class ShopifySeoVariant {
  final String? id;
  final String? title;
  final String? sku;
  final String? price;
  final String? barcode;
  final String? option1;
  final String? option2;
  final String? option3;
  final bool? availableForSale;

  const ShopifySeoVariant({
    this.id,
    this.title,
    this.sku,
    this.price,
    this.barcode,
    this.option1,
    this.option2,
    this.option3,
    this.availableForSale,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'sku': sku,
    'price': price,
    'barcode': barcode,
    'option1': option1,
    'option2': option2,
    'option3': option3,
    'availableForSale': availableForSale,
  };

  static ShopifySeoVariant fromJson(Map<String, Object?> json) {
    final priceMap = _firstMap(json['price']);
    return ShopifySeoVariant(
      id: stringValue(json['id']),
      title: stringValue(json['title']),
      sku: stringValue(json['sku']),
      price:
          stringValue(priceMap?['amount']) ??
          stringValue(_firstMap(json['priceV2'])?['amount']) ??
          (json['price'] is Map ? null : stringValue(json['price'])) ??
          (json['priceV2'] is Map ? null : stringValue(json['priceV2'])),
      barcode: stringValue(json['barcode']),
      option1: stringValue(json['option1']),
      option2: stringValue(json['option2']),
      option3: stringValue(json['option3']),
      availableForSale:
          boolValue(json['availableForSale']) ?? boolValue(json['available']),
    );
  }
}

List<ShopifySeoImage> _decodeImages(Map<String, Object?> json) {
  final raw =
      json['images'] ??
      json['media'] ??
      json['featuredImage'] ??
      json['featured_image'] ??
      json['image'];
  return _mapList(raw).map(ShopifySeoImage.fromJson).toList(growable: false);
}

List<ShopifySeoVariant> _decodeVariants(Map<String, Object?> json) => _mapList(
  json['variants'],
).map(ShopifySeoVariant.fromJson).toList(growable: false);

List<String> _decodeCollections(Map<String, Object?> json) {
  final merged = <String>[
    ...stringList(json['collections']),
    ...stringList(json['collectionTitles']),
    ...stringList(json['collection_handles']),
  ];
  return merged.toSet().toList(growable: false);
}

List<Map<String, Object?>> _mapList(Object? raw) {
  if (raw == null) return const [];
  if (raw is Map) {
    final edges = raw['edges'];
    final nodes = raw['nodes'];
    if (edges is List) {
      return edges
          .whereType<Map>()
          .map((edge) => _firstMap(edge['node']) ?? edge)
          .map((map) => map.map((key, value) => MapEntry('$key', value)))
          .toList(growable: false);
    }
    if (nodes is List) {
      return nodes
          .whereType<Map>()
          .map((map) => map.map((key, value) => MapEntry('$key', value)))
          .toList(growable: false);
    }
    return [raw.map((key, value) => MapEntry('$key', value))];
  }
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((map) => map.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }
  return const [];
}

Map<String, Object?>? _firstMap(Object? value) {
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return null;
}

String? stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

int? intValue(Object? value) {
  if (value is int) return value;
  return int.tryParse(stringValue(value) ?? '');
}

bool? boolValue(Object? value) {
  if (value is bool) return value;
  final text = stringValue(value)?.toLowerCase();
  if (text == 'true' || text == '1') return true;
  if (text == 'false' || text == '0') return false;
  return null;
}

List<String> stringList(Object? value) {
  if (value is List) {
    return value
        .map((item) {
          if (item is Map) {
            return stringValue(item['title']) ??
                stringValue(item['handle']) ??
                stringValue(item['name']);
          }
          return stringValue(item);
        })
        .whereType<String>()
        .toList(growable: false);
  }
  final text = stringValue(value);
  if (text == null) return const [];
  return text
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String slugText(String value) => _slug(value);

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');
