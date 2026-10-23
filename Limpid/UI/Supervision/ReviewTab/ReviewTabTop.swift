// ReviewTabTop.swift
// Limpid — the review tab's top edge: what it reads and whose turns, and how the diff is laid out.

import SwiftUI

/// The first lines of the review tab's top edge: "Review Scope" and
/// its menu, which chooses the conversation with the comparison, and under
/// them the notes that say what the comparison holds. The tab's own name is
/// in the pane strip and its Close is the band's, so neither is repeated
/// here.
struct ReviewTabScopeLine<Trailing: View>: View {
    let tab: ReviewTabState
    let handler: ReviewTabHandler
    var isScopeEnabled = true
    /// What the line ends with: the review's comment preview and Refresh,
    /// where there is a review.
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.locale) private var locale

    var body: some View {
        ReviewTabScopeLayout(notes: ReviewTabScopeNotes.make(tab, handler.context(tab), locale: locale)) {
            ReviewTabScopeMenu(tab: tab, handler: handler, isEnabled: isScopeEnabled)
        } trailing: {
            trailing()
        }
    }
}

/// What the top edge says under the scope, each on a line of its own,
/// in this order: that the range reads through viewed turns ("Includes 2
/// viewed turns"), and, in a worktree of two or more conversations, what
/// a turn's diff is, since another conversation's edits can fall between a
/// turn's two snapshots. Only while turns are read: the uncommitted changes
/// and the branch are not a turn's. Said once, here, and not on each file.
enum ReviewTabScopeNotes {
    static func make(_ tab: ReviewTabState, _ context: ReviewTabModel.Context, locale: Locale) -> [String] {
        guard case let .turns(range) = tab.scope else { return [] }
        let counts = ReviewScopeCatalog.counts(
            in: range,
            timeline: context.worktreeTurns,
            isViewed: context.isViewed,
            isRestored: context.isRestored
        )
        return [
            ReviewTabText.includesViewedTurns(counts.viewedTurns, locale: locale),
            context.conversations.count > 1 ? ReviewTabText.turnDiffNote(locale: locale) : nil
        ].compactMap(\.self)
    }
}

/// The top edge's first lines laid out from their parts, apart from what
/// fills them: the scope's line, and the notes under it. A choice of
/// scope that changes the notes moves nothing above them: the menu stays
/// where it was pressed.
struct ReviewTabScopeLayout<Scope: View, Trailing: View>: View {
    let notes: [String]
    @ViewBuilder var scope: () -> Scope
    @ViewBuilder var trailing: () -> Trailing

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Layout.reviewTabTopSpacing) {
                scope()
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                trailing()
            }
            .padding(.horizontal, Layout.reviewTabTopInset)
            .frame(height: Layout.reviewTabTopRowHeight)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceXS) {
                    ForEach(notes, id: \.self) { note in
                        Text(verbatim: note)
                            .font(.supervision(.meta))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.reviewScopeNoteInsets)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "Unified | Side by Side" at the top of the review tab: the two
/// layouts as words, in the window's segmented control, so the layout in
/// use is marked, and moved by ← →, as the file list's layout is. Off while
/// a comment is being written, which would move the run it is about into
/// the other column, or out of a column entirely.
struct ReviewTabLayoutSwitch: View {
    @Binding var layout: ReviewDiffLayout
    let isDisabled: Bool

    var body: some View {
        SupervisionSegmentedPicker(
            Text("Diff Layout"),
            selection: $layout,
            options: [
                .init(.unified, Text("Unified")),
                .init(.sideBySide, Text("Side by Side"))
            ],
            isCompact: true
        )
        .fixedSize()
        .disabled(isDisabled)
        .help(Text("Diff Layout"))
    }
}
