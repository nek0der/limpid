// ReviewChrome.swift
// Weir — the review's snapshot buttons and the banners above its diff.
//
// Their own file rather than more of `ReviewPane`: none of them reads the
// diff, and the workspace they were written inside had outgrown what one file
// should hold.

import SwiftUI

/// The two buttons about the snapshot: the comments it would insert, as a
/// count that opens their preview, and Refresh. The count says what it
/// counts, "1 Comment": a bubble and a bare number read as anything. Set closer than the rest of
/// a row so they read as a pair; on its own with the row's spacing on both
/// sides, the comment count floated between the numbers and the icon. The
/// review tab's top edge carries them.
struct ReviewSnapshotButtons: View {
    let reviewSession: ReviewSession
    let isInserting: Bool
    let prompt: String
    @Binding var isShowingPrompt: Bool
    let onRefresh: () -> Void
    let onJump: (ReviewComment) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceXS) {
            commentPill
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
        }
        .fixedSize()
        .accessibilityLabel(Text("Refresh"))
        .help(Text("Refresh"))
        .disabled(reviewSession.isLoading || isInserting)
    }

    private var commentPill: some View {
        Button {
            isShowingPrompt.toggle()
        } label: {
            Text(
                "\(reviewSession.insertableComments.count) Comments",
                comment: "Review tab, top right: the comments to insert, opening their preview; argument: their count, as 'コメント 1'"
            )
            .font(.caption.monospacedDigit())
        }
        .fixedSize()
        .disabled(reviewSession.shownComments.isEmpty)
        .accessibilityLabel(Text("Preview the comments to insert"))
        .accessibilityValue(Text(verbatim: "\(reviewSession.insertableComments.count)"))
        .help(Text("Preview what will be inserted"))
        .popover(isPresented: $isShowingPrompt, arrowEdge: .bottom) {
            ReviewPromptPreview(reviewSession: reviewSession, prompt: prompt, onJump: onJump)
                .environment(\.locale, locale)
        }
    }
}

/// The strip between the header and the diff that says something about the
/// review as a whole — an error, that the worktree has moved on, that some
/// comments will not be sent.
///
/// Its own type because the three differ only in what they say and what the
/// button does, and the workspace they were written inside had grown past
/// what one view should hold.
struct ReviewBanner: View {
    /// What the banner reports, which picks its icon's color and its
    /// ground. The words stay in `text` on every one of them: the icon and
    /// the fill carry amber and red, as on the decision bar, since amber
    /// words on white stood at 1.5:1 and the system red at 3.55:1, both
    /// under 4.5:1.
    enum Tone {
        /// Something failed, or something written could not be kept.
        case error
        /// Something will not go as the reader may expect: stale comments
        /// that will not be sent.
        case warning
        /// Neither: news about the review (the worktree has changed).
        case notice

        var icon: Color {
            switch self {
            case .error: SupervisionTokens.stopped.color
            case .warning: SupervisionTokens.waiting.color
            case .notice: SupervisionTokens.muted.color
            }
        }

        var fill: Color {
            switch self {
            case .error: SupervisionTokens.stoppedFill.color
            case .warning: SupervisionTokens.waitingFill.color
            case .notice: WeirColor.rowActiveFill.opacity(0.5)
            }
        }

        /// Whether the ground is opaque, so the buttons on it fill opaquely
        /// too, as on the decision bar; the notice's ground is see-through.
        var hasOpaqueFill: Bool {
            self != .notice
        }
    }

    let systemImage: String
    let message: Text
    let tone: Tone
    var actionTitle: LocalizedStringKey?
    var isActionEnabled = true
    var action: (() -> Void)?
    /// Drawn to the left of the main action, for a banner that offers both a
    /// way to look at what it reports and a way to dispose of it.
    var secondaryActionTitle: LocalizedStringKey?
    var secondaryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.icon)
            // Errors name paths and Git output the reader may want to carry
            // elsewhere, and nothing here is worth denying that to.
            message
                .foregroundStyle(SupervisionTokens.text.color)
                .textSelection(.enabled)
            Spacer(minLength: WeirLayout.Supervision.spaceS)
            // Bordered, as the decision bar's are on the same fills: with the
            // words in `text`, a borderless title would read as more of them.
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.supervisionSecondary(size: .mini))
                    .disabled(!isActionEnabled)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.supervisionSecondary(size: .mini))
                    .disabled(!isActionEnabled)
            }
        }
        .font(WeirFont.caption)
        .padding(.horizontal, WeirLayout.Supervision.spaceM)
        .padding(.vertical, WeirLayout.Supervision.spaceSnug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.fill)
        .transformEnvironment(\.supervisionSurfaceOpacity) { opacity in
            if tone.hasOpaqueFill {
                opacity = 1
            }
        }
    }
}
