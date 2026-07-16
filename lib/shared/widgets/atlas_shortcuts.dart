import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'create_work_item_dialog.dart';

// ---------------------------------------------------------------------------
// Intents — one per app-level keyboard action.
// Add future intents here (e.g. OpenCommandPaletteIntent, FocusSearchIntent).
// ---------------------------------------------------------------------------

/// Fired by Ctrl+N to open the global "new task" dialog.
class NewWorkItemIntent extends Intent {
  const NewWorkItemIntent();
}

// ---------------------------------------------------------------------------
// App-level shortcut map — wire this into AtlasShell via [atlasShortcuts].
// ---------------------------------------------------------------------------

/// The canonical shortcut→intent bindings for Atlas.
///
/// Wrap a subtree with [Shortcuts] + [atlasActions] to activate them.
final Map<ShortcutActivator, Intent> atlasShortcuts = {
  const SingleActivator(LogicalKeyboardKey.keyN, control: true):
      const NewWorkItemIntent(),
  // Future bindings go here, e.g.:
  // SingleActivator(LogicalKeyboardKey.keyK, control: true):
  //     const OpenCommandPaletteIntent(),
};

// ---------------------------------------------------------------------------
// Actions — one Action subclass per Intent.
// ---------------------------------------------------------------------------

/// Opens [showCreateWorkItemDialog] unless a modal overlay is already present.
class NewWorkItemAction extends Action<NewWorkItemIntent> {
  @override
  void invoke(NewWorkItemIntent intent) {
    final context = primaryFocus?.context;
    if (context == null) return;

    // Guard: don't open a second dialog when one is already on screen.
    if (ModalRoute.of(context)?.isCurrent == false) return;

    showCreateWorkItemDialog(context);
  }
}

/// Returns the [Actions] map to pair with [atlasShortcuts].
Map<Type, Action<Intent>> atlasActions() => {
      NewWorkItemIntent: NewWorkItemAction(),
    };
