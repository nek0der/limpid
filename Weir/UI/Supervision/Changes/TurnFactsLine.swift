// TurnFactsLine.swift
// Weir — a turn card's second line: its facts in columns the list keeps in line.

import SwiftUI

/// A card's second line: what the turn changed, then its checks, tokens,
/// and duration, each in a column as wide as the widest of the cards shown
/// (`TurnFactColumns`), so they stand in line from card to card. The changes give way first where the
/// panel is narrow; they cut short rather than wrap, and the tooltip has
/// them whole. A card that says its state in words instead lets them take
/// the room of a column it leaves empty.
struct TurnFactsLine: View {
    let facts: ChangesPanelText.Facts
    @Environment(\.locale) private var locale
    @Environment(\.turnFactColumns) private var columns

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.turnFactSpacing) {
            changes
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isWordsAlone {
                ReceiptRunsText(runs: facts.checks, size: .caption)
                    .fixedSize()
                    .reportingTurnFactColumn(\.checks)
                    .turnFactColumn(\.checks, least: Layout.turnChecksMinWidth, in: columns, alignment: .leading)
            }
            Group {
                if let tokens = facts.tokens {
                    // The unit rather than a glyph: no symbol says "tokens"
                    // at a glance.
                    HStack(alignment: .firstTextBaseline, spacing: Layout.spaceHairline) {
                        figures(tokens)
                        Text(verbatim: ChangesPanelText.tokenUnit(locale: locale))
                            .font(.supervision(.caption))
                            .foregroundStyle(SupervisionTokens.muted.color)
                    }
                    .fixedSize()
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .reportingTurnFactColumn(\.tokens)
            .turnFactColumn(\.tokens, least: Layout.turnTokensMinWidth, in: columns, alignment: .trailing)
            // The first fact to go where the changes would not fit whole
            // (`TurnFactColumns.showsDuration`); the tooltip keeps it.
            if columns.showsDuration {
                duration
                    .turnFactColumn(\.duration, least: Layout.turnDurationMinWidth, in: columns, alignment: .trailing)
            }
        }
        // What the card would need whole, measured apart from how it is
        // laid out, so dropping the duration never changes the answer.
        .background {
            ZStack {
                changes.fixedSize().reportingTurnFactColumn(isWordsAlone ? \.words : \.changes)
                duration.reportingTurnFactColumn(\.duration)
            }
            .hidden()
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TurnFactColumnsKey.self, value: TurnFactColumns(line: proxy.size.width))
            }
        }
        // The row's sentence says every fact (`ChangesPanelText.rowSpoken`).
        .accessibilityHidden(true)
    }

    /// The card says its state in words and ran no checks: the words take
    /// the checks' column too.
    private var isWordsAlone: Bool {
        facts.isStatus && facts.checks.isEmpty
    }

    /// What the turn changed: the file count beside its glyph, then the
    /// counts or the state in words.
    private var changes: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.spaceHairline) {
            if let files = facts.files {
                glyph("doc")
                Text(verbatim: files.formatted(.number.locale(locale)))
                    .font(.supervision(.caption).monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .padding(.trailing, Layout.spaceHairline)
            }
            ReceiptRunsText(runs: facts.changes, size: .caption)
        }
    }

    @ViewBuilder private var duration: some View {
        if let duration = facts.duration {
            HStack(alignment: .firstTextBaseline, spacing: Layout.spaceHairline) {
                glyph("timer")
                figures(duration)
            }
            .fixedSize()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func figures(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.supervision(.caption).monospacedDigit())
            .foregroundStyle(SupervisionTokens.muted.color)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.supervision(.glyph))
            // A mark that says which count is which, so held to 3:1 as
            // marks are, which `faint` is not.
            .foregroundStyle(SupervisionTokens.closedMark.color)
    }
}

/// The widths of the fact columns a turn card's second line holds after its
/// changes, the widest of the cards the list draws, and whether the
/// duration has room. Each card reports its own (`TurnFactColumnsKey`) and
/// lays its columns out at the list's, so a card with a longer count or none
/// at all does not move the marks of the cards around it.
struct TurnFactColumns: Equatable {
    var checks: CGFloat = 0
    var tokens: CGFloat = 0
    var duration: CGFloat = 0
    /// The widest changes, file count and glyph included, as they would
    /// read whole.
    var changes: CGFloat = 0
    /// The widest state in words ("No file changes") of a card that ran no
    /// checks, which takes the checks' room too.
    var words: CGFloat = 0
    /// The narrowest second line; 0 while no card has said.
    var line: CGFloat = 0

    private typealias Layout = WeirLayout.Supervision

    func widest(_ other: Self) -> Self {
        Self(
            checks: max(checks, other.checks),
            tokens: max(tokens, other.tokens),
            duration: max(duration, other.duration),
            changes: max(changes, other.changes),
            words: max(words, other.words),
            line: [line, other.line].filter { $0 > 0 }.min() ?? 0
        )
    }

    /// Whether the cards show their duration: only while every card's
    /// changes would still read whole beside it. The changes are what a
    /// card is for; the duration is the fact the tooltip can carry alone.
    /// Decided for the whole list, so the columns stay in line.
    var showsDuration: Bool {
        guard line > 0 else { return true }
        let changesAndChecks = max(changes + max(checks, Layout.turnChecksMinWidth) + Layout.turnFactSpacing, words)
        let needed = changesAndChecks
            + max(tokens, Layout.turnTokensMinWidth)
            + max(duration, Layout.turnDurationMinWidth)
            + 2 * Layout.turnFactSpacing
        return needed <= line
    }
}

struct TurnFactColumnsKey: PreferenceKey {
    static let defaultValue = TurnFactColumns()

    static func reduce(value: inout TurnFactColumns, nextValue: () -> TurnFactColumns) {
        value = value.widest(nextValue())
    }
}

/// The list's shared fact columns, held apart from the list: the columns
/// change as cards scroll in and out, and the list's own body, which builds
/// every row, should not run again each time they do.
struct SharedTurnFactColumns: ViewModifier {
    @State private var columns = TurnFactColumns()

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TurnFactColumnsKey.self) { columns = $0 }
            .environment(\.turnFactColumns, columns)
    }
}

extension EnvironmentValues {
    /// The list's fact columns (`TurnFactColumns`); none outside the list,
    /// where each card's columns take their least widths.
    @Entry var turnFactColumns = TurnFactColumns()
}

private extension View {
    /// Reports this view's width to the list as the card's `column`.
    func reportingTurnFactColumn(_ column: WritableKeyPath<TurnFactColumns, CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TurnFactColumnsKey.self, value: {
                    var own = TurnFactColumns()
                    own[keyPath: column] = proxy.size.width
                    return own
                }())
            }
        }
    }

    /// The column `column` of a card's facts, laid out at the list's widest
    /// and never under `least`.
    func turnFactColumn(
        _ column: KeyPath<TurnFactColumns, CGFloat>,
        least: CGFloat,
        in columns: TurnFactColumns,
        alignment: Alignment
    ) -> some View {
        frame(minWidth: max(least, columns[keyPath: column]), alignment: alignment)
            .layoutPriority(1)
    }
}
