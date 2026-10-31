// NeedsAttentionPillModel.swift
// Weir — what the title bar's "Needs Attention n" says, and how loudly.

import Foundation

/// The title bar's attention count. It never disappears:
/// at zero it reads "Needs Attention 0", faint and unfilled, so the place
/// the count lives does not move.
struct NeedsAttentionPillModel: Equatable {
    enum Style: Equatable {
        /// Something blocks on the person (an approval, a question, a wait
        /// at the agent's prompt, a stop): the amber chip.
        case blocking
        /// Only finished turns nobody has read: the blue chip, so amber
        /// keeps meaning "stopped until you act".
        case unreadOnly
        /// Nothing: faint, with no fill.
        case empty
    }

    let count: Int
    let style: Style
    let counts: AttentionCounts

    init(_ counts: AttentionCounts) {
        self.counts = counts
        count = counts.total
        style = counts.hasBlockingItems ? .blocking : counts.total > 0 ? .unreadOnly : .empty
    }

    var label: LocalizedStringResource {
        Self.label(count)
    }

    /// "Needs Attention · 3", wherever the count is named: the pill, the
    /// project menu's rows, and the banner after the Mac wakes.
    static func label(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "Needs Attention · \(count)",
            comment: "The attention count: the title bar pill, the project menu, and the notification after the Mac wakes"
        )
    }

    /// "Needs Attention list (⌃⌘J; Next Action: ⌘J) · 1 Approval · 2 Unread".
    /// A shortcut the person has unbound is left out rather than shown
    /// empty; the breakdown lists only the kinds that have items.
    func tooltip(listShortcut: String?, nextShortcut: String?, locale: Locale) -> String {
        let head = switch (listShortcut, nextShortcut) {
        case let (list?, next?):
            LocalizedStringResource(
                "Needs Attention list (\(list); Next Action: \(next))",
                comment: "Title bar pill tooltip; the shortcut that opens the list, the shortcut for the next item"
            )
        case let (list?, nil):
            LocalizedStringResource("Needs Attention list (\(list))", comment: "Title bar pill tooltip; the shortcut that opens the list")
        case let (nil, next?):
            LocalizedStringResource(
                "Needs Attention list (Next Action: \(next))",
                comment: "Title bar pill tooltip; the shortcut for the next item"
            )
        case (nil, nil):
            LocalizedStringResource("Needs Attention list", comment: "Title bar pill tooltip with no shortcuts bound")
        }
        let parts = [head.resolved(in: locale)] + AttentionSummaryText.breakdown(counts, locale: locale)
        return AgentStatusText.joined(parts, locale: locale)
    }
}
