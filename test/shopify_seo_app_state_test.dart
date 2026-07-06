import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/services/shopify_seo_review_service.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  group('Shopify SEO AppState queueing', () {
    late AppDb db;
    late AppState state;

    setUp(() async {
      db = AppDb.withExecutor(NativeDatabase.memory());
      state = AppState(db, enableBackgroundSummaryRefresh: false);
      await db.createProject('shop', 'Shop', DateTime(2026, 1, 1));
    });

    tearDown(() async {
      state.dispose();
      await db.close();
    });

    test('already queued products are skipped at service layer', () async {
      final snapshot = ShopifySeoReviewSnapshot(
        shopDomain: 'example-store.test',
        source: 'test',
        syncedAt: DateTime(2026, 1, 1),
        products: const [
          ShopifySeoProduct(
            id: 'queued-product',
            handle: 'queued-product',
            title: 'Queued Product',
            status: 'queued',
            vendor: 'Example Store',
          ),
        ],
      );

      final count = await state.queueShopifySeoProductBatches(
        projectId: 'shop',
        snapshot: snapshot,
        productIds: {'queued-product'},
      );
      final tasks = await state.getLlmTasksForProject('shop');

      expect(count, 0);
      expect(tasks, isEmpty);
    });
  });
}
