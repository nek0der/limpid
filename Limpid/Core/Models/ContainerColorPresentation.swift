// ContainerColorPresentation.swift
// Limpid — which Group or Project's color picker is open, and below which
// color dot.
//
// The picker is a floating panel (`FloatingPanel.swift`) drawn over a
// window rather than through `.popover`: it shares the other floating
// panels' surface, its arrow points at the dot, and it may overlap what lies
// below. The main window holds one presentation at scene root, which a
// sidebar row opens from its context menu; the container settings sheet,
// a window of its own, holds another for its Color row.

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ContainerColorPresentation {
    /// One open picker. `id` is minted per open, so the host can tell a
    /// reopened picker from the one before and measure it afresh. The
    /// current color is not kept here: the picker reads it from the session
    /// each time it draws, so its ring follows a change made elsewhere.
    struct Request: Equatable, FloatingPanelRequest {
        let id: UUID
        let container: GroupOrProjectID
        /// The color dot, in global coordinates. The panel hangs below it,
        /// or above it near the window's bottom, and follows it while the
        /// list scrolls or the window resizes.
        var anchor: CGRect
    }

    /// The picker on screen, if any. One at a time: opening another
    /// replaces it.
    private(set) var request: Request?

    /// Set while a working surface is up (the command palette, an approval
    /// card, the notification history, review): the picker does not open
    /// over it. See `FloatingSurfaceRules.isOpeningBlocked`. The main
    /// window's `FloatingPanelLayer` keeps this current; the settings
    /// sheet's picker, in a window of its own, never sets it.
    @ObservationIgnored var isOpeningBlocked = false

    /// Opens the picker for `container` below its color dot, unless a
    /// working surface is up.
    func open(container: GroupOrProjectID, anchor: CGRect) {
        guard !isOpeningBlocked else { return }
        request = Request(id: UUID(), container: container, anchor: anchor)
    }

    /// The color dot moved. No-op unless its row owns the open picker.
    func updateAnchor(container: GroupOrProjectID, anchor: CGRect) {
        guard var current = request, current.container == container, current.anchor != anchor else { return }
        current.anchor = anchor
        request = current
    }

    /// A swatch was picked. Returns the container and slot to apply, and
    /// closes the picker: a color is one click, with nothing to confirm, so
    /// the panel has done its job. Nil when nothing is open.
    func pick(_ paletteIndex: Int) -> (container: GroupOrProjectID, paletteIndex: Int)? {
        guard let current = request else { return nil }
        request = nil
        return (current.container, paletteIndex)
    }

    /// A mouse button went down outside the picker. It closes, and the
    /// click still reaches what it landed on.
    func pointerPressedOutside() {
        close()
    }

    /// A key went down while the picker is up. Escape closes it and is
    /// spent on that, so it never also reaches the terminal, where an agent
    /// reads Escape as a command of its own, nor dismisses the settings
    /// sheet around it. Other keys belong to whatever has the keyboard.
    func keyPressed(isEscape: Bool) -> Bool {
        guard request != nil, isEscape else { return false }
        close()
        return true
    }

    /// The row owning the picker left the screen: the container was
    /// removed, or its section collapsed. The picker goes with it.
    func rowDisappeared(container: GroupOrProjectID) {
        if request?.container == container {
            close()
        }
    }

    func close() {
        request = nil
    }
}
