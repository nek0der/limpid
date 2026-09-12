// UpdateDisplayItemTests.swift
// Limpid — presentation-state coverage for the custom update interface.

import Foundation
import Sparkle
import Testing
@testable import Limpid

@MainActor
@Suite("Update display item")
struct UpdateDisplayItemTests {
    @Test("preserves values used by the update interface")
    func preservesPresentationValues() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let releaseNotesURL = URL(string: "https://example.invalid/release-notes")
        let item = UpdateDisplayItem(
            displayVersion: "v1.2.3",
            contentLength: 42,
            date: date,
            releaseNotesURL: releaseNotesURL
        )

        #expect(item.displayVersion == "v1.2.3")
        #expect(item.contentLength == 42)
        #expect(item.date == date)
        #expect(item.releaseNotesURL == releaseNotesURL)
    }

    @Test("state carries presentation values without retaining a manufactured appcast item")
    func updateStateCarriesDisplayItem() {
        let item = UpdateDisplayItem(displayVersion: "v1.2.3")
        let reply = OneShot<SPUUserUpdateChoice> { _ in }
        let model = UpdateStateModel()

        model.state = .available(item: item, reply: reply)

        #expect(model.pendingItem?.displayVersion == "v1.2.3")
    }

    @Test("placeholder has stable metadata for out-of-order Sparkle callbacks")
    func placeholderHasStableMetadata() {
        #expect(UpdateDisplayItem.placeholder.displayVersion == "v0.0.0")
        #expect(UpdateDisplayItem.placeholder.contentLength == 0)
        #expect(UpdateDisplayItem.placeholder.date == nil)
        #expect(UpdateDisplayItem.placeholder.releaseNotesURL == nil)
    }
}
