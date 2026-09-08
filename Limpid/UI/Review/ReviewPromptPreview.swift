// ReviewPromptPreview.swift
// Limpid — what the review would hand an agent, laid out to be read.

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
    let store: ReviewStore
    /// Built by the pane rather than here: the surface's Insert button sends
    /// the same text, and two builders would be two answers.
    let prompt: String
    let onJump: (ReviewComment) -> Void

    /// Comments grouped by the file they sit in, in the order they were
    /// written. Repeating one file name down a list of five comments on it
    /// spends the width that the comments themselves need.
    private var commentsByFile: [(file: ReviewFile, comments: [ReviewComment])] {
        ReviewPromptBuilder.groupedByFile(store.comments)
    }

    /// How many comments the prompt beside this header actually carries, which
    /// is what Copy puts on the pasteboard and what Insert sends. The cards
    /// below stay a superset: a stale one is drawn with its warning so the
    /// reader can resolve or delete it here.
    private var insertableCount: Int {
        store.insertableComments.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Comments to insert")
                    .font(LimpidFont.headline)
                Text(verbatim: "\(insertableCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LimpidColor.tertiaryText)
                Spacer(minLength: 8)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if store.comments.isEmpty {
                Text("No comments yet.")
                    .font(LimpidFont.caption)
                    .foregroundStyle(LimpidColor.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(commentsByFile, id: \.file.id) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                promptFileHeading(
                                    group.file,
                                    count: group.comments.count(where: store.isInsertable)
                                )
                                ForEach(group.comments) { comment in
                                    promptEntry(comment, isStale: store.staleCommentIDs.contains(comment.id))
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 560, height: 380)
    }

    private func promptFileHeading(_ file: ReviewFile, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: ReviewFileTree.name(file.path))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            if let parent = ReviewFileTree.parent(file.path) {
                Text(verbatim: parent)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(LimpidColor.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(verbatim: "\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LimpidColor.tertiaryText)
        }
        .help(Text(verbatim: file.path))
    }

    /// One comment, and the line it is attached to. Selecting it takes the
    /// reader there: a list of feedback you cannot act on is a receipt.
    ///
    /// Neither a stale nor a resolved comment is drawn in the diff, so this is
    /// the only place either can be acted on — which is why the footer carries
    /// their buttons rather than leaving them to the card.
    private func promptEntry(_ comment: ReviewComment, isStale: Bool) -> some View {
        let isReachable = !isStale && !comment.isResolved
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard isReachable else { return }
                onJump(comment)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: comment.promptSpan)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(LimpidColor.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(LimpidColor.rowHoverFill)
                            )
                        Text(verbatim: comment.body)
                            .font(LimpidFont.body)
                            .multilineTextAlignment(.leading)
                            .lineLimit(6)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(verbatim: Self.excerpt(comment.code))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LimpidColor.tertiaryText)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(LimpidColor.rowHoverFill.opacity(0.6))
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .help(help(comment, isStale: isStale))
            .accessibilityLabel(Text(verbatim: helpText(comment, isStale: isStale) + " " + comment.body))
            promptEntryFooter(comment, isStale: isStale)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(LimpidColor.rowActiveFill.opacity(0.5)))
        .opacity(isReachable ? 1 : 0.75)
    }

    /// Matches the footer, and for the same reason: a resolved comment reads
    /// as resolved before it reads as stale, and neither offers to take the
    /// reader anywhere, because neither is drawn in the diff to arrive at.
    private func help(_ comment: ReviewComment, isStale: Bool) -> Text {
        Text(verbatim: helpText(comment, isStale: isStale))
    }

    /// The same phrase as a string, so the accessibility label can carry it
    /// with the comment's own text. `Text` addition is deprecated as of macOS
    /// 26, and the two read as one sentence anyway.
    private func helpText(_ comment: ReviewComment, isStale: Bool) -> String {
        if comment.isResolved {
            String(localized: "Resolved.")
        } else if isStale {
            String(localized: "The code this was written against has changed.")
        } else {
            String(localized: "Go to comment")
        }
    }

    /// Resolved wins over stale: the reader saying a comment is handled
    /// outranks Git noticing that its lines moved, and offering to resolve
    /// something already resolved says the state was not registered.
    @ViewBuilder
    private func promptEntryFooter(_ comment: ReviewComment, isStale: Bool) -> some View {
        if comment.isResolved {
            promptEntryActions(Text("Resolved."), tint: LimpidColor.tertiaryText) {
                Button("Unresolve") { store.setResolved(comment.id, false) }
                    .buttonStyle(.borderless)
                    .font(LimpidFont.caption)
                Button("Delete") { store.remove(comment.id) }
                    .buttonStyle(.borderless)
                    .font(LimpidFont.caption)
            }
        } else if isStale {
            promptEntryActions(
                Text("The code this was written against has changed."),
                tint: LimpidColor.warning
            ) {
                Button("Resolve") { store.setResolved(comment.id, true) }
                    .buttonStyle(.borderless)
                    .font(LimpidFont.caption)
                Button("Delete") { store.remove(comment.id) }
                    .buttonStyle(.borderless)
                    .font(LimpidFont.caption)
            }
        } else if comment.insertedAt != nil {
            promptEntryActions(Text("Already inserted."), tint: LimpidColor.tertiaryText) {
                Button("Resolve") { store.setResolved(comment.id, true) }
                    .buttonStyle(.borderless)
                    .font(LimpidFont.caption)
            }
        }
    }

    private func promptEntryActions(
        _ message: Text,
        tint: Color,
        @ViewBuilder buttons: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            message
                .font(LimpidFont.caption)
                .foregroundStyle(tint)
            Spacer(minLength: 6)
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
