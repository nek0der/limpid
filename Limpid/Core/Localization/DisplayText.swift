// DisplayText.swift
// Limpid — user-facing text that is either Limpid's own localized string
// or text we show as is, kept unresolved until it is drawn.

import Foundation

/// Text for the user that is either one of our catalog strings or text we
/// cannot localize ourselves (a user's own words, a system error message).
/// A store keeps this instead of a resolved `String` so a toast or banner
/// that is already on screen switches with the display language: SwiftUI
/// draws `.localized` in the window's `\.locale`, while a `String` resolved
/// when the store was written stays in the language of that moment.
///
/// Deliberately not expressible by a string literal. A literal would make
/// every `Text("…")` in the app prefer the `Text(display:)` overload and
/// reach SwiftUI as a runtime `String`, which the string catalog's
/// extraction never sees; spelling `.localized("…")` keeps each literal a
/// typed `LocalizedStringResource`, which it does see.
enum DisplayText: Equatable, Sendable {
    case localized(LocalizedStringResource)
    case verbatim(String)

    /// What to show for `error`. Limpid's own errors carry their message
    /// unresolved and follow the display language; anything else shows the
    /// message the system gave it.
    init(error: any Error) {
        if let error = error as? any LimpidLocalizedError {
            self = error.message
        } else {
            self = .verbatim(error.localizedDescription)
        }
    }

    /// This text as a `String` in `locale`'s language, for the places that
    /// need one (an accessibility join, an AppKit control).
    func resolved(in locale: Locale) -> String {
        switch self {
        case let .localized(resource): resource.resolved(in: locale)
        case let .verbatim(text): text
        }
    }
}
