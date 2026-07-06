import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/shopify_seo_analyzer.dart';
import 'package:project_atlas/services/shopify_seo_review_service.dart';

void main() {
  group('ShopifySeoAnalyzer', () {
    test('missing SEO title and meta description produce issues', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(currentSeoTitle: '', currentMetaDescription: ''),
      );

      expect(analysis.issues.map((i) => i.id), contains('missing_seo_title'));
      expect(
        analysis.issues.map((i) => i.id),
        contains('missing_meta_description'),
      );
      expect(analysis.criticalCount, greaterThanOrEqualTo(2));
    });

    test('thin descriptions are detected after stripping HTML', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(currentDescription: '<p>Nice tee.</p>'),
      );

      expect(analysis.issues.map((i) => i.id), contains('thin_description'));
    });

    test('duplicate meta descriptions across products are detected', () {
      final snapshot = ShopifySeoReviewSnapshot(
        shopDomain: 'sinternetcult.com',
        source: 'test',
        syncedAt: DateTime(2026, 1, 1),
        products: [
          _product(
            id: 'a',
            currentMetaDescription:
                'Same useful meta description for duplicate testing across products.',
          ),
          _product(
            id: 'b',
            title: 'Other Tee',
            currentMetaDescription:
                'Same useful meta description for duplicate testing across products.',
          ),
        ],
      );

      final analyses = ShopifySeoAnalyzer.analyzeSnapshot(snapshot);
      expect(
        analyses['a']!.issues.map((i) => i.id),
        contains('duplicate_meta_description'),
      );
      expect(
        analyses['b']!.issues.map((i) => i.id),
        contains('duplicate_meta_description'),
      );
    });

    test('missing image alt text is detected', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(
          images: const [ShopifySeoImage(id: 'img1', alt: '')],
        ),
      );

      expect(analysis.issues.map((i) => i.id), contains('missing_image_alt'));
    });

    test('long image alt text is warned', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(images: [ShopifySeoImage(alt: 'x' * 140)]),
      );

      expect(analysis.issues.map((i) => i.id), contains('image_alt_long'));
    });

    test('handles with random IDs or empty handles are warned', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(handle: 'product-a8f92da17823'),
      );

      expect(analysis.issues.map((i) => i.id), contains('random_handle'));
    });

    test('variant and merchant readiness issues are detected', () {
      final analysis = ShopifySeoAnalyzer.analyzeProduct(
        _product(
          variants: const [
            ShopifySeoVariant(
              title: 'Default',
              sku: '',
              price: '',
              barcode: '',
            ),
          ],
        ),
      );

      final ids = analysis.issues.map((i) => i.id);
      expect(ids, contains('missing_variant_price'));
      expect(ids, contains('missing_variant_sku'));
      expect(ids, contains('missing_variant_barcode'));
      expect(ids, contains('missing_availability'));
    });

    test('existing v1 sample JSON still decodes', () {
      final snapshot = ShopifySeoReviewSnapshot.decode(
        jsonEncode({
          'shopDomain': 'sinternetcult.com',
          'products': [
            {
              'id': 'gid://shopify/Product/1',
              'handle': 'chaos-tee',
              'title': 'Chaos Tee',
              'product_type': 'Apparel',
              'vendor': 'Sinternet Cult',
              'tags': 'tee, internet',
              'seo': {'title': 'Chaos Tee', 'description': ''},
              'body_html': '<p>Current body</p>',
            },
          ],
        }),
      );

      expect(snapshot.products.single.title, 'Chaos Tee');
      expect(snapshot.products.single.images, isEmpty);
    });

    test(
      'batch context includes analysis, proposal seed, field rules, and policy',
      () {
        final context = _product().toBatchContext(
          shopDomain: 'sinternetcult.com',
        );

        expect(context['seoAnalysis'], isA<Map<String, Object?>>());
        expect(context['proposalSeed'], isA<Map<String, Object?>>());
        expect(context['allowedFields'], contains('images.alt'));
        expect(context['forbiddenFields'], contains('price'));
        expect(context['writePolicy'], 'stage_only_until_user_approved');
      },
    );

    test('proposal seed does not invent unsupported claims', () {
      final seed = ShopifySeoAnalyzer.generateProposalSeed(
        _product(currentDescription: 'A graphic tee.'),
        shopDomain: 'sinternetcult.com',
        brandName: 'Sinternet Cult',
      );
      final combined = [
        seed.proposedSeoTitle,
        seed.proposedMetaDescription,
        seed.proposedDescriptionOutline,
      ].join(' ').toLowerCase();

      expect(combined, isNot(contains('guaranteed delivery')));
      expect(combined, isNot(contains('100% cotton')));
      expect(combined, isNot(contains('official')));
    });

    test('proposal seed meta is public-facing and uses supplied brand', () {
      final seed = ShopifySeoAnalyzer.generateProposalSeed(
        _product(
          title: 'Signal Hoodie',
          currentDescription: 'A graphic hoodie.',
        ),
        shopDomain: 'example-shop.com',
        brandName: 'Signal Store',
      );
      final meta = seed.proposedMetaDescription.toLowerCase();

      expect(seed.proposedSeoTitle, contains('Signal Store'));
      for (final forbidden in [
        'staged',
        'review',
        'seo',
        'snippet',
        'proposal',
      ]) {
        expect(meta, isNot(contains(forbidden)));
      }
    });
  });
}

ShopifySeoProduct _product({
  String id = 'gid://shopify/Product/test',
  String handle = 'internet-cult-core-tee',
  String title = 'Internet Cult Core Tee',
  String? currentSeoTitle = 'Internet Cult Core Tee | Sinternet Cult',
  String? currentMetaDescription =
      'A graphic streetwear tee from Sinternet Cult for extremely online outfit chaos.',
  String? currentDescription =
      '<p>A graphic tee with internet culture styling for everyday wear and gifting.</p>',
  List<ShopifySeoImage> images = const [
    ShopifySeoImage(id: 'img1', alt: 'Internet Cult Core Tee'),
  ],
  List<ShopifySeoVariant> variants = const [
    ShopifySeoVariant(
      id: 'var1',
      title: 'Default Title',
      sku: 'SC-TEE-001',
      price: '29.99',
      barcode: '123456789012',
      availableForSale: true,
    ),
  ],
}) => ShopifySeoProduct(
  id: id,
  handle: handle,
  title: title,
  status: 'needs_review',
  productType: 'Tee',
  vendor: 'Sinternet Cult',
  tags: const ['streetwear', 'tee'],
  currentSeoTitle: currentSeoTitle,
  currentMetaDescription: currentMetaDescription,
  currentDescription: currentDescription,
  images: images,
  variants: variants,
  collections: const ['Tees'],
);
