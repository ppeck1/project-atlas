import 'dart:convert';

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
    'shopDomain': shopDomain,
    'source': source,
    'syncedAt': syncedAt.toIso8601String(),
    'products': products.map((product) => product.toJson()).toList(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  String summaryMarkdown() {
    final lines = <String>[
      'Shopify SEO review snapshot',
      '',
      '- shop: $shopDomain',
      '- source: $source',
      '- syncedAt: ${syncedAt.toIso8601String()}',
      '- products: ${products.length}',
      '- needsReview: $needsReviewCount',
      '- staged: $stagedCount',
      '- queued: $queuedCount',
      '- approved: $approvedCount',
    ];
    return lines.join('\n');
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
      shopDomain: _string(json['shopDomain']) ?? 'sinternetcult.com',
      source: _string(json['source']) ?? 'shopify_admin_api_stub',
      syncedAt:
          DateTime.tryParse(_string(json['syncedAt']) ?? '') ?? DateTime.now(),
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
          currentSeoTitle: '',
          currentMetaDescription: '',
          currentDescription:
              'Graphic tee for the extremely online and spiritually unwell.',
          proposedSeoTitle: 'Internet Cult Core Tee | Sinternet Cult',
          proposedMetaDescription:
              'Shop the Internet Cult Core Tee from Sinternet Cult, a graphic streetwear shirt for extremely online chaos.',
          proposedDescription:
              'A graphic tee for extremely online streetwear fans, built as a first SEO review placeholder until Shopify sync is connected.',
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
          currentSeoTitle: 'Doomscroll Hoodie',
          currentMetaDescription: '',
          currentDescription:
              'Soft hoodie for logging off without actually logging off.',
          proposedSeoTitle: 'Doomscroll Recovery Hoodie | Sinternet Cult',
          proposedMetaDescription:
              'A soft graphic hoodie for internet culture, comfort, and late-night scrolling recovery.',
          proposedDescription:
              'A comfort-first graphic hoodie with internet culture styling and search-ready copy for streetwear shoppers.',
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
  };

  Map<String, Object?> toBatchContext({required String shopDomain}) => {
    'source': 'shopify_seo_review',
    'approvalUnit': 'product',
    'shopDomain': shopDomain,
    'product': toJson(),
    'allowedFields': ['seo.title', 'seo.description', 'body_html', 'tags'],
    'writePolicy': 'stage_only_until_user_approved',
  };

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
  );

  static ShopifySeoProduct fromJson(Map<String, Object?> json) {
    final id = _string(json['id']) ?? _string(json['admin_graphql_api_id']);
    final handle = _string(json['handle']);
    final title = _string(json['title']);
    if ((id == null || id.isEmpty) &&
        (handle == null || handle.isEmpty) &&
        (title == null || title.isEmpty)) {
      throw const FormatException('Product requires id, handle, or title.');
    }
    final seo = json['seo'];
    final seoMap = seo is Map
        ? seo.map((key, value) => MapEntry('$key', value))
        : const <String, Object?>{};
    final proposal = json['proposal'];
    final proposalMap = proposal is Map
        ? proposal.map((key, value) => MapEntry('$key', value))
        : const <String, Object?>{};
    return ShopifySeoProduct(
      id: id ?? handle ?? title!,
      handle: handle ?? _slug(title ?? id!),
      title: title ?? handle ?? id!,
      status: _string(json['status']) ?? 'needs_review',
      productType:
          _string(json['productType']) ?? _string(json['product_type']),
      vendor: _string(json['vendor']),
      tags: _stringList(json['tags']),
      currentSeoTitle:
          _string(json['currentSeoTitle']) ?? _string(seoMap['title']),
      currentMetaDescription:
          _string(json['currentMetaDescription']) ??
          _string(seoMap['description']),
      currentDescription:
          _string(json['currentDescription']) ??
          _string(json['body_html']) ??
          _string(json['description']),
      proposedSeoTitle:
          _string(json['proposedSeoTitle']) ?? _string(proposalMap['seoTitle']),
      proposedMetaDescription:
          _string(json['proposedMetaDescription']) ??
          _string(proposalMap['metaDescription']),
      proposedDescription:
          _string(json['proposedDescription']) ??
          _string(proposalMap['description']),
      issueNotes: _stringList(json['issueNotes']),
    );
  }
}

String? _string(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map(_string).whereType<String>().toList(growable: false);
  }
  final text = _string(value);
  if (text == null) return const [];
  return text
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');
