// RecordingWindowPresenter.swift
// Weir — a window presenter that records what the registry asked of it.

import Foundation
@testable import Weir
@testable import WeirDomain

/// Stands in for the app's window controllers: records which windows were
/// shown, beside which window, which are on screen, and which closed.
@MainActor
final class RecordingWindowPresenter: ProjectWindowPresenting {
    var onScreen: Set<WindowID> = []
    var shown: [WindowID] = []
    /// The window each window was opened from, as asked: the one it is
    /// placed beside, on that window's screen.
    var openedFrom: [WindowID: WindowID?] = [:]

    func show(_ window: ProjectWindowState, openedFrom origin: WindowID?) {
        shown.append(window.id)
        openedFrom[window.id] = origin
        onScreen.insert(window.id)
    }

    func hide(_ windowID: WindowID) {
        onScreen.remove(windowID)
    }

    /// The windows closed for good, in order.
    var closed: [WindowID] = []

    func close(_ windowID: WindowID) {
        closed.append(windowID)
        onScreen.remove(windowID)
    }

    func isOnScreen(_ windowID: WindowID) -> Bool {
        onScreen.contains(windowID)
    }

    /// The windows asked to come back to the front after full screen.
    var raisedAfterFullScreen: [WindowID] = []

    func raiseAfterFullScreenEntries(_ windowID: WindowID) {
        raisedAfterFullScreen.append(windowID)
    }
}
