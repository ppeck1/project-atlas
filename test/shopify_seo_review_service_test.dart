import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/services/shopify_seo_review_service.dart';

void main() {
  group('ShopifySeoReviewSnapshot', () {
    test('sample snapshot is plug-and-play for sinternetcult.com', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleSinternetCult();

      expect(snapshot.shopDomain, 'sinternetcult.com');
      expect(snapshot.source, 'shopify_admin_api_stub');
      expect(snapshot.products, hasLength(2));
      expect(snapshot.needsReviewCount, 2);
      expect(snapshot.summaryMarkdown(), contains('products: 2'));
    });

    test('decodes Shopify-like product JSON', () {
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
              'proposal': {
                'seoTitle': 'Chaos Tee | Sinternet Cult',
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
      expect(product.proposedSeoTitle, 'Chaos Tee | Sinternet Cult');
      expect(product.issueNotes, ['Missing meta description']);
    });

    test('decodes v2 images variants collections and timestamps', () {
      final snapshot = ShopifySeoReviewSnapshot.decode(
        jsonEncode({
          'shopDomain': 'sinternetcult.com',
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
                  'https://sinternetcult.com/products/signal-hoodie',
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

    test('marks selected products queued without changing others', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleSinternetCult();
      final queued = snapshot.markQueued({snapshot.products.first.id});

      expect(queued.products.first.status, 'queued');
      expect(queued.products.last.status, 'needs_review');
      expect(queued.queuedCount, 1);
    });

    test('batch context is stage-only and product scoped', () {
      final snapshot = ShopifySeoReviewSnapshot.sampleSinternetCult();
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
