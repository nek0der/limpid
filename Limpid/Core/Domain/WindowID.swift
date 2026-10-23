// WindowID.swift
// Limpid — the identity of one main window, kept across relaunches.

import Foundation

/// One main window. A UUID of our own rather than `NSWindow.windowNumber`,
/// which AppKit reassigns on every launch, so a window's saved selection
/// can find its window again after a relaunch.
struct WindowID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
