// OpenTabsModel.swift
// Limpid — Open Tabs: the session's tabs as the pane strip's leading button lists them, narrowed by a search.

import Foundation

/// The rows of Open Tabs, the list the pane strip's leading button opens:
/// the session's terminal tabs in the strip's order, then the review's tab
/// while one is open, each with a line that says who runs in it and in
/// what state. It is built from the strip's own model, so a row and its
/// tab never disagree. A search keeps the rows whose title or line holds
/// every word typed, so "approval" finds the tabs waiting for one.
struct OpenTabsModel: Equatable {
    enum RowID: Hashable {
        case terminal(UUID)
        case review
    }

    enum RowKind: Equatable {
        /// A terminal tab, as the strip draws it.
        case terminal(PaneStripModel.Item)
        /// The review's tab.
        case review
    }

    struct Row: Identifiable, Equatable {
        let id: RowID
        let kind: RowKind
        let title: String
        /// Who runs in the tab and its state, and how many panes a split tab
        /// has ("Claude · Needs approval", "Shell · 2 panes"); "Review" for
        /// the review's tab.
        let detail: String
        /// Whether the window shows this tab.
        let isCurrent: Bool
        /// What VoiceOver says for the row: the strip's tab's words, and the
        /// panes the line says.
        let spokenLabel: String

        var item: PaneStripModel.Item? {
            guard case let .terminal(item) = kind else { return nil }
            return item
        }
    }

    /// The terminal tabs' rows, in the strip's order.
    let terminalRows: [Row]
    /// The review's row, after a rule, while the review is open.
    let reviewRow: Row?

    /// Every row, in the order the arrow keys walk them.
    var rows: [Row] {
        terminalRows + (reviewRow.map { [$0] } ?? [])
    }

    /// `strip`'s tabs, with the review's titled `reviewTitle` (its scope),
    /// kept to those `query` matches.
    init(strip: PaneStripModel, reviewTitle: String?, query: String, locale: Locale) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        terminalRows = strip.items.map { item in
            Row(
                id: .terminal(item.id),
                kind: .terminal(item),
                title: item.title,
                detail: Self.detail(of: item, locale: locale),
                isCurrent: item.isActive,
                spokenLabel: AgentStatusText.spokenList(
                    [item.spokenLabel(locale: locale)] + Self.panes(of: item, locale: locale),
                    locale: locale
                )
            )
        }
        .filter { Self.matches($0, words: words) }
        if strip.showsReviewTab, let reviewTitle {
            let detail = LocalizedStringResource("Review").resolved(in: locale)
            let row = Row(
                id: .review,
                kind: .review,
                title: reviewTitle,
                detail: detail,
                isCurrent: strip.reviewTab == .inFront,
                spokenLabel: AgentStatusText.spokenList([reviewTitle, detail], locale: locale)
            )
            reviewRow = Self.matches(row, words: words) ? row : nil
        } else {
            reviewRow = nil
        }
    }

    /// The row's second line: the strip's tooltip lines ("Claude · Running /
    /// Codex · Needs approval"), every agent named, so a search finds a tab by
    /// any of them; and the panes of a split tab, which the strip does not
    /// show.
    static func detail(of item: PaneStripModel.Item, locale: Locale) -> String {
        let agents = SessionRowFactText.agentList(item.agentLines(locale: locale), locale: locale)
        return AgentStatusText.joined([agents] + panes(of: item, locale: locale), locale: locale)
    }

    /// "2 panes" for a split tab, which the strip does not say; nothing for
    /// a tab of one pane.
    private static func panes(of item: PaneStripModel.Item, locale: Locale) -> [String] {
        guard item.paneCount > 1 else { return [] }
        return [LocalizedStringResource("\(item.paneCount) panes").resolved(in: locale)]
    }

    /// Every word is in the title or the line, in any case: words, not a
    /// phrase, so "claude review" finds the Claude tab named "review".
    static func matches(_ row: Row, words: [String]) -> Bool {
        words.allSatisfy { word in
            row.title.localizedCaseInsensitiveContains(word) || row.detail.localizedCaseInsensitiveContains(word)
        }
    }
}
