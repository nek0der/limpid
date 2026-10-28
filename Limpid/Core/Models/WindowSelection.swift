// WindowSelection.swift
// Limpid — what one window has selected and how it is laid out.

import Foundation
import Observation

/// What one window shows: its selected container and tab, its history, and
/// its layout. The projects, tabs, agents, and terminals themselves are
/// shared by every window and stay on `WorkspaceSession`.
///
/// A class rather than a value in a dictionary so observation stays per
/// property: the frame changes on every step of a live resize, and as a
/// struct it would invalidate every view that reads the selected tab. The
/// form that is saved to disk is a separate value written from this one
/// (`WindowRecord`).
@MainActor
@Observable
final class WindowSelection {
    let windowID: WindowID

    /// The tab the session area shows. May be nil when the active
    /// container has zero tabs (the pane strip's empty state). Together with
    /// `activeContainerID` it forms the **active-selection invariant**:
    /// when `activeTabID` is non-nil,
    /// `tabs.first(where: { $0.id == activeTabID })?.container` must equal
    /// `activeContainerID`. Mutate through
    /// `WorkspaceSession.setActiveTab(_:in:intent:)` and
    /// `setActiveContainer(_:in:intent:)`, which keep the pair intact; direct
    /// assignment is only used by `init`, `restore(from:)`, and transient
    /// close paths that immediately re-establish the pair.
    var activeTabID: UUID?

    /// The selected container: the sidebar's selected row. Drives which
    /// container's tabs the pane strip shows. Independent of `activeTabID` so the strip can show an
    /// "empty container" state. The only legitimate intermediate violation
    /// of the invariant above is during multi-step close paths (`closeTab`,
    /// `closeTabs(where:)`) that clear `activeTabID` before the caller picks
    /// the next active container.
    var activeContainerID: ContainerID

    /// The project this window shows: the one its selection is in, kept
    /// while the window is on a scratch tab, which belongs to no project,
    /// so the sidebar keeps listing the project's sessions. `nil` until the
    /// window has shown one. Stored rather than derived from
    /// `activeContainerID` for that scratch case. Changed as the window
    /// takes a project (`WorkspaceSession.showProject(_:in:intent:reason:)`),
    /// before anything is selected in it.
    var projectID: UUID?

    /// The project the window stands for: `projectID`, or the selection's
    /// own project before anything has set it (the first frame). What every part of the window
    /// that names "this project" reads, so they cannot disagree.
    var shownProjectID: UUID? {
        projectID ?? activeContainerID.projectID
    }

    /// Whether the window shows nothing yet: opened by New Window, or
    /// left with no project to go to as the one it showed was removed. It
    /// stands on the scratch row with no tab, draws no scratch tab, and
    /// offers the projects to open instead, until the person chooses a
    /// project (`WorkspaceSession.showProject(_:in:intent:reason:)`) or the
    /// scratch tabs (`WorkspaceSession.claimScratch(for:)`). Only while the app
    /// runs: never saved, so a window that showed nothing comes back on
    /// the scratch tabs.
    var isChoosingProject = false

    /// Back/forward history of (container, tab) pairs this window has
    /// visited, for Go Back / Go Forward (unbound by default; ⌘[ / ⌘]
    /// move between sessions). Pushed on every `activeTabID` change
    /// driven by user input; rewritten when the user steps off the
    /// history tail (forward stack truncates). Transient — not persisted
    /// across launches.
    var navBackStack: [WorkspaceSession.NavTarget] = []
    var navForwardStack: [WorkspaceSession.NavTarget] = []

    /// Sidebar width in points; persisted. The window's chrome, as are
    /// `sidebarHidden`, `isChangesPanelPresented`, and `changesPanelWidth`:
    /// they stay as the window switches projects (`ProjectView`).
    var sidebarWidth: CGFloat

    /// Whether the sidebar is collapsed.
    var sidebarHidden = false

    /// How the sidebar lists the projects: their order, which headers are
    /// folded, and which sections are open. The window's chrome, like
    /// `sidebarWidth`: it stays as the window switches projects, apart from
    /// the header of the project switched to, which opens
    /// (`WorkspaceSession.showProject(_:in:intent:reason:)`). Saved with
    /// the window.
    var sidebarArrangement = SidebarArrangement()

    /// Whether the changes panel is open beside the session. Closed
    /// by default and never opened on its own; persisted with the window.
    var isChangesPanelPresented = false
    /// The changes panel's width as the person last dragged it, `nil` for
    /// the default.
    var changesPanelWidth: CGFloat?
    /// How the changes panel lists the turns: one timeline, the default,
    /// or a section per conversation. The window's chrome, like the panel's
    /// width, and saved with the window.
    var changesPanelGrouping = ChangesPanelGrouping.timeline
    /// The conversation the changes panel's filter narrows the timeline
    /// to, `nil` for all, the default. The project's, unlike the panel
    /// itself: it names one of its conversations, and comes back with the
    /// project while the app runs (`ProjectView`). Never saved with the
    /// window: a launch opens the panel on "All".
    var changesPanelFilter: ConversationKey?

    /// Last-known `NSWindow` frame in screen coordinates, out of full
    /// screen: the frame the window goes back to (`WindowFrameSync`).
    var frame: CGRect?

    /// Whether the hosting window is in native fullscreen. Maintained by
    /// `WindowFullScreenSync`; saved, so a window that was in full screen
    /// at quit goes back into it when it is shown. The window base fill
    /// reads this to neutralize the backdrop in fullscreen: a fullscreen
    /// Space sits directly on the desktop wallpaper, so the desktop-tinted
    /// `.underWindowBackground` vibrancy floods the backdrop with the
    /// wallpaper's color. We drain the saturation there (swapping the
    /// material doesn't help — `.behindWindow` pulls the wallpaper pixels in
    /// regardless), keeping the translucent blur while collapsing the hue to
    /// neutral.
    var isFullScreen = false

    /// Whether the traffic lights are out of the top strip, so the sidebar
    /// controls can take their place. Also maintained by
    /// `WindowFullScreenSync`, but unlike `isFullScreen` it clears when the
    /// exit animation starts: the traffic lights return while the window
    /// shrinks, before `didExit`.
    var areTrafficLightsHidden = false

    init(
        windowID: WindowID = WindowID(),
        activeTabID: UUID? = nil,
        activeContainerID: ContainerID = .loose,
        sidebarWidth: CGFloat = SessionLayoutDefaults.sidebarWidth
    ) {
        self.windowID = windowID
        self.activeTabID = activeTabID
        self.activeContainerID = activeContainerID
        self.sidebarWidth = sidebarWidth
    }
}

/// How the changes panel lists a worktree's turns. Saved by its raw value
/// (`WindowRecord`), so a case is never renamed.
enum ChangesPanelGrouping: String, Codable, Sendable {
    /// Every conversation's turns in one list, oldest first.
    case timeline
    /// A section per conversation, each with its own viewed line.
    case byConversation
}
