// BellFeatures.swift
// Limpid — which feedback channels fire when a pane rings the bell.
//
// The terminal setting maps onto the three channels Limpid implements:
// system audio, Dock attention, and the pane flash.

import Foundation

struct BellFeatures: OptionSet {
    let rawValue: Int

    /// macOS system beep (`NSSound.beep`).
    static let system = BellFeatures(rawValue: 1 << 0)
    /// Bounce the Dock icon (`NSApp.requestUserAttention`).
    static let attention = BellFeatures(rawValue: 1 << 1)
    /// Flash the originating pane for a moment.
    static let paneFlash = BellFeatures(rawValue: 1 << 2)

    /// How long a pane's bell-ring highlight stays lit. One constant so
    /// the libghostty bell handler and the manual `flashPane` helper
    /// agree on the duration — before it they drifted to 350ms and
    /// 400ms respectively, and either could win depending on the
    /// path the user took.
    static let paneFlashNanoseconds: UInt64 = 400_000_000

    static func forAction(_ action: BellAction) -> BellFeatures {
        switch action {
        case .none: []
        case .visual: [.attention, .paneFlash]
        case .audio: [.system]
        case .both: [.system, .attention, .paneFlash]
        }
    }
}
