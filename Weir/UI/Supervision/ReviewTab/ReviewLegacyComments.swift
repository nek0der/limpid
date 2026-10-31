// ReviewLegacyComments.swift
// Weir — the comments from before scopes, read only in the review tab until the reader moves one into the scope on screen.

import SwiftUI

/// "Comments from an earlier review": the comments the review tab has no
/// scope to show in (`ReviewComment.isLegacy`), written against the "This
/// turn" scope of earlier builds or before scopes were kept. Read only,
/// folded by default, each with "Move to This Scope", which places it where
/// the code it quotes is in the scope on screen, or says why it cannot
/// (`ReviewSession.moveLegacyComment`). Nothing moves a comment on its own.
struct ReviewLegacyComments: View {
    let reviewSession: ReviewSession
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.reviewTabHandler) private var handler
    @Environment(ToastCenter.self) private var toastCenter
    /// Kept beside the window (`ReviewTabViewState`).
    @State private var isExpanded = false
    /// The comment being moved, while Git checks it: one move at a time,
    /// and the same one not twice.
    @State private var movingID: UUID?

    /// Whether the review shows the scope the tab names, which is where a
    /// moved comment goes; while it loads, or after a load failed, the
    /// review's scope is not the one on screen.
    private var canMove: Bool {
        guard movingID == nil, !reviewSession.isLoading, let tab = window.review, let handler else { return false }
        return handler.isShowingItsScope(tab)
    }

    var body: some View {
        let comments = reviewSession.legacyComments.filter { !$0.isResolved }
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: WeirLayout.Supervision.spaceSnug) {
                        Image(systemName: "chevron.right")
                            .font(.supervision(.glyph, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        Text("Comments from an earlier review (\(comments.count))")
                            .font(.supervision(.row))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
                if isExpanded {
                    ForEach(comments) { comment in
                        row(comment)
                    }
                }
            }
            .padding(.horizontal, WeirLayout.Supervision.spaceM)
            .padding(.vertical, WeirLayout.Supervision.spaceSnug)
            .background(WeirColor.reviewAsideBackground)
            .overlay(alignment: .bottom) {
                SupervisionTokens.line.color.frame(height: 0.5)
            }
            .keptInReviewTab($isExpanded, as: \.areEarlierCommentsExpanded)
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
            VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceHairline) {
                Text(verbatim: location(comment))
                    .font(.supervisionCode(beside: .meta))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .supervisionTruncation(.path)
                Text(verbatim: comment.body)
                    .font(.supervision(.row))
                    .lineLimit(2)
            }
            Spacer(minLength: WeirLayout.Supervision.spaceS)
            // A comment that cannot be moved can still be put away, which
            // is how it stops counting toward the draft's limits. Resolved,
            // it leaves this section, so Undo is the way back to it.
            Button("Resolve") {
                resolve(comment)
            }
            .controlSize(.small)
            Button("Move to This Scope") {
                move(comment)
            }
            .controlSize(.small)
            .disabled(!canMove)
            .help(Text("Places the comment where the code it quotes is in this scope"))
        }
        .padding(.vertical, WeirLayout.Supervision.spaceXS)
        // Named for its place, so its two buttons say which comment they act on.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: location(comment)))
    }

    private func resolve(_ comment: ReviewComment) {
        let session = reviewSession
        session.setResolved(comment.id, true)
        toastCenter.show(ToastItem(
            message: .localized("Resolved \(1) comments."),
            undo: { session.setResolved(comment.id, false) }
        ), in: window.id)
    }

    private func move(_ comment: ReviewComment) {
        let session = reviewSession
        let target = session.scope
        movingID = comment.id
        Task {
            defer { movingID = nil }
            do {
                try await session.moveLegacyComment(comment.id, to: target)
            } catch is CancellationError {
                // The review moved on; the comment stays where it was.
            } catch {
                session.report(error)
            }
        }
    }

    private func location(_ comment: ReviewComment) -> String {
        guard let line = comment.anchor.newLine ?? comment.anchor.oldLine else { return comment.file.path }
        return "\(comment.file.path):\(line)"
    }
}
