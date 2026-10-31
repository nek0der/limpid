// DockBadge.swift
// Weir — what the Dock icon's badge shows: the attention count, or a dot for other news.

import Foundation

/// The Dock icon's badge.
package enum DockBadge: Equatable, Sendable {
    case none
    /// The attention count, the same number as "Needs attention n"
    /// everywhere else.
    case count(Int)
    /// Nothing needs attention, but a command notification (OSC 9 / 777, a
    /// long command finishing) is unread or a bell rang unseen. Shown as a
    /// dot so the Dock never counts what the attention list does not.
    case dot

    /// The badge for `attentionCount` items, with `hasOtherNews` when a
    /// non-agent notification or a bell is waiting.
    package static func badge(attentionCount: Int, hasOtherNews: Bool) -> Self {
        if attentionCount > 0 {
            return .count(attentionCount)
        }
        return hasOtherNews ? .dot : .none
    }

    /// The text AppKit puts in the badge; `nil` clears it.
    package var label: String? {
        switch self {
        case .none: nil
        case let .count(count): String(count)
        case .dot: "\u{2022}"
        }
    }
}
