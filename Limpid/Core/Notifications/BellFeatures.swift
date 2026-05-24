// BellFeatures.swift
// Limpid — which feedback channels fire when a pane rings the bell.
//
// Mirrors Ghostty's `BellFeatures` packed struct (near "BellFeatures"
// in `vendor/ghostty/src/config/Config.zig`; line numbers shift with
// upstream so we don't pin one). Defaults are hard-coded today and
// will become per-profile once the preferences UI exposes them.

import Foundation

struct BellFeatures: OptionSet {
    let rawValue: Int

    /// macOS system beep (`NSSound.beep`).
    static let system = BellFeatures(rawValue: 1 << 0)
    /// Play a user-supplied audio file at `Limpid.bellAudioPath`. Not
    /// wired yet.
    static let audio = BellFeatures(rawValue: 1 << 1)
    /// Bounce the Dock icon (`NSApp.requestUserAttention`).
    static let attention = BellFeatures(rawValue: 1 << 2)
    /// Mark the bell on the tab title (icon prefix until focus
    /// returns). Not wired yet.
    static let title = BellFeatures(rawValue: 1 << 3)
    /// Flash the originating pane's border for a moment.
    static let border = BellFeatures(rawValue: 1 << 4)

    /// Defaults applied when no per-profile override is set.
    static let `default`: BellFeatures = [.system, .attention, .border]
}
