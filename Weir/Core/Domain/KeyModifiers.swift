// KeyModifiers.swift
// Weir — the four modifier keys a key rule or a saved shortcut reads, free of AppKit.

import Foundation

/// These are the modifier keys we act on: ⌘, ⇧, ⌥, and ⌃. We keep a set of
/// our own rather than `NSEvent.ModifierFlags`, whose raw values are AppKit's and can
/// shift across SDK revisions, so a saved shortcut decodes the same on
/// every build and a key rule can be tested without AppKit. Caps Lock,
/// the function key, and the rest are not here: nothing binds to them.
///
/// Saved shortcuts store `rawValue` as a single `UInt8`
/// (`StoredShortcut.modifiers`), so the bits never change meaning. The
/// conversions from and to AppKit and SwiftUI live in the files that
/// already import them (`KeyboardShortcut+Capture.swift`,
/// `StoredShortcut+AppKitMenu.swift`, `KeyboardShortcut.swift`).
struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)
}
