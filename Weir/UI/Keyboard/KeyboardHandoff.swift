// KeyboardHandoff.swift
// Weir — when a surface that opens takes the keyboard, and how it goes back to the terminal when it closes.

import AppKit
import WeirDomain

/// The keyboard passing between a terminal and a surface over it: a panel,
/// a sheet, or a list that takes the keys as it opens, and the terminal
/// getting them back when it closes.
@MainActor
enum KeyboardHandoff {
    /// Runs `take` once a surface that has just opened can hold the
    /// keyboard: two turns of the main queue. The first mounts the surface's
    /// field or list; the second lets the terminal, or whatever held the
    /// keys, give up first responder. Asked at once, the request is lost.
    /// Every surface that takes the keyboard as it opens asks here, so none
    /// of them waits a turn less than the rest.
    static func afterResponderSettles(_ take: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            DispatchQueue.main.async { take() }
        }
    }

    /// The same wait, for a `.task` that checks it was not canceled
    /// before it takes the keyboard.
    static func responderSettled() async {
        await withCheckedContinuation { continuation in
            afterResponderSettles { continuation.resume() }
        }
    }

    /// Who has the keyboard as it is handed back.
    enum Holder: Equatable {
        case terminal
        /// A text field still in a window.
        case textField
        case other
    }

    /// Who keeps the keyboard rather than give it to the terminal.
    enum Keeper: Equatable {
        /// Only a terminal: anything else is the closing surface's own field
        /// or list, still fading out, which would keep the keys and type
        /// them into nothing.
        case terminal
        /// A terminal or a text field: for a surface whose field is already
        /// gone when the keyboard is handed back, any field still in the
        /// window is one the person went to.
        case terminalOrTextField
    }

    /// When the keyboard is handed back.
    enum Timing: Equatable {
        /// At once: the pane is drawn and the closing surface's field still
        /// holds the keys.
        case now
        /// On the next turn, after a pane the surface opened is drawn, or
        /// after AppKit has settled who owns first responder once a field
        /// is torn down.
        case nextTurn
    }

    /// Whether the terminal takes the keyboard from `holder`.
    nonisolated static func returnsKeyboard(from holder: Holder, keeper: Keeper) -> Bool {
        switch (holder, keeper) {
        case (.terminal, _): false
        case (.textField, .terminalOrTextField): false
        case (.textField, .terminal), (.other, _): true
        }
    }

    /// Gives the keyboard to `paneID`'s terminal, unless the view that has
    /// it is one `keeper` lets keep it.
    static func returnToTerminal(
        paneID: UUID?,
        registry: any SurfaceViewProviding,
        keeper: Keeper,
        timing: Timing
    ) {
        guard let paneID else { return }
        let hand = {
            guard let view = registry.view(for: paneID), let window = view.window,
                  returnsKeyboard(from: holder(of: window.firstResponder), keeper: keeper)
            else { return }
            window.makeFirstResponder(view)
        }
        switch timing {
        case .now: hand()
        case .nextTurn: DispatchQueue.main.async { hand() }
        }
    }

    /// Gives the keyboard to the focused pane of `window`'s tab, read now,
    /// after whatever closed the surface may have moved the window to
    /// another tab.
    static func returnToFocusedPane(
        in window: WindowID,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        keeper: Keeper,
        timing: Timing
    ) {
        returnToTerminal(
            paneID: session.activeTab(in: window)?.splitTree.effectiveFocusedLeafID,
            registry: registry,
            keeper: keeper,
            timing: timing
        )
    }

    private static func holder(of responder: NSResponder?) -> Holder {
        switch responder {
        case is SurfaceView:
            .terminal
        case let editor as NSText where (editor.delegate as? NSView)?.window != nil:
            .textField
        default:
            .other
        }
    }
}
