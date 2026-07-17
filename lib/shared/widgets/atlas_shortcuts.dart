import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'atlas_command_palette.dart';
import 'create_work_item_dialog.dart';

// ---------------------------------------------------------------------------
// Intents — one per app-level keyboard action.
// ---------------------------------------------------------------------------

/// Fired by Ctrl+N to open the global "new task" dialog.
class NewWorkItemIntent extends Intent {
  const NewWorkItemIntent();
}

/// Fired by Ctrl+K to open the jump-to-project command palette.
class OpenCommandPaletteIntent extends Intent {
  const OpenCommandPaletteIntent();
}

/// Fired by `/` to focus the routed screen's search field, if it has one.
class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

// ---------------------------------------------------------------------------
// Search-focus registry — lets routed screens expose their search field to
// the `/` shortcut.
// ---------------------------------------------------------------------------

/// Screens with a search field call [register] in initState and [unregister]
/// in dispose. Only one screen is routed at a time, so a single slot
/// ("last registered wins") is enough — no keying needed.
class AtlasSearchFocusRegistry {
  AtlasSearchFocusRegistry._();

  static FocusNode? _node;

  /// The currently registered search field, or null when the routed screen
  /// has none.
  static FocusNode? get current => _node;

  static void register(FocusNode node) => _node = node;

  static void unregister(FocusNode node) {
    if (identical(_node, node)) _node = null;
  }
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
  const SingleActivator(LogicalKeyboardKey.keyK, control: true):
      const OpenCommandPaletteIntent(),
  const SingleActivator(LogicalKeyboardKey.slash): const FocusSearchIntent(),
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

/// Opens [showAtlasCommandPalette] unless a modal overlay is already present.
class OpenCommandPaletteAction extends Action<OpenCommandPaletteIntent> {
  @override
  void invoke(OpenCommandPaletteIntent intent) {
    final context = primaryFocus?.context;
    if (context == null) return;

    // Guard: don't open a second palette when a modal is already on screen.
    if (ModalRoute.of(context)?.isCurrent == false) return;

    showAtlasCommandPalette(context);
  }
}

/// Moves focus to the routed screen's registered search field.
///
/// `/` must keep working as a plain character inside text fields. Checking
/// inside [invoke] would be too late — by then the keystroke is already
/// consumed. Instead the action reports itself *disabled* (via [isEnabled])
/// whenever an [EditableText] holds primary focus: ShortcutManager then
/// returns KeyEventResult.ignored for the event, which falls through to the
/// platform text input, so the character is typed normally.
class FocusSearchAction extends Action<FocusSearchIntent> {
  @override
  bool isEnabled(FocusSearchIntent intent) {
    if (AtlasSearchFocusRegistry.current == null) return false;
    final focusContext = primaryFocus?.context;
    if (focusContext == null) return false;
    // Disabled while the user is typing in any text field.
    return focusContext.widget is! EditableText &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  void invoke(FocusSearchIntent intent) {
    AtlasSearchFocusRegistry.current?.requestFocus();
  }
}

/// Returns the [Actions] map to pair with [atlasShortcuts].
Map<Type, Action<Intent>> atlasActions() => {
      NewWorkItemIntent: NewWorkItemAction(),
      OpenCommandPaletteIntent: OpenCommandPaletteAction(),
      FocusSearchIntent: FocusSearchAction(),
    };
