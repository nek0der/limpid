// ReviewPromptPreview.swift
// Weir — what the review would hand an agent, laid out to be read.

import AppKit
import SwiftUI

/// What the reader is about to hand an agent, as a list they can check rather
/// than as the text itself. The prompt's framing, its instructions and the full
/// excerpts are not drawn: quoting the document verbatim was unreadable, and a
/// code block per comment wrapped into a wall. The cards are a superset — a
/// resolved or stale comment is listed here and not inserted — so this answers
/// "what have I written" rather than "what exactly will be pasted".
///
/// Its own type because it is also where a comment the diff no longer draws —
/// one that has gone stale, or that the reader has resolved — is acted on, and
/// the workspace it was written inside had grown past what one file should
/// hold.
struct ReviewPromptPreview: View {
    let reviewSession: ReviewSession
    /// Built by the pane rather than here: the surface's Insert button sends
    /// the same text, and two builders would be two answers.
    let prompt: String
    let onJump: (ReviewComment) -> Void

    @Environment(\.locale) private var locale

    /// Where the heading's words start.
    private static let wordsInset: CGFloat = 12

    /// Comments grouped by the file they sit in, in the order they were
    /// written. Repeating one file name down a list of five comments on it
    /// spends the width that the comments themselves need.
    private var commentsByFile: [(file: ReviewFile, comments: [ReviewComment])] {
        ReviewPromptBuilder.groupedByFile(reviewSession.shownComments)
    }

    /// How many comments the prompt beside this header actually carries, which
    /// is what Copy puts on the pasteboard and what Insert sends. The cards
    /// below stay a superset: a stale one is drawn with its warning so the
    /// reader can resolve or delete it here.
    private var insertableCount: Int {
        reviewSession.insertableComments.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WeirLayout.Supervision.spaceS) {
                Text("Comments to insert")
                    .font(WeirFont.headline)
                Text(verbatim: "\(insertableCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                Button("Copy") {
                    // An empty prompt means building it failed; clearing the
                    // pasteboard first would take what the reader had and
                    // leave nothing behind.
                    guard !prompt.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }
                .disabled(prompt.isEmpty)
                .accessibilityLabel(Text("Copy"))
            }
            .padding(.horizontal, Self.wordsInset)
            .padding(.vertical, WeirLayout.Supervision.spaceS)
            Divider()
            if reviewSession.shownComments.isEmpty {
                SupervisionEmptyState(.noComments, size: .regular)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceM) {
                        ForEach(commentsByFile, id: \.file.id) { group in
                            VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceSnug) {
                                promptFileHeading(
                                    group.file,
                                    count: group.comments.count(where: reviewSession.isInsertable)
                                )
                                ForEach(group.comments) { comment in
                                    promptEntry(comment, isStale: reviewSession.staleCommentIDs.contains(comment.id))
                                }
                            }
                        }
                    }
                    .padding(WeirLayout.Supervision.spaceM)
                }
            }
        }
        .frame(width: 560, height: 380)
    }

    private func promptFileHeading(_ file: ReviewFile, count: Int) -> some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            Text(verbatim: ReviewFileTree.name(file.path))
                .font(.supervision(.meta, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            if let parent = ReviewFileTree.parent(file.path) {
                Text(verbatim: parent)
                    .font(.supervision(.badge, design: .monospaced))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: WeirLayout.Supervision.spaceSnug)
            Text(verbatim: "\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(SupervisionTokens.muted.color)
        }
        .help(Text(verbatim: file.path))
    }

    /// One comment, and the line it is attached to. Selecting it takes the
    /// reader there: a list of feedback you cannot act on is a receipt.
    ///
    /// Neither a stale nor a resolved comment is drawn in the diff, so this is
    /// the only place either can be acted on — which is why the footer carries
    /// their buttons rather than leaving them to the card.
    ///
    /// A card that cannot be reached steps back by drawing its comment in
    /// `muted`, not by fading the card: a faded card took its quiet text and
    /// the stale warning under 4.5:1.
    private func promptEntry(_ comment: ReviewComment, isStale: Bool) -> some View {
        let isReachable = !isStale && !comment.isResolved
        return VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceSnug) {
            Button {
                guard isReachable else { return }
                onJump(comment)
            } label: {
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceSnug) {
                    HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
                        Text(verbatim: comment.promptSpan)
                            .font(.supervision(.micro, weight: .medium, design: .monospaced))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .padding(.horizontal, WeirLayout.Supervision.spaceSnug)
                            .padding(.vertical, WeirLayout.Supervision.spaceHairline)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(WeirColor.rowHoverFill)
                            )
                        Text(verbatim: comment.body)
                            .font(WeirFont.body)
                            .foregroundStyle(isReachable ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
                            .multilineTextAlignment(.leading)
                            .lineLimit(6)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(verbatim: Self.excerpt(comment.code))
                        .font(.supervision(.micro, design: .monospaced))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WeirLayout.Supervision.spaceS)
                        .padding(.vertical, WeirLayout.Supervision.spaceXS)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(WeirColor.rowHoverFill.opacity(0.6))
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .help(help(comment, isStale: isStale))
            // Where it can be gone to, the comment, with the tooltip's "Go to
            // comment" read as the hint rather than run into it. Where it
            // can't, why, then the comment: the reason's own full stop goes,
            // since the list's separator follows it, and the tooltip is not
            // read a second time as the hint.
            .accessibilityLabel(Text(verbatim: isReachable
                    ? comment.body
                    : AgentStatusText.spokenList(
                        [
                            helpText(comment, isStale: isStale).resolved(in: locale)
                                .trimmingCharacters(in: CharacterSet(charactersIn: ".。")),
                            comment.body
                        ],
                        locale: locale
                    )))
            .accessibilityHint(isReachable ? help(comment, isStale: isStale) : Text(verbatim: ""))
            promptEntryFooter(comment, isStale: isStale)
        }
        .padding(WeirLayout.Supervision.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(WeirColor.rowActiveFill.opacity(0.5)))
    }

    /// Matches the footer, and for the same reason: a resolved comment reads
    /// as resolved before it reads as stale, and neither offers to take the
    /// reader anywhere, because neither is drawn in the diff to arrive at.
    private func help(_ comment: ReviewComment, isStale: Bool) -> Text {
        Text(helpText(comment, isStale: isStale))
    }

    /// The same phrase, which the accessibility label resolves to carry it
    /// with the comment's own text. `Text` addition is deprecated as of macOS
    /// 26, and the two read as one sentence anyway.
    private func helpText(_ comment: ReviewComment, isStale: Bool) -> LocalizedStringResource {
        if comment.isResolved {
            "Resolved."
        } else if isStale {
            "The code this was written against has changed."
        } else {
            "Go to comment"
        }
    }

    /// Resolved wins over stale: the reader saying a comment is handled
    /// outranks Git noticing that its lines moved, and offering to resolve
    /// something already resolved says the state was not registered.
    @ViewBuilder
    private func promptEntryFooter(_ comment: ReviewComment, isStale: Bool) -> some View {
        if comment.isResolved {
            promptEntryActions(Text("Resolved."), tint: SupervisionTokens.muted.color) {
                Button("Unresolve") { reviewSession.setResolved(comment.id, false) }
                    .buttonStyle(.borderless)
                    .font(WeirFont.caption)
                Button("Delete") { reviewSession.remove(comment.id) }
                    .buttonStyle(.borderless)
                    .font(WeirFont.caption)
            }
        } else if isStale {
            promptEntryActions(
                Text("The code this was written against has changed."),
                tint: SupervisionTokens.waitingText.color
            ) {
                Button("Resolve") { reviewSession.setResolved(comment.id, true) }
                    .buttonStyle(.borderless)
                    .font(WeirFont.caption)
                Button("Delete") { reviewSession.remove(comment.id) }
                    .buttonStyle(.borderless)
                    .font(WeirFont.caption)
            }
        } else if comment.insertedAt != nil {
            promptEntryActions(Text("Already inserted."), tint: SupervisionTokens.muted.color) {
                Button("Resolve") { reviewSession.setResolved(comment.id, true) }
                    .buttonStyle(.borderless)
                    .font(WeirFont.caption)
            }
        }
    }

    private func promptEntryActions(
        _ message: Text,
        tint: Color,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            message
                .font(WeirFont.caption)
                .foregroundStyle(tint)
            Spacer(minLength: WeirLayout.Supervision.spaceSnug)
            buttons()
        }
    }

    /// The quoted run, without the indentation every line of it shares: a
    /// deeply nested excerpt otherwise starts halfway across the card.
    private static func excerpt(_ code: String) -> String {
        // Through the same replacement the prompt makes. A draft saved before
        // that existed still holds whatever the file did, and a preview that
        // showed it would be describing a prompt that says something else.
        let lines = ReviewText.neutralized(code)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.count))) }.joined(separator: "\n")
    }
}
