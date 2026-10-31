// ShortcutValidation.swift
// Weir — why Settings → Keyboard takes or refuses a combination for an action.

import Foundation

/// Outcome of `KeyboardSettings.validate`. The recorder surfaces
/// these to the user as a small warning under the row; `.ok` is the
/// only outcome that commits.
enum ShortcutValidation: Equatable {
    case ok
    /// Another action is already bound to the same trigger.
    case conflict(WeirShortcutAction)
    /// Two actions that share keys (`WeirShortcutAction.sharesKeys`) are
    /// both bound to the trigger, so the message names both.
    case conflictWithPair(WeirShortcutAction, WeirShortcutAction)
    /// The place the action answers in uses the trigger already
    /// (`WeirShortcutAction.keysItsPlaceKeeps`): the sidebar's ⌥← ⌥→.
    case keptBySidebar
    /// Trigger is one Weir reserves (⌘Q, ⇧⏎, ⌘⏎, ⌘1…⌘9, ⌘⌃1…⌘⌃9).
    /// See `ReservedShortcuts`.
    case reserved
    /// Modifier-less binding — would hijack every plain keystroke
    /// of that character and break terminal input. The recorder
    /// requires at least one of ⌘/⌥/⌃/⇧.
    case missingModifier
    /// The quick terminal's global hotkey uses the same trigger. Carbon
    /// takes a registered hotkey before the menu bar sees it, so the
    /// menu item would never fire.
    case quickTerminalConflict
}
