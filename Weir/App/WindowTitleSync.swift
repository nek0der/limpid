// WindowTitleSync.swift
// Weir — keep `NSWindow.title` in sync with what the window shows, so
// the OS-level window header (Mission Control, ⌘`, the Window menu, app
// switcher previews) names it even when the title bar itself is hidden.

import AppKit
import Foundation

/// The title is "{project} — {branch}", with the traffic lights on the
/// title bar. One window shows one project, so its title names the place,
/// not the terminal title, which the pane strip already carries.
@MainActor
final class WindowTitleSync {
    private weak var session: WorkspaceSession?
    /// The window's own selection, so the title follows the tab this window
    /// shows rather than another window's.
    private weak var selection: WindowSelection?
    private weak var window: NSWindow?
    /// The height of the bar the traffic lights stand centered in, handed
    /// in by the window's owner, since its size is the UI layer's.
    private let stripHeight: CGFloat

    init(session: WorkspaceSession, selection: WindowSelection, window: NSWindow, stripHeight: CGFloat) {
        self.session = session
        self.selection = selection
        self.window = window
        self.stripHeight = stripHeight
        // Push the initial value immediately so the window doesn't read
        // "Weir" for one frame before the first observation fires.
        apply()

        // Re-arm the observation tracker after every fire so the title
        // keeps following all subsequent mutations.
        observeRepeatedly { [weak self] in
            _ = self?.title
        } onChange: { [weak self] in
            self?.apply()
        }
    }

    /// Read inside the observation, so it tracks exactly what it reads.
    private var title: String {
        guard let session, let selection else { return "Weir" }
        // A window that shows nothing stands for no project, whatever it
        // showed before.
        return WindowTitleText.projectAndBranch(
            selection.activeContainerID,
            shownProjectID: selection.isChoosingProject ? nil : selection.shownProjectID,
            in: session
        )
    }

    private func apply() {
        guard let window else { return }
        let title = title
        // Avoid redundant writes — assigning the same string still bumps
        // AppKit's internal observers.
        if window.title != title {
            window.title = title
            // Setting title makes AppKit re-lay out the titlebar, which
            // resets traffic lights to their default position. Re-apply
            // our placement so a title change (another branch, another
            // project) doesn't visibly knock the buttons sideways.
            repositionTrafficLights(in: window, stripHeight: stripHeight)
        }
    }
}
