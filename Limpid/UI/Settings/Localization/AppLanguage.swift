// AppLanguage.swift
// Limpid — user-facing app language choice. Wires the Settings picker
// to both:
//   1. SwiftUI's `\.environment(\.locale, …)` — flips immediately
//      for everything inside the SwiftUI tree.
//   2. UserDefaults `AppleLanguages` — required for the AppKit menu
//      bar (NSApp menu) to follow. AppKit only reads this at process
//      start, so the Settings UI nudges the user to restart.

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow whatever the OS Region preferences dictate.
    case system
    case english
    case japanese

    var id: String {
        rawValue
    }

    var localizedTitle: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: String(localized: "English")
        case .japanese: String(localized: "日本語")
        }
    }

    /// SwiftUI `\.environment(\.locale, …)` value. `nil` for `.system`
    /// so SwiftUI inherits whatever the host environment resolves to.
    var locale: Locale? {
        switch self {
        case .system: nil
        case .english: Locale(identifier: "en")
        case .japanese: Locale(identifier: "ja")
        }
    }

    /// What to write into `UserDefaults["AppleLanguages"]`. AppKit
    /// reads this at process start; setting `nil` (handled by the
    /// caller with `removeObject(forKey:)`) reverts to OS default.
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .japanese: ["ja"]
        }
    }
}
