import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Shopify SEO section defers inherited scope load past initState', () {
    final source = File(
      'lib/features/projects/detail/shopify_seo_section.dart',
    ).readAsStringSync();
    final classStart = source.indexOf('class _ShopifySeoSectionState');
    final nextClass = source.indexOf('\nclass ', classStart + 1);
    final body = source.substring(classStart, nextClass);

    expect(body, contains('void didChangeDependencies()'));
    expect(body, contains('void didUpdateWidget('));
    expect(body, contains('_loadIfNeeded()'));
    expect(body, contains('_loadIfNeeded(force: true)'));
    expect(body, contains('AppState? _loadedState'));
    expect(body, contains('String? _loadedProjectId'));
    expect(body, contains('identical(_loadedState, state)'));
    expect(body, contains('widget.projectId != projectId'));
    expect(body, isNot(contains('void initState()')));
  });
}
