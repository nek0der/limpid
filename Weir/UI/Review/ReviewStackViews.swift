// ReviewStackViews.swift
// Weir — the review tab's stacked diff: each file's header, and the bar that sizes up the range.

import AppKit
import SwiftUI
import WeirDomain

/// A file's "+94 −2" (`DiffStatLabel`), or "binary" for a file Git does not
/// count lines in; nothing for a file it has no counts for (untracked).
/// The file list and the stacked diff's headers both draw it.
struct ReviewDiffCounts: View {
    let stat: ReviewFileStat?
    let size: WeirFont.Supervision.Size
    var spacing: CGFloat = 4

    var body: some View {
        if let stat {
            if stat.isBinary {
                Text("binary")
                    .font(.supervision(size, design: .monospaced))
                    // `muted`, to read at 4.5:1.
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .fixedSize()
                    .contentShape(Rectangle())
                    .help(Text("This file can’t be reviewed as text."))
            } else {
                DiffStatLabel(added: stat.added, removed: stat.removed, spacing: spacing)
                    .font(.supervision(size, design: .monospaced))
                    // Never wrapped: the name beside it gives way instead.
                    .fixedSize()
            }
        }
    }
}

/// A file's checkbox: the reader's mark of how far they have read, which
/// folds the file away and never moves the viewed line.
struct ReviewViewedCheckbox: View {
    let path: String
    let isViewed: Bool
    let onToggle: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Toggle(isOn: Binding(get: { isViewed }, set: { _ in onToggle() })) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help(Text(verbatim: ReviewStackText.checkboxHelp(locale: locale)))
        .accessibilityLabel(Text(verbatim: ReviewStackText.checkboxLabel(path: path, locale: locale)))
        .accessibilityHint(Text(verbatim: ReviewStackText.checkboxHelp(locale: locale)))
    }
}

/// A file's header in the stacked diff: the checkbox, the path, the marks,
/// and the counts. A checked file folds to this row, with a chevron
/// before its checkbox that opens it again and folds it once more; a click
/// anywhere on the row outside its controls does the same. The checkbox
/// says the file is viewed and the chevron whether it is folded, so the row
/// needs no words for either. On the sidebar's gray, edged above and below,
/// so it reads as the head of the file under it; its marks are neutral
/// tags, since none of them is a state the person has to act on.
struct ReviewStackFileHeader: View {
    /// `nil` only before the row is first configured.
    let header: ReviewStackHeader?
    var onToggleViewed: () -> Void = {}
    var onToggleFold: () -> Void = {}

    /// Handed over by the table, whose rows are AppKit (`ReviewHosted`).
    @Environment(\.locale) private var locale
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity

    private typealias Layout = WeirLayout.Supervision

    /// The chevron's column. The file list's chevron is 9 points wide; this
    /// one also takes the click, so a little wider.
    private static let disclosureWidth: CGFloat = 12

    var body: some View {
        if let header {
            HStack(spacing: WeirLayout.Supervision.spaceS) {
                disclosure(header)
                ReviewViewedCheckbox(path: header.file.path, isViewed: header.isViewed, onToggle: onToggleViewed)
                Text(verbatim: header.file.path)
                    .font(.supervisionCode(beside: .label, weight: .semibold))
                    .foregroundStyle(header.isFolded ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                    .lineLimit(1)
                    // The middle of a deep path goes first; the start says
                    // where it is and the end which file.
                    .supervisionTruncation(.path)
                    // A header with no tag still says when some turn's files
                    // could not be read, which its tags would have named.
                    .help(Text(verbatim: [header.file.path, ReviewTabText.unreadableNote(header.unreadableTags, locale: locale)]
                            .compactMap(\.self)
                            .joined(separator: "\n")))
                ForEach(header.marks, id: \.self) { mark in
                    ReviewFileMarkTag(text: ReviewStackText.mark(mark, locale: locale))
                        .help(ReviewStackText.markHelp(mark, locale: locale).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
                }
                if !header.tags.isEmpty {
                    ReviewFileConversationTags(tags: header.tags, unreadable: header.unreadableTags, locale: locale)
                }
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                ReviewDiffCounts(stat: header.stat, size: .row)
            }
            .padding(.horizontal, WeirLayout.Supervision.spaceM)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The whole row folds a checked file, as a heading of the file
            // list does: the chevron alone is a small target. The checkbox
            // and the chevron keep their own clicks, as controls inside it.
            // Only on a checked file's header: an unchecked file has no
            // fold, and its header leaves the click to the table as before.
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded(onToggleFold), including: header.isViewed ? .all : .subviews)
            .background(SupervisionTokens.sidebar.color.opacity(surfaceOpacity))
            .overlay(alignment: .top) {
                SupervisionTokens.line.color.frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                SupervisionTokens.line.color.frame(height: 1)
            }
        }
    }

    /// A checked file's chevron: right while it is folded, down while it is
    /// open. An unchecked file is always open and has none, but keeps its
    /// width, so every checkbox and path stands in one column and the
    /// checkbox does not move under the pointer as it is checked. It
    /// changes without animating, so there is nothing to hold back under
    /// Reduce Motion. A `Button`, as the file list's headings are, so Full
    /// Keyboard Access and VoiceOver reach it: named by what it does, so it
    /// does not read as the checkbox beside it, which the path names, with
    /// "Collapsed" or "Expanded" as its value and the path as its hint.
    @ViewBuilder
    private func disclosure(_ header: ReviewStackHeader) -> some View {
        if header.isViewed {
            Button(action: onToggleFold) {
                Image(systemName: header.isFolded ? "chevron.right" : "chevron.down")
                    .font(.supervision(.disclosure, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(header.isFolded ? "Expand File" : "Collapse File"))
            .accessibilityLabel(Text(header.isFolded ? "Expand File" : "Collapse File"))
            .accessibilityValue(Text(verbatim: ReviewStackText.foldState(isFolded: header.isFolded, locale: locale)))
            .accessibilityHint(Text(verbatim: header.file.path))
        } else {
            Color.clear
                .frame(width: Self.disclosureWidth, height: 1)
                .accessibilityHidden(true)
        }
    }
}

/// "New", "Changed by Bash", "Changed Outside Turns" on a file's header: a
/// small tag in the hover gray with muted words, the same for all three.
struct ReviewFileMarkTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.supervision(.micro))
            .foregroundStyle(SupervisionTokens.muted.color)
            .padding(.horizontal, WeirLayout.Supervision.reviewFileMarkHorizontalPadding)
            .padding(.vertical, 1)
            // As see-through as the file's header under it (`SurfaceGround`).
            .background(SurfaceGround {
                RoundedRectangle(cornerRadius: WeirLayout.Supervision.reviewFileMarkCornerRadius, style: .continuous)
                    .fill(SupervisionTokens.hover.color)
            })
            .fixedSize()
            .contentShape(Rectangle())
    }
}

/// The conversations whose turns changed the file within the range, on its
/// header: the first two as their identity bars and badges, each with its
/// number ("#4") where its name carries one, then "2 more" for the rest, so a
/// file many conversations touched keeps the header's room for its path.
/// Every one with its turns is in the tooltip and in what VoiceOver reads
/// ("Changed during Claude #4's T4, T6"), never "by": a turn's diff is what
/// changed in the worktree during it. The turns whose files could not be
/// read are named there too. Tags, not controls: they neither fold the file nor take a click.
struct ReviewFileConversationTags: View {
    let tags: [ReviewFileTag]
    let unreadable: [ReviewFileTag]
    let locale: Locale

    var body: some View {
        let (shown, more) = ReviewFileTags.shown(tags)
        let help = ReviewTabText.fileTagsHelp(tags, unreadable: unreadable, locale: locale) ?? ""
        let spoken = ReviewTabText.fileTagsSpoken(tags, unreadable: unreadable, locale: locale) ?? ""
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            ForEach(shown, id: \.self) { tag in
                face(tag)
            }
            if more > 0 {
                Text(verbatim: ReviewTabText.moreFileTags(more, locale: locale))
                    .font(.supervision(.micro))
                    .foregroundStyle(SupervisionTokens.muted.color)
            }
        }
        .fixedSize()
        .contentShape(Rectangle())
        .help(Text(verbatim: help))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private func face(_ tag: ReviewFileTag) -> some View {
        let badge = SessionRowFact.Badge.agent(tag.provider)
        return HStack(spacing: WeirLayout.Supervision.spaceXS) {
            ConversationIdentityLead(identity: tag.identity) {
                SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale))
            }
            if let number = ReviewTabText.fileTagNumber(tag) {
                Text(verbatim: number)
                    .font(.supervision(.micro).monospacedDigit())
                    .foregroundStyle(SupervisionTokens.muted.color)
            }
        }
    }
}

/// The header row in the table. SwiftUI inside, as the hunk header's
/// buttons are, so the checkbox and the counts are the controls and colors
/// the rest of the window uses.
final class ReviewFileHeaderRowView: NSView {
    private let host = NSHostingView(rootView: ReviewHosted(environment: .init(), content: ReviewStackFileHeader(header: nil)))
    /// The header spans what the reader can see rather than the column,
    /// which is as wide as the longest line of every file: across that, the
    /// counts sat past the right edge of the window.
    private var hostWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addSubview(host)
        let width = host.widthAnchor.constraint(equalToConstant: 400)
        hostWidth = width
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            width
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ content: ReviewStackFileHeader, in environment: ReviewHostedEnvironment, width: CGFloat) {
        hostWidth?.constant = max(width, 1)
        host.rootView = ReviewHosted(environment: environment, content: content)
    }
}

/// The last line of the review tab's top edge: how many files the
/// range has and how much they changed, and the layout, as words. Each
/// file's own name and counts are on its header in the diff.
struct ReviewStackBar: View {
    let files: [ReviewFile]
    let stats: [String: ReviewFileStat]
    let isComposerOpen: Bool
    @Binding var layout: ReviewDiffLayout
    /// True when the inline file list has yielded to the diff; the bar then
    /// opens it as a drawer.
    let showsFileListButton: Bool
    /// Off, not gone, while a comment is being written or the find bar is
    /// open, when the drawer does not open (`presentCompactFileRail`). Taken
    /// away, the button gave its width to the range's size, which moved
    /// sideways under the reader.
    let isFileListButtonEnabled: Bool
    let onShowFiles: () -> Void
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        HStack(spacing: Layout.reviewTabTopSpacing) {
            if showsFileListButton {
                Button(action: onShowFiles) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.supervision(.caption))
                        .frame(height: Layout.secondaryButtonCompactHeight)
                }
                .buttonStyle(.supervisionIcon)
                .disabled(!isFileListButtonEnabled)
                .accessibilityLabel(Text("Files"))
                .help(Text("Files"))
            }
            ReceiptRunsText(
                runs: ReviewStackText.summary(files: files, stats: stats, locale: locale),
                size: .row
            )
            .lineLimit(1)
            Spacer(minLength: WeirLayout.Supervision.spaceS)
            ReviewTabLayoutSwitch(layout: $layout, isDisabled: isComposerOpen)
        }
        .padding(.horizontal, Layout.reviewTabTopInset)
        .frame(height: Layout.reviewFileHeaderHeight)
        .frame(maxWidth: .infinity)
    }
}
