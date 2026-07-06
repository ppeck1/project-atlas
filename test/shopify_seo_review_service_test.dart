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
