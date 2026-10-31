// ProjectWindowPresenting.swift
// Weir — the port through which window state asks for a window to be shown or hidden.

import Foundation
import WeirDomain

/// Shows, hides, and closes the window for a `ProjectWindowState`.
///
/// A protocol so the registry decides which windows exist without knowing
/// AppKit: the app layer implements it with window controllers, and tests
/// with a recorder.
@MainActor
protocol ProjectWindowPresenting: AnyObject {
    /// A window with no saved frame opens cascaded from `origin`'s window,
    /// on its screen, so a new window asked from it neither lands on top of
    /// it nor on another display; with no `origin`, or one with no
    /// window, it is centered on the main screen.
    func show(_ window: ProjectWindowState, openedFrom origin: WindowID?)
    func hide(_ windowID: WindowID)
    /// Ends `windowID`'s window for good: the registry has let it go
    /// (`WindowRegistry.close`), and showing it again would take a new one.
    func close(_ windowID: WindowID)
    func isOnScreen(_ windowID: WindowID) -> Bool
    /// Brings `windowID` back to the front once the windows going back
    /// into full screen have, since each takes the screen to its own Space.
    func raiseAfterFullScreenEntries(_ windowID: WindowID)
}
