// ReviewChrome.swift
// Limpid — the review surface's furniture: its banners, its scope switch, and
// the key bindings printed along its foot.
//
// Their own file rather than more of `ReviewPane`: none of them reads the
// diff, and the workspace they were written inside had outgrown what one file
// should hold.

import SwiftUI

/// Which of the two the review is of, with the selection sliding between them.
///
/// Not `.pickerStyle(.segmented)`: on macOS that is an `NSSegmentedControl`,
/// and AppKit swaps its highlight rather than moving it — leaving the one
/// control that decides what the whole surface is showing as the only one on
/// it that does not appear to respond.
struct ReviewScopeSwitch: View {
    let base: String
    /// What the store is actually reading. Follows the tap by however long
    /// Git takes, which is why it is not what the pill is drawn from.
    let isBranch: Bool
    var isEnabled = true
    let onSelect: (Bool) -> Void

    @Environment(\.limpidAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the pill is, which is not the same thing as what is being read.
    ///
    /// Moved from the tap rather than derived from the store: the scope
    /// changes inside an async reload, and a value that arrives outside the
    /// tap's transaction is a value `.animation(_:value:)` has already stopped
    /// watching for. Driving it here also means the control answers the click
    /// at once instead of when Git does.
    @State private var showsBranch: Bool
    /// Each segment's frame in the control's own space, so the pill can be
    /// given a width and an origin. An ordinary frame change animates;
    /// handing a shape between two backgrounds is a pair of transitions, and
    /// naming a different `matchedGeometryEffect` source relinks rather than
    /// travels.
    @State private var frames: [Bool: CGRect] = [:]

    /// `nonisolated` so the geometry closure can name it: the reader is on the
    /// main actor, but the closure is not, and a coordinate space name has no
    /// state to protect.
    private nonisolated static let space = "review-scope-switch"

    init(base: String, isBranch: Bool, isEnabled: Bool = true, onSelect: @escaping (Bool) -> Void) {
        self.base = base
        self.isBranch = isBranch
        self.isEnabled = isEnabled
        self.onSelect = onSelect
        _showsBranch = State(initialValue: isBranch)
    }

    /// `nil` here would be the obvious reading of Reduce Motion and the wrong
    /// one: it took the acknowledgment away entirely, so the control looked
    /// broken rather than calm. The toast host makes the same substitution —
    /// a shorter, unsprung animation rather than none.
    private var motion: Animation {
        reduceMotion ? LimpidMotion.reducedSlide : LimpidMotion.paneMergeHighlight
    }

    private var selected: CGRect {
        frames[showsBranch] ?? .zero
    }

    var body: some View {
        HStack(spacing: 2) {
            // The tooltip says the one thing the label cannot: this side
            // keeps the index and the working copy apart, so a file edited
            // and partly staged is listed twice and commented on twice. A
            // reader who wants one reading per file wants the other segment,
            // which folds both into a single diff — and nothing on the
            // control said so.
            segment(Text("Uncommitted"), tag: false)
                .help(Text("Staged, unstaged and untracked changes, listed separately."))
            // Git's own range notation rather than a sentence: it is what a
            // reader of diffs already knows, and it fits a segment where
            // "everything this branch adds since it left origin/main" does
            // not. The one place it is loose — the view runs to the worktree,
            // where the notation stops at `HEAD` — is what the tooltip is for.
            segment(Text(verbatim: base + "..."), tag: true)
                .accessibilityLabel(Text("Since \(base)"))
                .help(Text("Everything this branch adds, including work not committed yet."))
        }
        .coordinateSpace(.named(Self.space))
        .background(alignment: .leading) {
            Capsule()
                .fill(accent.opacity(0.3))
                .frame(width: selected.width, height: selected.height)
                .offset(x: selected.minX)
                // Nothing to draw until both segments have reported: a pill at
                // the origin with no width flickers through the first layout.
                .opacity(selected.isEmpty ? 0 : 1)
        }
        .padding(2)
        .background(Capsule().fill(LimpidColor.rowActiveFill.opacity(0.6)))
        // The reload can end somewhere the tap did not ask for — a retarget,
        // or a scope the store refused — and the pill has to follow it back.
        .onChange(of: isBranch) { _, latest in
            guard latest != showsBranch else { return }
            withAnimation(motion) { showsBranch = latest }
        }
        // Disabled while the reload it started is in flight, but not dimmed:
        // the pill has just moved to say the switch took, and fading the
        // control at the same moment reads as it having been refused.
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Review scope"))
    }

    private func segment(_ label: Text, tag: Bool) -> some View {
        Button {
            withAnimation(motion) { showsBranch = tag }
            onSelect(tag)
        } label: {
            label
                .font(LimpidFont.caption)
                .foregroundStyle(showsBranch == tag ? LimpidColor.primaryText : LimpidColor.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .contentShape(Capsule())
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { frame in
                    frames[tag] = frame
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsBranch == tag ? [.isButton, .isSelected] : .isButton)
    }
}

/// The key bindings the surface answers to, spelled out along its bottom edge.
///
/// Its own type because none of it depends on the review being read — only on
/// how the diff is laid out — and the workspace it was written inside had
/// grown past what one view should hold.
struct ReviewFooterHints: View {
    @Environment(ReviewPresentation.self) private var reviewPresentation

    var body: some View {
        HStack(spacing: 14) {
            hint("j / k", String(localized: "Line"))
            hint("⇧J / ⇧K", String(localized: "Extend"))
            hint("] / [", String(localized: "Hunk"))
            if reviewPresentation.diffLayout == .sideBySide {
                hint("h / l", String(localized: "Column"))
            }
            hint("n / p", String(localized: "File"))
            hint("c", String(localized: "Comment"))
            hint("v", String(localized: "Viewed"))
            hint("⌘↩", String(localized: "Insert"))
            hint("⌘⇧E", String(localized: "Terminal"))
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimpidColor.tabColumnBackground)
        // One stop rather than nine or none. Hidden, this was the only place
        // the bindings are written down and a screen reader could not reach
        // it; left as separate labels, every key and its noun read as two
        // unrelated fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Keyboard shortcuts"))
        .help(Text("Review shortcuts apply while the diff is focused."))
        .accessibilityHint(Text("Review shortcuts apply while the diff is focused."))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: key)
                .font(.caption2.monospaced())
                .foregroundStyle(LimpidColor.secondaryText)
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(LimpidColor.tertiaryText)
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
    let systemImage: String
    let message: Text
    let tint: Color
    /// `nil` tints the background from `tint`, which is what an error and a
    /// warning want. A banner that is neither picks its own.
    var fill: Color?
    var actionTitle: LocalizedStringKey?
    var isActionEnabled = true
    var action: (() -> Void)?
    /// Drawn to the left of the main action, for a banner that offers both a
    /// way to look at what it reports and a way to dispose of it.
    var secondaryActionTitle: LocalizedStringKey?
    var secondaryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            // Errors name paths and Git output the reader may want to carry
            // elsewhere, and nothing here is worth denying that to.
            message.textSelection(.enabled)
            Spacer(minLength: 8)
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.borderless)
                    .disabled(!isActionEnabled)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .disabled(!isActionEnabled)
            }
        }
        .font(LimpidFont.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill ?? tint.opacity(0.08))
    }
}

/// The bar above the diff: which file is open, how much it changed, and how it
/// is being read.
///
/// Fixed above the scroll rather than the first row of it, which put the file's
/// identity out of view as soon as the reader moved and let it run off the
/// right edge with the longest line in the file. Its own type rather than a
/// method on the workspace, which had grown past what one view body should
/// hold.
struct ReviewFileBar: View {
    let file: ReviewFile
    let stat: ReviewFileStat?
    /// Whether the diff loaded for this file came back empty.
    ///
    /// The counts beside the name come from the change list, which is read
    /// once and left alone — a list that reloaded under a comment being
    /// written would be worse than one a few seconds old. So when the file's
    /// change has since been committed or reverted, `stat` still carries the
    /// numbers from that read while the pane below says there is nothing here.
    /// The bar is the one place that knows both, and two lines of the same bar
    /// contradicting each other is what reads as a broken surface.
    let isEmpty: Bool
    /// Switching layout while a comment is being written would move the run it
    /// is about into the other column, or out of a column entirely.
    let isComposerOpen: Bool
    let isViewed: Bool
    @Binding var layout: ReviewDiffLayout
    let onToggleViewed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The tooltip belongs to the pair, not to the path itself:
            // selectable text installs its own hit area and answers the
            // pointer first, so a tooltip on it is never delivered. On the
            // icon beside it, it is — and the path stays selectable, which is
            // how a reader gets it out of here and into a terminal.
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(LimpidColor.tertiaryText)
                Text(verbatim: file.path)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .contentShape(Rectangle())
            // The middle of a deep path is what the bar drops first, and that
            // is usually the part saying which of two similarly named files
            // this is.
            .help(Text(verbatim: file.path))
            Spacer(minLength: 8)
            if let stat, !isEmpty {
                if stat.isBinary {
                    Text("binary")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LimpidColor.tertiaryText)
                        .contentShape(Rectangle())
                        .help(Text("This file cannot be reviewed as text."))
                } else {
                    HStack(spacing: 4) {
                        Text(verbatim: "+\(stat.added)").foregroundStyle(LimpidColor.success)
                        Text(verbatim: "−\(stat.removed)").foregroundStyle(LimpidColor.error)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .contentShape(Rectangle())
                    .help(Text("Changed lines"))
                }
            }
            Text(verbatim: file.layer.title)
                .font(LimpidFont.caption)
                .foregroundStyle(LimpidColor.tertiaryText)
                .contentShape(Rectangle())
                .help(Text(verbatim: file.layer.detail))
            viewedToggle
            picker
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(LimpidColor.rowActiveFill)
    }

    /// A toggle rather than a checkbox: at this size a `Toggle` draws a label
    /// beside a control, and the bar has room for one or the other.
    private var viewedToggle: some View {
        Button {
            onToggleViewed()
        } label: {
            Image(systemName: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(isViewed ? LimpidColor.success : LimpidColor.tertiaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isViewed ? "Mark as Not Viewed" : "Mark as Viewed"))
        .accessibilityAddTraits(isViewed ? [.isSelected] : [])
        .help(Text(isViewed ? "Mark as Not Viewed" : "Mark as Viewed"))
    }

    private var picker: some View {
        Picker("Diff Layout", selection: $layout) {
            Image(systemName: "rectangle")
                .accessibilityLabel(Text("Unified"))
                .tag(ReviewDiffLayout.unified)
            Image(systemName: "rectangle.split.2x1")
                .accessibilityLabel(Text("Side by Side"))
                .tag(ReviewDiffLayout.sideBySide)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .disabled(isComposerOpen)
        .accessibilityLabel(Text("Diff Layout"))
        // On the control rather than on each segment: AppKit draws this as one
        // `NSSegmentedControl`, and a tooltip attached to a segment's label
        // never reaches it.
        .help(Text("Unified or side by side"))
    }
}
