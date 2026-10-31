// PaneVisibilityTests.swift
// Weir — panes on screen per window, and their union.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct PaneVisibilityTests {
    @Test func union_coversEveryWindow() {
        let front = WindowID()
        let back = WindowID()
        let shared = UUID()
        let onlyFront = UUID()
        let onlyBack = UUID()
        var visibility = PaneVisibility()

        visibility.report(window: front, visiblePaneIDs: [shared, onlyFront])
        visibility.report(window: back, visiblePaneIDs: [shared, onlyBack])

        #expect(visibility.union == [shared, onlyFront, onlyBack])
    }

    @Test func aWindowGoingBehind_doesNotHideWhatAnotherShows() {
        let front = WindowID()
        let back = WindowID()
        let pane = UUID()
        var visibility = PaneVisibility()
        visibility.report(window: front, visiblePaneIDs: [pane])
        visibility.report(window: back, visiblePaneIDs: [pane])

        visibility.report(window: back, visiblePaneIDs: [])

        #expect(visibility.union == [pane])
    }

    @Test func anEmptyReport_removesTheWindow() {
        let window = WindowID()
        var visibility = PaneVisibility()
        visibility.report(window: window, visiblePaneIDs: [UUID()])

        visibility.report(window: window, visiblePaneIDs: [])

        #expect(visibility.visibleByWindow.isEmpty)
        #expect(visibility.union.isEmpty)
    }

    @Test func aNewReport_replacesTheWindowsSet() {
        let window = WindowID()
        let old = UUID()
        let new = UUID()
        var visibility = PaneVisibility()
        visibility.report(window: window, visiblePaneIDs: [old])

        visibility.report(window: window, visiblePaneIDs: [new])

        #expect(visibility.union == [new])
    }
}
