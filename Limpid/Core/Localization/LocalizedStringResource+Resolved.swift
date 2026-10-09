// LocalizedStringResource+Resolved.swift
// Limpid — the one place localized text is resolved to a `String`.
//
// `String(localized:)` answers in the language the process launched with,
// however late it is called, so a `String` resolved that way stays in the
// old language after the user switches Display Language in Settings. Models
// carry `LocalizedStringResource`, views hand it to SwiftUI, and text that
// has to be a `String` comes through here with the environment or app
// locale. The `launch_language_lookup` lint rule keeps the raw lookup out of
// every other file.

import Foundation

extension LocalizedStringResource {
    /// This string in `locale`'s language. SwiftUI's `\.locale` carries the
    /// language chosen in Settings from the moment it is picked, while a
    /// plain lookup answers in the language the process launched with; text
    /// that has to be a `String` (an AppKit menu, an accessibility join, a
    /// search index) resolves through here to switch with the rest of the
    /// window.
    func resolved(in locale: Locale) -> String {
        var resource = self
        resource.locale = locale
        return String(localized: resource)
    }
}

extension Locale {
    /// English, for search aliases that match the English name whatever
    /// language the app shows.
    static let english = Locale(identifier: "en")
}
