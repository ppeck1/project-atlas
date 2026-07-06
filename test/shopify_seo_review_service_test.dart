import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/shopify_seo_review_service.dart';

void main() {
  group('ShopifySeoReviewSnapshot', () {
    test('sample snapshot is plug-and-play for example-store.test', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleExampleStore();

      expect(snapshot.shopDomain, 'example-store.test');
      expect(snapshot.source, 'shopify_admin_api_stub');
      expect(snapshot.products, hasLength(2));
      expect(snapshot.needsReviewCount, 2);
      expect(snapshot.summaryMarkdown(), contains('products: 2'));
    });

    test('decodes Shopify-like product JSON', () {
      final snapshot = ShopifySeoReviewSnapshot.decode(
        jsonEncode({
          'shopDomain': 'example-store.test',
          'products': [
            {
              'id': 'gid://shopify/Product/1',
              'handle': 'chaos-tee',
              'title': 'Chaos Tee',
              'product_type': 'Apparel',
              'vendor': 'Example Store',
              'tags': 'tee, internet',
              'seo': {'title': 'Chaos Tee', 'description': ''},
              'body_html': '<p>Current body</p>',
              'proposal': {
                'seoTitle': 'Chaos Tee | Example Store',
                'metaDescription': 'Search-ready chaos tee copy.',
              },
              'issueNotes': ['Missing meta description'],
            },
          ],
        }),
      );

      final product = snapshot.products.single;
      expect(product.handle, 'chaos-tee');
      expect(product.productType, 'Apparel');
      expect(product.tags, ['tee', 'internet']);
      expect(product.currentSeoTitle, 'Chaos Tee');
      expect(product.proposedSeoTitle, 'Chaos Tee | Example Store');
      expect(product.issueNotes, ['Missing meta description']);
    });

    test('decodes v2 images variants collections and timestamps', () {
      final snapshot = ShopifySeoReviewSnapshot.decode(
        jsonEncode({
          'shopDomain': 'example-store.test',
          'products': [
            {
              'id': 'gid://shopify/Product/2',
              'handle': 'signal-hoodie',
              'title': 'Signal Hoodie',
              'images': [
                {
                  'id': 'img1',
                  'src': 'https://example.test/img.png',
                  'altText': 'Signal Hoodie front',
                  'width': 1200,
                  'height': 1200,
                  'position': 1,
                },
              ],
              'variants': {
                'edges': [
                  {
                    'node': {
                      'id': 'var1',
                      'title': 'Large',
                      'sku': 'SIG-L',
                      'price': {'amount': '54.99'},
                      'availableForSale': true,
                    },
                  },
                ],
              },
              'collection_handles': 'hoodies, signal',
              'onlineStoreUrl':
                  'https://example-store.test/products/signal-hoodie',
              'updatedAt': '2026-07-06T12:00:00Z',
            },
          ],
        }),
      );

      final product = snapshot.products.single;
      expect(product.images.single.alt, 'Signal Hoodie front');
      expect(product.variants.single.price, '54.99');
      expect(product.variants.single.availableForSale, isTrue);
      expect(product.collections, ['hoodies', 'signal']);
      expect(product.updatedAt, '2026-07-06T12:00:00Z');
    });

    test('decodes nested GraphQL media preview image shapes', () {
      final snapshot = ShopifySeoReviewSnapshot.decode(
        jsonEncode({
          'shopDomain': 'example-store.test',
          'products': [
            {
              'id': 'gid://shopify/Product/3',
              'handle': 'front-view-tee',
              'title': 'Front View Tee',
              'media': {
                'edges': [
                  {
                    'node': {
                      'id': 'media1',
                      'alt': 'Front view',
                      'previewImage': {'url': 'https://example.test/front.png'},
                      'image': {'url': 'https://example.test/fallback.png'},
                    },
                  },
                ],
              },
            },
          ],
        }),
      );

      final image = snapshot.products.single.images.single;
      expect(image.alt, 'Front view');
      expect(image.src, 'https://example.test/front.png');
    });

    test('brandName falls back to most common vendor then domain', () {
      final snapshot = ShopifySeoReviewSnapshot(
        shopDomain: 'example-shop.com',
        source: 'test',
        syncedAt: DateTime(2026),
        products: const [
          ShopifySeoProduct(
            id: '1',
            handle: 'a',
            title: 'A',
            status: 'needs_review',
            vendor: 'Vendor One',
          ),
          ShopifySeoProduct(
            id: '2',
            handle: 'b',
            title: 'B',
            status: 'needs_review',
            vendor: 'Vendor One',
          ),
          ShopifySeoProduct(
            id: '3',
            handle: 'c',
            title: 'C',
            status: 'needs_review',
            vendor: 'Vendor Two',
          ),
        ],
      );
      final domainOnly = ShopifySeoReviewSnapshot(
        shopDomain: 'weird-store.example',
        source: 'test',
        syncedAt: DateTime(2026),
        products: const [],
      );

      expect(snapshot.resolvedBrandName, 'Vendor One');
      expect(domainOnly.resolvedBrandName, 'Weird Store');
    });

    test('marks selected products queued without changing others', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleExampleStore();
      final queued = snapshot.markQueued({snapshot.products.first.id});

      expect(queued.products.first.status, 'queued');
      expect(queued.products.last.status, 'needs_review');
      expect(queued.queuedCount, 1);
    });

    test('default product selection is empty for catalog safety', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleExampleStore();

      expect(defaultShopifySeoProductSelection(snapshot), isEmpty);
    });

    test('batch context is stage-only and product scoped', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleExampleStore();
      final context = snapshot.products.first.toBatchContext(
        shopDomain: snapshot.shopDomain,
      );

      expect(context['source'], 'shopify_seo_review');
      expect(context['approvalUnit'], 'product');
      expect(context['writePolicy'], 'stage_only_until_user_approved');
      expect(context['allowedFields'], contains('seo.title'));
    });
  });
}
