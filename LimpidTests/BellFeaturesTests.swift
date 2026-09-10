// BellFeaturesTests.swift
// Limpid — pins the user-facing Bell choices to the feedback channels
// the embedded terminal actually performs.

import Testing
@testable import Limpid

@Suite("Bell features")
struct BellFeaturesTests {
    @Test(
        "Bell choices map to their audio and visual channels",
        arguments: [
            (BellAction.none, BellFeatures()),
            (BellAction.visual, BellFeatures([.attention, .paneFlash])),
            (BellAction.audio, BellFeatures([.system])),
            (BellAction.both, BellFeatures([.system, .attention, .paneFlash]))
        ]
    )
    func actionMapsToChannels(action: BellAction, expected: BellFeatures) {
        #expect(BellFeatures.forAction(action) == expected)
    }
}
