// UpdateStateTests.swift
// Weir — the update interface's state: the item it shows, a download's progress, and how progress is read out.

import Foundation
import Sparkle
import Testing
@testable import Weir

@MainActor
struct UpdateStateTests {
    @Test func aDownload_isZeroWhileItsSizeIsUnknown_andStopsAtTheEnd() {
        #expect(UpdateState.downloadProgress(received: 500, expected: nil) == 0)
        #expect(UpdateState.downloadProgress(received: 500, expected: 0) == 0)
        #expect(UpdateState.downloadProgress(received: 250, expected: 1000) == 0.25)
        #expect(UpdateState.downloadProgress(received: 1500, expected: 1000) == 1)
    }

    @Test func progress_isReadAsAPercentage_inTheWindowsLanguage() {
        #expect(UpdateState.progressText(0.42, locale: Locale(identifier: "en")) == "42%")
        #expect(UpdateState.progressText(0.42, locale: Locale(identifier: "ja")) == "42%")
        #expect(UpdateState.extracting(progress: 0.5).progressValueText(locale: Locale(identifier: "en")) == "50%")
        #expect(UpdateState.idle.progressValueText(locale: Locale(identifier: "en")).isEmpty)
    }

    /// `UpdateDisplayItem` holds no appcast item by its type, which needs no
    /// test here.
    @Test("the driver reads the update's version from the state")
    func updateStateCarriesDisplayItem() {
        let item = UpdateDisplayItem(displayVersion: "v1.2.3")
        let reply = OneShot<SPUUserUpdateChoice> { _ in }
        let model = UpdateStateModel()

        model.state = .available(item: item, reply: reply)

        #expect(model.pendingItem?.displayVersion == "v1.2.3")
    }
}
