// LimpidLocalizedError.swift
// Limpid — errors whose message follows the display language.

import Foundation

/// An error whose message Limpid writes: one of our catalog strings, or
/// text from a tool we ran (git's stderr) shown as is.
///
/// `LocalizedError.errorDescription` is a `String`, resolved in the
/// language the process launched with, so a view that showed it would not
/// switch with the display language. Views read `message` (usually through
/// `DisplayText(error:)`) instead; `errorDescription` stays for logs and for
/// system code that only knows `localizedDescription`.
protocol LimpidLocalizedError: LocalizedError {
    var message: DisplayText { get }
}

extension LimpidLocalizedError {
    /// `Locale.current` carries the launch language, which is what
    /// `localizedDescription` has always answered in.
    var errorDescription: String? {
        message.resolved(in: .current)
    }
}
