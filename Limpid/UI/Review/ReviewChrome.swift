// ReviewChrome.swift
// Limpid — the review surface's header, banners, scope switch, and
// key bindings printed along its foot.
//
// Their own file rather than more of `ReviewPane`: none of them reads the
// diff, and the workspace they were written inside had outgrown what one file
// should hold.

import SwiftUI

enum ReviewHeaderMetrics {
    /// Match the regular macOS button height used by the actions in this
    /// header. Every custom capsule uses this value so mixed SwiftUI and
    /// native controls still share one visual baseline.
    static let controlHeight: CGFloat = 28

    /// Enough for two signed five-digit counts at the caption size. A fixed
    /// slot keeps a refreshed count from changing which `ViewThatFits` layout
    /// wins and moving the scope control under the pointer.
    static let statWidth: CGFloat = 104
}

struct ReviewHeader: View {
    let store: ReviewStore
    let destination: ReviewDestination?
    let isResolvingDestination: Bool
    let isInserting: Bool
    let isSnapshotReady: Bool
    let scopeSelectionWithoutAnimation: ReviewScope?
    let canInsert: Bool
    let offeredTurnScope: ReviewScope?
    let prompt: String
    @Binding var isShowingPrompt: Bool
    let onSelectScope: (ReviewScope) -> Void
    let onRefresh: () -> Void
    let onInsert: () -> Void
    let onClose: () -> Void
    let onJump: (ReviewComment) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide
            medium
            compact
        }
        .padding(.horizontal, 12)
        .background(LimpidColor.tabColumnBackground)
    }

    private var wide: some View {
        HStack(spacing: 10) {
            title
            rootName
            scopePicker
            statPill
            Spacer(minLength: 8)
            destinationControl
            commentPill
            refreshButton
            insertButton
            closeButton
        }
        .frame(height: 44)
    }

    /// Medium widths have room for every control, but not for a single row.
    /// Keep related controls together across two balanced rows before the
    /// minimum-width layout gives the destination a row of its own.
    private var medium: some View {
        VStack(spacing: 6) {
            primaryRow
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    destinationControl
                    scopePicker
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    commentPill
                    refreshButton
                    statPill
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 6)
    }

    /// The destination gets its own line at narrow widths. Scope and status
    /// remain visible below it instead of disappearing into a horizontal
    /// scroll position with no on-screen affordance.
    private var compact: some View {
        VStack(spacing: 6) {
            primaryRow
            HStack(spacing: 10) {
                destinationControl
                    .layoutPriority(1)
                Spacer(minLength: 8)
                statPill
            }
            HStack(spacing: 10) {
                scopePicker
                Spacer(minLength: 8)
                commentPill
                refreshButton
            }
        }
        .padding(.vertical, 6)
    }

    private var primaryRow: some View {
        HStack(spacing: 10) {
            title
            rootName
            insertButton
            closeButton
        }
    }

    private var title: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(LimpidColor.secondaryText)
            Text("Review changes")
                .font(LimpidFont.headline)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var rootName: some View {
        Text(verbatim: store.root.lastPathComponent)
            .font(LimpidFont.caption)
            .foregroundStyle(LimpidColor.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var destinationControl: some View {
        HStack(spacing: 6) {
            Text("Insert into")
                .font(LimpidFont.caption)
                .foregroundStyle(LimpidColor.tertiaryText)
                .fixedSize(horizontal: true, vertical: false)
            ReviewDestinationChip(destination: destination, isResolving: isResolvingDestination)
        }
    }

    private var refreshButton: some View {
        Button("Refresh", action: onRefresh)
            .accessibilityLabel(Text("Refresh"))
            .disabled(store.isLoading || isInserting)
    }

    private var insertButton: some View {
        // The surface is a review; the button does not have to say so again.
        // It keeps the full phrase for VoiceOver, where the reader may be
        // arriving from anywhere in the window.
        Button("Insert", action: onInsert)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text("Insert Review"))
            .disabled(!canInsert)
    }

    private var closeButton: some View {
        // Never disabled, not even mid-insert: validation runs Git once per
        // commented file, and a surface that cannot be closed while that
        // happens is a surface that can be stuck. The insert task re-checks
        // its target before writing anything.
        Button("Close", action: onClose)
            .accessibilityLabel(Text("Close"))
    }

    private var totals: (added: Int, removed: Int) {
        store.stats.values.reduce(into: (0, 0)) { total, stat in
            guard !stat.isBinary else { return }
            total.0 += stat.added
            total.1 += stat.removed
        }
    }

    private var statPill: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(totals.added)")
                .foregroundStyle(LimpidColor.success)
            Text(verbatim: "−\(totals.removed)")
                .foregroundStyle(LimpidColor.error)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 7)
        .frame(width: ReviewHeaderMetrics.statWidth, height: ReviewHeaderMetrics.controlHeight)
        .overlay(Capsule().stroke(LimpidColor.panelDivider))
        .opacity(isSnapshotReady ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Changed lines"))
    }

    /// What the review is of. It decides the stats and the diff as much as the
    /// file list, so it belongs to the header rather than either content pane.
    @ViewBuilder
    private var scopePicker: some View {
        let scopes = availableScopes
        if scopes.count > 1 {
            ReviewScopeSwitch(
                scopes: scopes,
                selection: store.scope,
                selectionWithoutAnimation: scopeSelectionWithoutAnimation,
                isEnabled: !store.isLoading && !isInserting,
                onSelect: onSelectScope
            )
            .opacity(isSnapshotReady ? 1 : 0)
        }
    }

    private var availableScopes: [ReviewScope] {
        ReviewScope.pickerOptions(
            current: store.scope,
            offeredTurn: offeredTurnScope,
            branchBase: store.base
        )
    }

    private var commentPill: some View {
        Button {
            isShowingPrompt.toggle()
        } label: {
            Label {
                Text(verbatim: "\(store.insertableComments.count)")
                    .font(.caption.monospacedDigit())
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
        }
        .disabled(store.comments.isEmpty)
        .accessibilityLabel(Text("Preview the comments to insert"))
        .accessibilityValue(Text(verbatim: "\(store.insertableComments.count)"))
        .help(Text("Preview what will be inserted"))
        .popover(isPresented: $isShowingPrompt, arrowEdge: .bottom) {
            ReviewPromptPreview(store: store, prompt: prompt, onJump: onJump)
        }
    }
}

/// Which snapshot the review is of, with the selection sliding between them.
///
/// Not `.pickerStyle(.segmented)`: on macOS that is an `NSSegmentedControl`,
/// and AppKit swaps its highlight rather than moving it — leaving the one
/// control that decides what the whole surface is showing as the only one on
/// it that does not appear to respond.
struct ReviewScopeSwitch: View {
    let scopes: [ReviewScope]
    /// What the completed snapshot represents. It changes only when the new
    /// file list and diff are ready, so the pill never labels old code as the
    /// scope the reader just requested.
    let selection: ReviewScope
    /// A command-driven destination is not a simulated picker gesture. The
    /// pill appears at that scope when its snapshot commits.
    let selectionWithoutAnimation: ReviewScope?
    var isEnabled = true
    let onSelect: (ReviewScope) -> Void

    @Environment(\.limpidAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the pill is. Stored only to animate the committed scope change;
    /// it must not move ahead of the snapshot it describes.
    @State private var displayedSelection: ReviewScope
    /// Each segment's frame in the control's own space, so the pill can be
    /// given a width and an origin. An ordinary frame change animates;
    /// handing a shape between two backgrounds is a pair of transitions, and
    /// naming a different `matchedGeometryEffect` source relinks rather than
    /// travels.
    @State private var frames: [String: CGRect] = [:]
    /// `ViewThatFits` builds all header candidates while choosing one. A
    /// per-instance space keeps their measured segment frames from mixing.
    @Namespace private var coordinateSpace

    init(
        scopes: [ReviewScope],
        selection: ReviewScope,
        selectionWithoutAnimation: ReviewScope? = nil,
        isEnabled: Bool = true,
        onSelect: @escaping (ReviewScope) -> Void
    ) {
        self.scopes = scopes
        self.selection = selection
        self.selectionWithoutAnimation = selectionWithoutAnimation
        self.isEnabled = isEnabled
        self.onSelect = onSelect
        _displayedSelection = State(initialValue: selection)
    }

    /// `nil` here would be the obvious reading of Reduce Motion and the wrong
    /// one: it took the acknowledgment away entirely, so the control looked
    /// broken rather than calm. The toast host makes the same substitution —
    /// a shorter, unsprung animation rather than none.
    private var motion: Animation {
        reduceMotion ? LimpidMotion.reducedSlide : LimpidMotion.paneMergeHighlight
    }

    private var selected: CGRect {
        // The option builder keeps this true. The guard is the final visual
        // boundary if a future caller violates that contract: a stale frame
        // must not leave an unlabeled selection pill beside the live options.
        guard scopes.contains(displayedSelection) else { return .zero }
        return frames[id(for: displayedSelection)] ?? .zero
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes, id: \.selfID) { scope in
                segment(label(for: scope), tag: scope)
                    .accessibilityLabel(accessibilityLabel(for: scope))
                    .help(help(for: scope))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .coordinateSpace(.named(coordinateSpace))
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
        .frame(height: ReviewHeaderMetrics.controlHeight)
        .background(Capsule().fill(LimpidColor.rowActiveFill.opacity(0.6)))
        // The reload can end somewhere the tap did not ask for — a retarget,
        // or a scope the store refused — and the pill has to follow it back.
        .onChange(of: selection) { _, latest in
            guard latest != displayedSelection else { return }
            if Self.animatesSelection(to: latest, selectionWithoutAnimation: selectionWithoutAnimation) {
                withAnimation(motion) { displayedSelection = latest }
            } else {
                displayedSelection = latest
            }
        }
        // Disabled while the reload it started is in flight, but not dimmed:
        // the pill has just moved to say the switch took, and fading the
        // control at the same moment reads as it having been refused.
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Review scope"))
    }

    static func animatesSelection(
        to selection: ReviewScope,
        selectionWithoutAnimation: ReviewScope?
    ) -> Bool {
        selection != selectionWithoutAnimation
    }

    private func segment(_ label: Text, tag: ReviewScope) -> some View {
        // Geometry transforms are Sendable closures. Capture the namespace on
        // the main actor before entering one rather than reaching back into
        // SwiftUI's actor-isolated property from that closure.
        let space = coordinateSpace
        return Button {
            onSelect(tag)
        } label: {
            label
                .font(LimpidFont.caption)
                .foregroundStyle(displayedSelection == tag ? LimpidColor.primaryText : LimpidColor.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: ReviewHeaderMetrics.controlHeight - 4)
                .contentShape(Capsule())
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(space))
                } action: { frame in
                    frames[id(for: tag)] = frame
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(displayedSelection == tag ? [.isButton, .isSelected] : .isButton)
    }

    private func id(for scope: ReviewScope) -> String {
        scope.selfID
    }

    private func label(for scope: ReviewScope) -> Text {
        switch scope {
        case .uncommitted: Text("Uncommitted")
        case .turn: Text("This turn")
        case let .branch(base): Text(verbatim: base)
        }
    }

    private func accessibilityLabel(for scope: ReviewScope) -> Text {
        switch scope {
        case .uncommitted: Text("Uncommitted")
        case .turn: Text("This turn")
        case let .branch(base): Text("Since \(base)")
        }
    }

    private func help(for scope: ReviewScope) -> Text {
        switch scope {
        case .uncommitted: Text("Staged, unstaged and untracked changes, listed separately.")
        case .turn: Text(ReviewLayer.turn.detail)
        case .branch: Text("Everything this branch adds, including work not committed yet.")
        }
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
        ViewThatFits(in: .horizontal) {
            hints
                .fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal, showsIndicators: false) {
                hints
                    .fixedSize(horizontal: true, vertical: false)
            }
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

    private var hints: some View {
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
    let root: URL
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
    /// True when the inline file rail has yielded to the diff. The file bar
    /// then becomes the stable place from which to open its transient drawer.
    let showsFileListButton: Bool
    let onShowFiles: () -> Void
    let onToggleViewed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsFileListButton {
                Button(action: onShowFiles) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Files"))
                .help(Text("Files"))
            }
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
            .contextMenu {
                ReviewFileActionsMenu(root: root, file: file)
            }
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
