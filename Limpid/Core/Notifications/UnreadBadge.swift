// UnreadBadge.swift
// Limpid — the text an unread-count badge shows.

import Foundation

enum UnreadBadge {
    /// Past two digits the badge says "99+". The toolbar bell and the
    /// history header disagreed — one capped at a bare 99, which reads as
    /// an exact count — so both read this.
    static func text(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}
