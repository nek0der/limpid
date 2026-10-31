// DurationText.swift
// Weir — how long a command ran, as its notification and its history row say it.

import Foundation

/// How long a command ran: "48.2s" under a minute, then "2m 14s", in the
/// locale's own units and decimal separator. A format string such as
/// `"%.1fs"` pinned the C locale's "." and English units, so comma-decimal
/// locales read "1,5s" as "15s" and Japanese showed "1.5s" amid translated
/// words. The banner's body and the history's row say it the same way.
enum DurationText {
    /// `locale` is the one the sentence around it is resolved in.
    static func command(_ seconds: Double, locale: Locale) -> String {
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))
                    .locale(locale)
            )
        }
        // Whole seconds past a minute: "2m 14s", not "2m 14.6s".
        return Duration.seconds(Int(seconds)).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow)
                .locale(locale)
        )
    }
}
