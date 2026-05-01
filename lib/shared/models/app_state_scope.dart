import 'package:flutter/widgets.dart';

import '../models/app_state.dart';

/// Single source of truth for AppState access across the app.
/// This must be the ONLY AppStateScope type used (do not duplicate elsewhere).
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required Widget child,
  }) : super(notifier: state, child: child);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found above this context');
    return scope!.notifier!;
  }
}
