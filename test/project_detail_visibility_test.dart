import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_atlas/db/app_db.dart';
import 'package:project_atlas/shared/models/app_state.dart';

void main() {
  test('project detail section visibility is persisted per project', () async {
    final db = AppDb.withExecutor(NativeDatabase.memory());
    final state = AppState(db, enableBackgroundSummaryRefresh: false);
    addTearDown(() async {
      state.dispose();
      await db.close();
    });

    const defaults = ['tags', 'identity', 'shopify_seo', 'work'];

    final initial = await state.loadProjectDetailSectionVisibility(
      'atlas',
      defaults,
    );
    expect(initial.visibleSectionIds, containsAll(defaults));

    await state.saveProjectDetailSectionVisibility('atlas', [
      'tags',
      'identity',
      'work',
    ], defaults);
    await state.saveProjectDetailSectionVisibility('other', defaults, defaults);

    final atlas = await state.loadProjectDetailSectionVisibility(
      'atlas',
      defaults,
    );
    final other = await state.loadProjectDetailSectionVisibility(
      'other',
      defaults,
    );

    expect(atlas.isVisible('shopify_seo'), isFalse);
    expect(atlas.isVisible('identity'), isTrue);
    expect(other.isVisible('shopify_seo'), isTrue);
  });

  test('project display dialog keeps the section checklist scrollable', () {
    final source = File(
      'lib/features/projects/project_detail_screen.dart',
    ).readAsStringSync();
    final dialogStart = source.indexOf(
      'Future<void> _showSectionVisibilityDialog',
    );
    final nextDialog = source.indexOf('Future<void> _showMetaDialog');
    final body = source.substring(dialogStart, nextDialog);

    expect(body, contains("title: const Text('Project display')"));
    expect(body, contains('SingleChildScrollView'));
    expect(body, contains('BoxConstraints(maxHeight: 520)'));
    expect(body, contains('_projectDetailSections'));
    expect(body, contains("child: const Text('Show all')"));
  });
}
