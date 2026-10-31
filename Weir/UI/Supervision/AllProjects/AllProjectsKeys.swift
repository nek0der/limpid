// AllProjectsKeys.swift
// Weir — the keys the all projects sheet takes at its window.

import AppKit

/// The keys of the all projects sheet, which its `WindowOverlayKeyMonitor`
/// takes at the window while it is up, so none reaches the terminal under
/// it. The arrows, Return, and Esc work the sheet; Tab and ⇧Tab go through
/// the sheet's controls (`AllProjectsSelection.Control`), the keyboard
/// staying in the field. ⌘Return opens the card in a new window, and is the
/// sheet's rather than the decision bar's under it.
enum AllProjectsKeys {
    enum Key {
        case previous
        case next
        case up
        case down
        case open
        /// ⌘Return: the card opens in a new window.
        case openInNewWindow
        case close
        /// Tab: the next of the filter, the selected card's button, and the
        /// ×, rather than a view under the dimmed window.
        case nextControl
        /// ⇧Tab: the one before.
        case previousControl
    }

    /// The sheet's key for `event`, or `nil` for one it leaves alone.
    static func key(for event: NSEvent) -> Key? {
        if event.modifierFlags.chord == .command, event.namedKey == .return {
            return .openInNewWindow
        }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        if event.namedKey == .tab {
            return event.modifierFlags.contains(.shift) ? .previousControl : .nextControl
        }
        return switch event.namedKey {
        case .left: .previous
        case .right: .next
        case .up: .up
        case .down: .down
        case .return: .open
        case .escape: .close
        default: nil
        }
    }
}
