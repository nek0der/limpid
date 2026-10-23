// RecordingAttentionNavigator.swift
// Limpid — goes nowhere, and records where the attention list asked to go.

import Foundation
@testable import Limpid

/// Stands in for the app's navigator so a test reads what the attention
/// list asked of it: each item gone to, in which window, whether its turn's
/// review was to open, and each runtime asked for. `SessionAttentionNavigator`
/// goes there over a real session; this one is for tests about the asking.
@MainActor
final class RecordingAttentionNavigator: AttentionNavigating {
    /// The project every window walks first.
    var project: UUID?
    /// The window the items' project is shown in, when it is not the one
    /// the list was used in.
    var projectWindow: ProjectWindowState?
    private(set) var visited: [AttentionItemID] = []
    private(set) var opensTurnReview: [Bool] = []
    /// The window each item was gone to in.
    private(set) var wentIn: [WindowID?] = []
    private(set) var runtimes: [String] = []

    func projectID(of _: ProjectWindowState) -> UUID? {
        project
    }

    func go(to item: AttentionItem, opensTurnReview: Bool, in window: ProjectWindowState?) {
        visited.append(item.id)
        self.opensTurnReview.append(opensTurnReview)
        wentIn.append(window?.id)
    }

    /// Only a runtime named "shown" is found in a pane.
    func go(toRuntime runtimeID: String, in _: ProjectWindowState?) -> Bool {
        runtimes.append(runtimeID)
        return runtimeID == "shown"
    }

    func presentWindow(for _: AttentionItem, from window: ProjectWindowState?) -> ProjectWindowState? {
        projectWindow ?? window
    }
}
