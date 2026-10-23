// SystemAppearance.swift
// Limpid — the system's light or dark appearance, read from the global defaults, and the notice of its change.

import Foundation

/// The OS Appearance setting, as the global defaults hold it: the
/// `AppleInterfaceStyle` key is "Dark" in dark mode and absent in light, and
/// the system rewrites it when Auto switches, announcing it on the
/// distributed notification `AppleInterfaceThemeChangedNotification`. Read
/// from the defaults rather than `NSApp.effectiveAppearance`, so it can be
/// asked before NSApplication has finished its appearance graph, and so it
/// stays the system's when Limpid pins its own windows to another one.
/// The one reading for the terminals' color scheme (`GhosttyApp`) and the
/// menu bar extra (`MenuBarAppearance`).
enum SystemAppearance {
    static let interfaceStyleKey = "AppleInterfaceStyle"
    static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

    /// Whether `interfaceStyle`, the defaults' value, is the dark appearance.
    /// Without regard to case: the system writes "Dark", and a value it
    /// might spell otherwise still means dark.
    static func isDark(interfaceStyle: String?) -> Bool {
        interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    /// Whether the system is in its dark appearance now, as `defaults`
    /// (the standard ones, which see the global domain) say.
    static func isSystemDark(defaults: UserDefaults = .standard) -> Bool {
        isDark(interfaceStyle: defaults.string(forKey: interfaceStyleKey))
    }
}
