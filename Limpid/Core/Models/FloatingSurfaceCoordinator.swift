// FloatingSurfaceCoordinator.swift
// Limpid — the surfaces that float over the main window, and which of them
// give way when another appears.
//
// Two at once would stack over each other and compete for Escape, since each
// floating panel watches the window's keys. So this is the one list of those
// surfaces, and the one place that decides what closes when one presents,
// what may not open while another is up, and whether the prompt cache panel
// may open under the pointer. The scene-root
// layer (`FloatingPanelLayer`) reads the surfaces' states into a set and asks
// here.

import Foundation

/// Everything that floats over the main window's content.
enum FloatingSurfaceKind: Hashable, CaseIterable {
    case commandPalette
    case paneRename
    case promptCache
    case containerColor
    /// An approval card the user brought up, by a click on its row or a
    /// command.
    case approvalCard
    /// An approval card showing only because the pointer rests on its
    /// Waiting row: a hover peek, like the PR card.
    case approvalPreview
    case notificationHistory
    case prCard
    case review

    /// One of Limpid's own small floating panels, which close for each
    /// other: the rename field, the cache panel, the color picker.
    var isFloatingPanel: Bool {
        switch self {
        case .paneRename, .promptCache, .containerColor: true
        default: false
        }
    }

    /// A surface the user brings up to work in. The cache panel and the
    /// color picker make way for it and do not open over it, so that two
    /// Escape monitors never compete. A rename in progress is left to end
    /// itself: these surfaces take the keyboard, and the rename field
    /// commits when it loses it.
    var makesPanelsGiveWay: Bool {
        switch self {
        case .commandPalette, .approvalCard, .notificationHistory, .review: true
        default: false
        }
    }
}

enum FloatingSurfaceRules {
    /// The open surfaces that close when `opening` presents.
    ///
    /// A floating panel closes the other floating panels, a rename in
    /// progress included: opened by keyboard or VoiceOver there is no click
    /// elsewhere to end the rename, and two panels would stand side by side.
    /// A working surface closes the cache panel and the color picker. A hover
    /// peek (the PR card, an approval preview) closes nothing.
    static func surfacesToClose(
        whenPresenting opening: FloatingSurfaceKind,
        open: Set<FloatingSurfaceKind>
    ) -> Set<FloatingSurfaceKind> {
        let closing: Set<FloatingSurfaceKind> = if opening.isFloatingPanel {
            [.paneRename, .promptCache, .containerColor]
        } else if opening.makesPanelsGiveWay {
            [.promptCache, .containerColor]
        } else {
            []
        }
        return open.intersection(closing).subtracting([opening])
    }

    /// Whether anything other than `kind` is up. The prompt cache panel
    /// does not open under a resting pointer or by itself while it is: the
    /// pointer is on its way to or from that surface, and a second one would
    /// cover it.
    static func isAnotherSurfaceOpen(than kind: FloatingSurfaceKind, open: Set<FloatingSurfaceKind>) -> Bool {
        !open.subtracting([kind]).isEmpty
    }

    /// Whether `kind` may not open at all, by any means, while `open` is
    /// up: the cache panel and the color picker do not open over a working
    /// surface. The other half of `surfacesToClose`, which closes them when
    /// one comes up, so neither order ends with both on screen.
    static func isOpeningBlocked(_ kind: FloatingSurfaceKind, open: Set<FloatingSurfaceKind>) -> Bool {
        guard kind == .promptCache || kind == .containerColor else { return false }
        return open.contains { $0.makesPanelsGiveWay }
    }
}

/// Carries out `FloatingSurfaceRules.surfacesToClose` against the panels
/// that can be closed from here. A value built where the presentations
/// live, so the rule is applied the same way and can be tested with real
/// presentations.
@MainActor
struct FloatingSurfaceCoordinator {
    let promptCache: PromptCachePanelPresentation
    let containerColor: ContainerColorPresentation
    /// Ends a rename in progress the way a click elsewhere does, committing
    /// what was typed: the keyboard goes back to the pane's terminal.
    let endRename: () -> Void

    /// `opening` has just presented, and `open` is what is up now. Two
    /// panels opening in the same update each report presenting; the one
    /// already closed by the other must not close it in turn, so a surface
    /// no longer open does nothing.
    /// Tells the panels what may open while `open` is up: whether the cache
    /// panel may open under the pointer or by itself, and whether either
    /// panel may open at all.
    func updateGates(open: Set<FloatingSurfaceKind>) {
        promptCache.isAnotherSurfaceOpen = FloatingSurfaceRules.isAnotherSurfaceOpen(than: .promptCache, open: open)
        promptCache.isOpeningBlocked = FloatingSurfaceRules.isOpeningBlocked(.promptCache, open: open)
        containerColor.isOpeningBlocked = FloatingSurfaceRules.isOpeningBlocked(.containerColor, open: open)
    }

    /// The surfaces open went from `previous` to `current`: each one newly
    /// presented makes way in turn, in `FloatingSurfaceKind` order, each
    /// against what `live` reports is open by then, so a surface an earlier
    /// one closed has nothing left to close.
    func makeWay(
        from previous: Set<FloatingSurfaceKind>,
        to current: Set<FloatingSurfaceKind>,
        live: () -> Set<FloatingSurfaceKind>
    ) {
        for kind in FloatingSurfaceKind.allCases where current.contains(kind) && !previous.contains(kind) {
            makeWay(for: kind, open: live())
        }
    }

    func makeWay(for opening: FloatingSurfaceKind, open: Set<FloatingSurfaceKind>) {
        guard open.contains(opening) else { return }
        for kind in FloatingSurfaceRules.surfacesToClose(whenPresenting: opening, open: open) {
            switch kind {
            case .paneRename:
                endRename()
            case .promptCache:
                promptCache.close()
            case .containerColor:
                containerColor.close()
            case .commandPalette, .approvalCard, .approvalPreview, .notificationHistory, .prCard, .review:
                // Never in the closing set: these are the app's own
                // surfaces, which close by their own controls.
                break
            }
        }
    }
}
