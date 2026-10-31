// ReviewTabDisplayTests.swift
// Weir — the review tab as its views draw it: one model the file list binds to, each part observed on its own.

import Foundation
import Observation
import Testing
@testable import Weir

/// Set once an observed read is told of a change; written from the
/// observation's change handler, which runs synchronously in the write.
private final class Told: @unchecked Sendable {
    var value = false
}

@MainActor
struct ReviewTabDisplayTests {
    /// Whether reading `read` is told of a change made by `change`.
    private static func isTold(reading read: @escaping () -> Void, after change: () -> Void) -> Bool {
        let told = Told()
        withObservationTracking(read) { told.value = true }
        change()
        return told.value
    }

    /// The file list's filter lives with the window's review tab, not with
    /// the list: a filter that matches nothing takes the list's rows away,
    /// and what is typed then still reaches the tab a project keeps.
    @Test func theFilter_isTheWindows_whateverTheListShows() {
        let window = ProjectWindowsFixture().primary
        window.reviewTabDisplay.fileFilter = "no-such-file"
        window.reviewTabDisplay.collapsedSections = ["dir:src"]

        #expect(window.reviewTabView.fileFilter == "no-such-file")
        #expect(window.reviewTabView.collapsedSections == ["dir:src"])

        window.letGoOfReview()
        #expect(window.reviewTabDisplay.fileFilter.isEmpty, "another review starts anew")
        #expect(window.reviewTabDisplay.collapsedSections.isEmpty)
    }

    @Test func aTabBroughtBack_setsEveryPart_andOnlyAChangedPartTellsItsViews() {
        let display = ReviewTabDisplay()
        var state = ReviewTabViewState()
        state.fileFilter = "src"
        state.isTreeLayout = true
        state.search = ReviewSearch(query: "TODO", isPresented: true, index: 1)

        display.state = state
        #expect(display.state == state)

        // The find bar's every keystroke is written; the file list, which
        // reads the filter, is not drawn again for it.
        #expect(!Self.isTold(reading: { _ = display.fileFilter }, after: {
            display.assign(\.search, ReviewSearch(query: "TODO!", isPresented: true, index: 0))
        }))
        #expect(!Self.isTold(reading: { _ = display.fileFilter }, after: { display.state = display.state }))
        #expect(Self.isTold(reading: { _ = display.fileFilter }, after: { display.assign(\.fileFilter, "lib") }))
    }
}
