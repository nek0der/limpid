// ProjectSwitch.swift
// Weir — why a window switches to another project, and what the app layer is told as it does.

import Foundation

/// Why a window switches to another project. What the app
/// layer keeps of the project left depends on it.
enum ProjectSwitchReason: Equatable, Sendable {
    /// The person chose something of another project in the window: a tab
    /// from the palette, going back, ⌘J, a notification, a suggested move.
    case person
    /// The project the window showed was removed: nothing of it is kept,
    /// neither its view nor its review.
    case projectRemoved
}

/// What the supervision window's app layer does as windows switch projects.
/// The session decides which window shows which project
/// (`WorkspaceSession.showProject(_:in:intent:reason:)`); it makes no window,
/// and leaves bringing one forward, and what a window holds beside its
/// selection, to the app layer, which owns the windows. The session keeps
/// one project in at most one window whatever it is told: until an app
/// layer connects (`unconnected`), its windows switch in place all the
/// same, and nothing beside their selections hears of it.
@MainActor
struct ProjectSwitchHandlers {
    /// Brings `window` forward, shown again if hidden: the window that
    /// already shows the project the person chose in another, since a
    /// project is shown in one window at a time.
    let onRaiseWindow: (_ window: WindowID) -> Void
    /// Told as `window` is about to leave `from` for `to` (`nil`: no
    /// project), before its selection changes, so what it shows of the
    /// project it leaves goes with that project or, for `reason`
    /// `.projectRemoved`, is let go.
    let willSwitchProject: (_ window: WindowID, _ from: UUID?, _ to: UUID?, _ reason: ProjectSwitchReason) -> Void
    /// Told once `window` shows `projectID`, put back on what the project
    /// showed when a window last left it, and before whatever was asked is
    /// selected in it.
    let didSwitchProject: (_ window: WindowID, _ projectID: UUID?) -> Void
    /// Told as a window is added (`WorkspaceSession.addWindow(showing:layoutFrom:)`),
    /// with its selection, before it takes the project it opens on: the app
    /// layer lists it then, so the window takes what that project kept as
    /// any window switching to it does (`didSwitchProject`).
    var didAddWindow: (_ selection: WindowSelection) -> Void = { _ in }
    /// Runs a switch (`switching`) as the app layer draws it: as one change,
    /// with nothing animated, so the window does not show the project left
    /// and the next in between, or slide a panel the next project lays out
    /// another way. Every write of the switch is made inside it, those the
    /// app layer makes as it is told on both sides included.
    var drawsSwitch: (_ switching: () -> Void) -> Void = { $0() }

    /// What a session tells before an app layer connects
    /// (`WindowRegistry.connectProjectSwitching`): nothing. The app does
    /// so before any window can select another project's session.
    static let unconnected = ProjectSwitchHandlers(
        onRaiseWindow: { _ in },
        willSwitchProject: { _, _, _, _ in },
        didSwitchProject: { _, _ in }
    )
}
