// PrimaryKeyHint.swift
// Limpid — whether the decision bar's primary button still shows its "⌘⏎" hint.

import Foundation
import Observation

/// The small "⌘⏎" beside the decision bar's primary button, shown
/// until the person has pressed ⌘⏎ for that button three times: by then
/// they know the key, and the hint is only clutter.
///
/// Counted in the user defaults rather than a file of its own: it is one
/// number about the person, not their work, and losing it costs three
/// more glimpses of the hint.
@MainActor
@Observable
final class PrimaryKeyHint {
    static let usesBeforeHidden = 3
    static let defaultsKey = "primaryKeyHintUses"

    private(set) var uses: Int
    /// `nil` in demo mode: the count is kept in memory only.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        uses = defaults?.object(forKey: Self.defaultsKey) as? Int ?? 0
    }

    var isShown: Bool {
        uses < Self.usesBeforeHidden
    }

    /// ⌘⏎ performed the bar's primary button. Clicks do not count: they
    /// teach nothing about the key.
    func noteKeyUse() {
        guard isShown else { return }
        uses += 1
        defaults?.set(NSNumber(value: uses), forKey: Self.defaultsKey)
    }
}
