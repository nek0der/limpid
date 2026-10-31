// PendingOpens.swift
// Weir — holds what is handed to Weir to open until launching has finished.

import Foundation

/// The URLs handed to Weir from outside (Finder's Open With, `open -a`, a
/// drop on the Dock icon) and when to open them. AppKit hands over what
/// Weir was launched to open before `applicationDidFinishLaunching`,
/// while the restored windows are not out yet; those are held and opened
/// once, after the windows, so the folder lands in front of them. Anything
/// handed over later opens at once.
struct PendingOpens {
    private var held: [URL] = []
    private(set) var hasFinishedLaunching = false

    /// What to open now: `urls` once launching has finished, else nothing,
    /// as they are held for `finishLaunching`.
    mutating func receive(_ urls: [URL]) -> [URL] {
        guard hasFinishedLaunching else {
            held += urls
            return []
        }
        return urls
    }

    /// Everything held, in the order it arrived, handed over once.
    mutating func finishLaunching() -> [URL] {
        hasFinishedLaunching = true
        defer { held = [] }
        return held
    }
}
