// SettingsSearchNavigationTests.swift
// Limpid — Keyboard selection and submission behavior for Settings search.

import Testing
@testable import Limpid

@Suite("SettingsSearchNavigation")
struct SettingsSearchNavigationTests {
    private let results = [
        SettingsSearchEntry(id: "first", section: .general, groupTitle: "General", title: "First", order: 0),
        SettingsSearchEntry(id: "second", section: .general, groupTitle: "General", title: "Second", order: 1)
    ]

    @Test("Arrow selection starts at the nearest end and clamps")
    func movedSelection_startsAndClamps() {
        #expect(SettingsSearchNavigation.movedSelection(from: nil, by: 1, in: results) == "first")
        #expect(SettingsSearchNavigation.movedSelection(from: nil, by: -1, in: results) == "second")
        #expect(SettingsSearchNavigation.movedSelection(from: "first", by: -1, in: results) == "first")
        #expect(SettingsSearchNavigation.movedSelection(from: "second", by: 1, in: results) == "second")
    }

    @Test("Submission uses the selection and otherwise falls back to the first result")
    func submittedEntry_usesSelectionOrFirst() {
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "second", in: results)?.id == "second")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "missing", in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: []) == nil)
    }
}
