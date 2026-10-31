// WindowOverlayKeyMonitor.swift
// Weir — gives a window-wide overlay its keys, so none reaches the terminal under it.

import AppKit
import SwiftUI

/// The keys of a surface laid over the whole window (All Projects, the
/// keyboard shortcuts panel), taken at the window while it is up. Such a
/// surface is an overlay, which AppKit does not make the receiver of keys
/// as it does a sheet's window: whatever holds the keyboard under it (the
/// surface's field, or a terminal that took it back) would otherwise get
/// them, and a TUI under the dimmed window would read Return or a letter.
///
/// Which keys it takes is `WindowOverlayKeyRoute`'s, by where the keyboard
/// is.
struct WindowOverlayKeyMonitor<Key: Equatable>: View {
    /// The surface's key for an event, or `nil` for one it leaves alone.
    let key: (NSEvent) -> Key?
    let onKey: (Key) -> Void
    /// The surface is up; `false` while it fades out, when its keys are
    /// the window's again.
    let isPresented: () -> Bool
    /// The surface's field holds the keyboard.
    let isFieldFocused: () -> Bool
    /// The keyboard is in the approval card over the surface, which takes
    /// its own keys. A card that is only on screen holds none: the
    /// surface's field has the keyboard then, and its keys are the
    /// surface's.
    let isCardFocused: () -> Bool
    /// The terminal took the keyboard: the field asks for it back.
    let reclaimKeyboard: () -> Void

    var body: some View {
        WindowKeyDownMonitor(handle: handle)
    }

    /// Whether the surface took `event`.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        let responder = window.firstResponder
        let holder: WindowOverlayKeyRoute<Key>.Holder = if isCardFocused() {
            .approvalCard
        } else if isFieldFocused() {
            .field
        } else if responder is SurfaceView {
            .terminal
        } else if responder === window || responder == nil {
            .window
        } else {
            .otherLayer
        }
        let route = WindowOverlayKeyRoute.route(
            key: key(event),
            holder: holder,
            isPresented: isPresented(),
            isComposing: window.isComposingText,
            hasShortcutModifier: !event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        )
        switch route {
        case .pass:
            return false
        case let .take(key):
            onKey(key)
            return true
        case .reclaim:
            reclaimKeyboard()
            return true
        }
    }
}

/// What a window overlay's monitor does with a key, by where the keyboard
/// is. The keys the surface names act on it while the keyboard is with its
/// field, a terminal under it, or no view. Any other key while a terminal holds the
/// keyboard is dropped and the field takes the keyboard back. Passed
/// through: a key the input method is composing with, a key another layer
/// holds (the approval card while the keyboard is in it, the palette, a
/// title bar menu), a shortcut with ⌘, ⌃, or ⌥ the surface does not name,
/// and every key once the surface is closing.
enum WindowOverlayKeyRoute<Key: Equatable>: Equatable {
    /// The key goes on to the window as if the surface were not there.
    case pass
    /// The surface takes the key.
    case take(Key)
    /// The key is dropped and the surface's field takes the keyboard back.
    case reclaim
}

extension WindowOverlayKeyRoute {
    /// Where the keyboard is as a key reaches the surface.
    enum Holder: Equatable {
        /// The surface's own field.
        case field
        /// A terminal under the dimmed window.
        case terminal
        /// The window itself, or no view.
        case window
        /// The approval card over the surface.
        case approvalCard
        /// Another layer's field or list (the palette, a title bar menu).
        case otherLayer
    }

    /// The route for a key the surface names as `key` (`nil` for one it
    /// leaves alone). Where the keyboard is decides, not which layers are
    /// on screen: a card open over the surface while its field has the
    /// keyboard leaves Esc and Tab to the surface, since the card takes
    /// only the keys that reach it.
    static func route(
        key: Key?,
        holder: Holder,
        isPresented: Bool,
        isComposing: Bool,
        hasShortcutModifier: Bool
    ) -> WindowOverlayKeyRoute {
        guard isPresented, !isComposing else { return .pass }
        switch holder {
        case .approvalCard, .otherLayer:
            return .pass
        case .field, .terminal, .window:
            if let key {
                return .take(key)
            }
            return holder == .terminal && !hasShortcutModifier ? .reclaim : .pass
        }
    }
}
