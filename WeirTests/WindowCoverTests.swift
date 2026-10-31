// WindowCoverTests.swift
// Weir — what covers a window's content, and which of those are the panels Weir draws over the whole window.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WindowCoverTests {
    /// What a window can have open over or beside its content.
    enum Layer: CaseIterable, Sendable {
        case allProjects
        case keyboardShortcuts
        case systemSheet
        case notificationHistory
    }

    /// All Projects and the keyboard shortcuts panel are drawn over the
    /// whole window and have the person's attention; a system sheet covers
    /// the window too. A floating panel (the history) hangs beside its
    /// control and leaves the window to the pointer.
    @Test(arguments: [
        (Layer.allProjects, true, true),
        (.keyboardShortcuts, true, true),
        (.systemSheet, true, false),
        (.notificationHistory, false, false)
    ])
    func aLayer_coversTheWindow_onlyWhenItIsOverTheWholeWindowOrASheet(layer: Layer, covers: Bool, isOverlay: Bool) {
        let window = ProjectWindowState(selection: WindowSelection())
        #expect(!window.isContentCovered)
        #expect(!window.isWindowOverlayPresented)

        switch layer {
        case .allProjects: window.isAllProjectsPresented = true
        case .keyboardShortcuts: window.keyboardShortcuts.isPresented = true
        case .systemSheet: window.hasAttachedSheet = true
        case .notificationHistory: window.notificationHistory.isPresented = true
        }

        #expect(window.isContentCovered == covers)
        #expect(window.isWindowOverlayPresented == isOverlay)
    }
}
