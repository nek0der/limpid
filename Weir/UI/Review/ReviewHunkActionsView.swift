// ReviewHunkActionsView.swift
// Weir — the buttons on a review hunk's header: Comment, Discard, and Undo Discard.

import SwiftUI

/// A hunk header's "Comment", and its "Discard" or what became of it:
/// "Discarded" and "Undo Discard", or why it was not. A reason the
/// action is off shows as its tooltip and its VoiceOver hint; what went
/// wrong shows beside it.
struct ReviewHunkActionsView: View {
    /// What the header's buttons do.
    struct Handlers {
        var onComment: () -> Void = {}
        var onDiscard: () -> Void = {}
        var onUndo: () -> Void = {}
    }

    let action: ReviewHunkAction?
    let isCommentable: Bool
    /// The hunk's `@@` line, which tells VoiceOver's list of buttons one
    /// hunk's "Comment" from another's.
    var header = ""
    var handlers = Handlers()
    /// Handed over by the table, whose rows are AppKit (`ReviewHosted`).
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceXS) {
            if isCommentable {
                styled(Button(ReviewHunkCommentText.comment(locale: locale), action: handlers.onComment), tone: .ghost)
                    .accessibilityLabel(Text(verbatim: ReviewHunkCommentText.commentLabel(header: header, locale: locale)))
                    .help(Text(verbatim: ReviewHunkCommentText.commentHelp(locale: locale)))
                    .accessibilityHint(Text(verbatim: ReviewHunkCommentText.commentHelp(locale: locale)))
            }
            switch action {
            case nil:
                EmptyView()
            case let .discard(blockedReason):
                discardButton(blockedReason: blockedReason)
            case .running:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(Text(verbatim: ReviewHunkDiscardText.discarding(locale: locale)))
            case let .discarded(blockedReason, text):
                if let text {
                    note(text)
                }
                Text(verbatim: ReviewHunkDiscardText.discarded(locale: locale))
                    .font(.supervision(.detail, weight: .medium))
                    .foregroundStyle(SupervisionTokens.muted.color)
                styled(Button(ReviewHunkDiscardText.undoDiscard(locale: locale), action: handlers.onUndo), tone: .standard)
                    .disabled(blockedReason != nil)
                    .help(Text(verbatim: blockedReason ?? ""))
                    .accessibilityHint(Text(verbatim: blockedReason ?? ""))
            case let .uncertain(blockedReason, text):
                note(text)
                styled(Button(ReviewHunkDiscardText.undoDiscard(locale: locale), action: handlers.onUndo), tone: .standard)
                    .disabled(blockedReason != nil)
                    .help(Text(verbatim: blockedReason ?? ""))
                    .accessibilityHint(Text(verbatim: blockedReason ?? ""))
            case let .failed(message, blockedReason):
                note(message)
                discardButton(blockedReason: blockedReason)
            }
        }
        .fixedSize()
    }

    /// The window's button at its mini size, on the header's opaque ground.
    private func styled(_ button: Button<Text>, tone: SupervisionSecondaryButtonStyle.Tone) -> some View {
        button.buttonStyle(.supervisionSecondary(size: .mini, tone: tone))
    }

    /// Only the review tab offers "Discard"; it takes the look every
    /// destructive action shares, at the header's size.
    private func discardButton(blockedReason: String?) -> some View {
        Button(ReviewHunkDiscardText.discard(locale: locale), action: handlers.onDiscard)
            .buttonStyle(SupervisionDestructiveButtonStyle(size: .mini))
            .disabled(blockedReason != nil)
            .help(Text(verbatim: blockedReason ?? ReviewHunkDiscardText.discardHelp(locale: locale)))
            .accessibilityHint(Text(verbatim: blockedReason ?? ReviewHunkDiscardText.discardHelp(locale: locale)))
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.supervision(.detail))
            .foregroundStyle(SupervisionTokens.text.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 360, alignment: .trailing)
            .help(Text(verbatim: text))
    }
}
