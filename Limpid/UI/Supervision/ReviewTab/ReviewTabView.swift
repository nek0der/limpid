// ReviewTabView.swift
// Limpid — the review tab's surface: the window's review where the terminal was.

import SwiftUI

/// The review tab of a supervision window, drawn in place of the terminal
/// it was opened from: the review, and the band at its foot in the row the
/// decision bar has in the pane. It docks no terminal and changes none: the
/// panes it covers are not drawn while it shows, so each keeps its columns
/// and rows.
struct ReviewTabView: View {
    let tab: ReviewTabState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.reviewTabHandler) private var handler

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if tab.scope == nil {
                    // No unviewed turns, or a record that lost a snapshot: the
                    // tab says so rather than read a comparison that does not
                    // exist. Over it stands the same top edge as over a
                    // review, whose scope menu reaches another comparison,
                    // every conversation's included.
                    VStack(spacing: 0) {
                        if let handler {
                            ReviewTabScopeLine(tab: tab, handler: handler) {
                                EmptyView()
                            }
                            .overlay(alignment: .bottom) {
                                SupervisionTokens.line.color
                                    .frame(height: 1)
                                    .accessibilityHidden(true)
                            }
                        }
                        SupervisionEmptyState(ReviewTabText.emptyScope(tab.selection), size: .regular)
                    }
                } else {
                    ReviewPane(
                        directory: URL(fileURLWithPath: tab.root, isDirectory: true),
                        available: geometry.size.width,
                        onClose: { handler?.close() },
                        session: window.reviewSession
                    )
                    .environment(\.reviewTabOpening, tab.opening)
                    .environment(\.isReviewInFront, tab.isShown)
                    // Only where they are part of what is read: the
                    // uncommitted changes.
                    .environment(\.reviewPathsOutsideTurns, tab.scope == .uncommitted ? handler?.pathsOutsideTurns(tab) ?? [] : [])
                    .environment(\.reviewFileTags, handler?.fileTags(tab) ?? ReviewFileTagSet())
                    // Each turn's files are read once, as the range opens; the
                    // tags come in as they are.
                    .task(id: tab.scope) {
                        await handler?.loadFileTagPaths(tab)
                    }
                }
            }
            // With a comparison, the review draws the band, which carries
            // its insert (`ReviewWorkspaceView`).
            if tab.scope == nil, let handler {
                ReviewTabBand(tab: tab, reviewSession: window.reviewSession, handler: handler)
            }
        }
        // Again each time the review reads its list, which is when the
        // worktree was last looked at (opening another file reads none).
        // Every agent's turns in the worktree count, so the tab's
        // conversation changes nothing.
        .task(id: OutsideTurnsRead(
            opening: tab.opening,
            listReads: window.reviewSession?.listReadCount ?? 0
        )) {
            await handler?.refreshPathsOutsideTurns()
        }
    }

    private struct OutsideTurnsRead: Equatable {
        let opening: UUID
        let listReads: Int
    }
}

extension EnvironmentValues {
    /// Whether the review is in front of the person. Behind a terminal tab
    /// the review tab keeps its place but stops asking Git and the panes,
    /// which only describe a screen no one is looking at.
    @Entry var isReviewInFront = true
    /// The opening of the review tab drawn (`ReviewTabState.opening`), `nil`
    /// outside the review tab.
    @Entry var reviewTabOpening: UUID?
    /// The paths the stacked diff's headers mark "Changed Outside Turns".
    @Entry var reviewPathsOutsideTurns: Set<String> = []
    /// The conversations whose turns changed each file of a range, by path
    /// (`ReviewFileTags`): the stacked diff's headers tag them.
    @Entry var reviewFileTags = ReviewFileTagSet()
}
