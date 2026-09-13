// ReviewChrome.swift
// Limpid — the review surface's header, banners, scope switch, and
// key bindings printed along its foot.
//
// Their own file rather than more of `ReviewPane`: none of them reads the
// diff, and the workspace they were written inside had outgrown what one file
// should hold.

import AppKit
import SwiftUI

enum ReviewHeaderMetrics {
    /// Match the regular macOS button height used by the actions in this
    /// header, measured from a rendered `.bordered` button on macOS 26. Every
    /// custom control uses this value so mixed SwiftUI and native controls
    /// share one visual baseline.
    static let controlHeight: CGFloat = 24

    /// The corner the native buttons beside it draw, so the joined
    /// destination control reads as one of them.
    static let controlRadius: CGFloat = 6

    /// How narrow the destination may be squeezed before the header gives up
    /// a row instead. Below this a tab title is mostly ellipsis, and the one
    /// thing the header exists to say — where the text goes — is unreadable.
    /// The row is chosen as if the name were this wide whatever it says, so
    /// a name that arrives or changes later never changes the row count; the
    /// chip itself is sized to the name. See `ReviewDestinationLayout`. The
    /// two-row layouts accept less because the alternative is a third row.
    static let destinationFloor: CGFloat = 200
    static let destinationFloorSplit: CGFloat = 160
    static let destinationFloorCompact: CGFloat = 120

    /// The worktree's directory name is usually short and always the answer
    /// to "which checkout is this"; a long one still gives way to the
    /// destination, but not to nothing.
    static let rootFloor: CGFloat = 72
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

    @Environment(\.limpidAccent) private var accent

    /// Measured from the native Close button, so the insert button beside or
    /// below it can be drawn the same width; a prominent button narrower than
    /// its plain neighbor read as the lesser control.
    @State private var closeWidth: CGFloat = 0
    /// Measured so the two-row layouts can set the destination to the width
    /// of the buttons above it, and the two right-hand columns line up. Both
    /// are read off the skeleton, which carries the same buttons, so the
    /// first full layout already has them.
    @State private var rowButtonsWidth: CGFloat = 0

    /// Three candidates, each with the same controls in the same order. A
    /// narrower header only breaks the row; nothing moves to a different
    /// side or disappears, so the reader never has to find a control again.
    ///
    /// Until the snapshot is in, only the first row of the two-row layout:
    /// the identity and the buttons. The row count depends on the scope set
    /// and the counts, and a header laid out before they arrived chose one
    /// row and then broke into two in front of the reader. The destination
    /// may still be resolving at that point; the row count does not depend
    /// on its name, so it can arrive whenever it does.
    var body: some View {
        Group {
            if isSnapshotReady {
                ViewThatFits(in: .horizontal) {
                    single
                    split(scope: .switch, destinationFloor: ReviewHeaderMetrics.destinationFloorSplit)
                    split(scope: .menu, destinationFloor: ReviewHeaderMetrics.destinationFloorCompact)
                }
            } else {
                row {
                    title
                    rootName
                    slack
                    rowButtons
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 12)
        .background(LimpidColor.tabColumnBackground)
    }

    /// One row: what the review is of on the left, what it does on the right,
    /// and the destination joined to the action it is the object of.
    private var single: some View {
        row {
            title
            rootName
            slack
            snapshot(scope: .switch)
            snapshotButtons
            destinationControl(floor: ReviewHeaderMetrics.destinationFloor)
            closeButton
        }
        .frame(height: 44)
    }

    /// One row of the header, as tall as its controls whatever it holds. A
    /// row that took its height from its contents sat a point lower with
    /// only the Close button in it than with the full set, and the title
    /// shifted when the rest arrived.
    private func row(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .frame(height: ReviewHeaderMetrics.controlHeight)
    }

    /// Two rows: the identity and the buttons above, the snapshot below —
    /// its scope, its numbers, and where the review goes. The buttons sit
    /// with the title rather than with the numbers they act on because the
    /// second row is the one that runs out of room first: at the narrowest
    /// widths the destination and a scope menu are all it can hold.
    private func split(scope: ScopeControl, destinationFloor: CGFloat) -> some View {
        VStack(spacing: 6) {
            row {
                title
                rootName
                slack
                rowButtons
            }
            row {
                snapshot(scope: scope)
                slack
                destinationControl(floor: destinationFloor, fill: rowButtonsWidth)
            }
        }
        // The same inset the one-row header has above its row, so the first
        // row sits where it did and a second row only ever appears below it.
        // With a tighter inset the title stepped up as the header grew.
        .padding(.vertical, 10)
    }

    /// The buttons of the first row, set as one cluster with one gap, and
    /// measured as one so the destination below can match them edge to edge.
    private var rowButtons: some View {
        HStack(spacing: 4) {
            snapshotButtons
            closeButton
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowButtonsWidth = width
        }
    }

    /// The two buttons about the snapshot, set closer than the rest of the
    /// row so they read as a pair. On its own with the row's spacing on both
    /// sides, the comment count floated between the numbers and the icon.
    private var snapshotButtons: some View {
        HStack(spacing: 4) {
            commentPill
            refreshButton
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

    /// Truncates past its floor rather than claiming every spare point, which
    /// used to leave the destination cut short beside an empty stretch of
    /// header.
    private var rootName: some View {
        WidthFloorLayout(floor: ReviewHeaderMetrics.rootFloor) {
            Text(verbatim: store.root.lastPathComponent)
                .font(LimpidFont.caption)
                .foregroundStyle(LimpidColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// The gap between the two halves of a row, filled last. A stack hands
    /// its flexible children equal shares of what is left, and a spacer at
    /// the same priority as the names kept half of it while they truncated.
    /// The destination sits a step above this and the root name a step
    /// above that, so a name truncates only once there is no gap left.
    private var slack: some View {
        Spacer(minLength: 8)
            .layoutPriority(-1)
    }

    /// The destination and the insert button as one control. Where the text
    /// goes is the button's object, and standing next to it says so without
    /// a label. The button alone dims when there is nothing to insert; the
    /// destination stays legible, because it is still true.
    ///
    /// One outline around both halves, drawn here rather than by each: a chip
    /// with its own border met the button at a visible seam, and two shapes
    /// side by side are two controls however close they sit.
    ///
    /// First in line for the row's spare width. A stack offers the children
    /// of a higher priority the room left after the minimums of the rest, so
    /// the name grows before the spacer does — and so every neighbor in the
    /// row pins its own size, or it would be that minimum: an ellipsis.
    private func destinationControl(floor: CGFloat, fill: CGFloat = 0) -> some View {
        let shape = RoundedRectangle(cornerRadius: ReviewHeaderMetrics.controlRadius)
        return ReviewDestinationLayout(floor: floor, fill: max(0, fill)) {
            ReviewDestinationChip(destination: destination, isResolving: isResolvingDestination)
            insertButton
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(accent.opacity(0.45), lineWidth: 1))
        .layoutPriority(1)
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
        }
        .fixedSize()
        .accessibilityLabel(Text("Refresh"))
        .help(Text("Refresh"))
        .disabled(store.isLoading || isInserting)
    }

    private var insertButton: some View {
        // The surface is a review; the button does not have to say so again.
        // It keeps the full phrase for VoiceOver, where the reader may be
        // arriving from anywhere in the window.
        Button("Insert", action: onInsert)
            .buttonStyle(ReviewInsertButtonStyle(minWidth: closeWidth))
            .accessibilityLabel(Text("Insert Review"))
            .disabled(!canInsert)
    }

    private var closeButton: some View {
        // Never disabled, not even mid-insert: validation runs Git once per
        // commented file, and a surface that cannot be closed while that
        // happens is a surface that can be stuck. The insert task re-checks
        // its target before writing anything.
        Button("Close", action: onClose)
            .fixedSize()
            .accessibilityLabel(Text("Close"))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                closeWidth = width
            }
    }

    private var totals: (added: Int, removed: Int) {
        store.stats.values.reduce(into: (0, 0)) { total, stat in
            guard !stat.isBinary else { return }
            total.0 += stat.added
            total.1 += stat.removed
        }
    }

    /// The scope and its numbers, set closer than the rest of the row: the
    /// counts describe the snapshot the switch selected, and on their own
    /// between two groups of controls they read as belonging to neither.
    private func snapshot(scope: ScopeControl) -> some View {
        HStack(spacing: 4) {
            scopePicker(scope)
            stats
        }
    }

    /// Drawn on the same track as the scope switch, as its trailing badge.
    /// Sized to the counts rather than to a fixed slot: a slot wide enough for
    /// five-digit counts left a blank stretch after the usual three, and the
    /// counts change only when the snapshot does, which relays out the whole
    /// header anyway.
    private var stats: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(totals.added)")
                .foregroundStyle(LimpidColor.success)
            Text(verbatim: "−\(totals.removed)")
                .foregroundStyle(LimpidColor.error)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(height: ReviewHeaderMetrics.controlHeight)
        .background(Capsule().fill(LimpidColor.rowActiveFill.opacity(0.6)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Changed lines"))
    }

    private enum ScopeControl {
        case `switch`
        case menu
    }

    /// What the review is of. It decides the stats and the diff as much as the
    /// file list, so it belongs to the header rather than either content pane.
    @ViewBuilder
    private func scopePicker(_ control: ScopeControl) -> some View {
        let scopes = availableScopes
        if scopes.count > 1 {
            Group {
                switch control {
                case .switch:
                    ReviewScopeSwitch(
                        scopes: scopes,
                        selection: store.scope,
                        selectionWithoutAnimation: scopeSelectionWithoutAnimation,
                        isEnabled: !store.isLoading && !isInserting,
                        onSelect: onSelectScope
                    )
                case .menu:
                    ReviewScopeMenu(
                        scopes: scopes,
                        selection: store.scope,
                        isEnabled: !store.isLoading && !isInserting,
                        onSelect: onSelectScope
                    )
                }
            }
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
        .fixedSize()
        .disabled(store.comments.isEmpty)
        .accessibilityLabel(Text("Preview the comments to insert"))
        .accessibilityValue(Text(verbatim: "\(store.insertableComments.count)"))
        .help(Text("Preview what will be inserted"))
        .popover(isPresented: $isShowingPrompt, arrowEdge: .bottom) {
            ReviewPromptPreview(store: store, prompt: prompt, onJump: onJump)
        }
    }
}

/// The prominent button as a plain filled block, so the destination chip in
/// front of it and the button can be clipped and outlined as one control.
///
/// Its own style rather than `.borderedProminent`: the native style draws its
/// own shape, and there is no way to ask it to share one with a neighbor.
/// Uses the same accent the native button would, so the pair matches the
/// Close button beside it.
struct ReviewInsertButtonStyle: ButtonStyle {
    /// At least this wide, so it can match the Close button it sits beside
    /// or below. Zero until that button has been measured.
    var minWidth: CGFloat = 0

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.limpidAccent) private var accent

    /// The native prominent style keeps white on the darker accents and dark
    /// text on the lighter ones (yellow, amber); drawing our own fill means
    /// making that choice here, or white on amber reads at under 2:1.
    private var label: Color {
        accent.isLight ? .black : .white
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The size and weight a regular native button draws its title
            // at, so the pair with Close beside it reads as one family.
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(label)
            // Never truncated: a one-character "Insert" is not a button the
            // reader can name. The chip beside it is what gives way.
            .fixedSize()
            .frame(minWidth: max(0, minWidth - 24))
            .padding(.horizontal, 12)
            .frame(height: ReviewHeaderMetrics.controlHeight)
            .background(accent.opacity(configuration.isPressed ? 0.8 : 1))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A view that asks for no more than `floor` — or its own content, whichever
/// is narrower — and holds that under pressure.
///
/// For the root name. `frame(minWidth:)` would pad a short name out to the
/// floor; this only stops a long one from being erased by a neighbor that
/// outranks it for spare width, and leaves the rest of the row to that
/// neighbor.
struct WidthFloorLayout: Layout {
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let content = subview.sizeThatFits(.unspecified)
        let ideal = min(floor, content.width)
        guard let proposed = proposal.width else {
            return CGSize(width: ideal, height: content.height)
        }
        let width = min(content.width, max(proposed, ideal))
        let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: max(min(fitted.width, content.width), ideal), height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// The destination chip and the insert button as one control: the button at
/// its own width on the trailing edge, the chip taking the rest.
///
/// `ViewThatFits` judges a row by its ideal width, and a plain `Text` reports
/// its whole string as ideal: a long tab title then broke the header into two
/// rows while one row could have held it truncated, and a title that arrived
/// a moment after the header did changed the row count in front of the
/// reader. So the ideal is `floor` for the chip whatever it says — the row is
/// chosen as if the name were that wide — and the chip is then sized to the
/// name, up to the room the row has. `fill` stretches the pair past that, to
/// the width of the buttons above it in the two-row layouts, so the right
/// edge of the header is one line.
///
/// The floor is not a minimum. When even the last layout cannot fit, the
/// stack takes the shortfall from whatever can still shrink, and a chip that
/// refused to go below its floor pushed that onto the buttons beside it —
/// "Insert" came back as its first character. A name reduced to an ellipsis
/// is the lesser loss; it is still in the tooltip.
struct ReviewDestinationLayout: Layout {
    let floor: CGFloat
    var fill: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let chip = subviews[0]
        let button = subviews[1].sizeThatFits(.unspecified)
        let content = chip.sizeThatFits(.unspecified)
        let height = max(content.height, button.height)
        guard let proposed = proposal.width else {
            return CGSize(width: max(floor + button.width, fill), height: height)
        }
        let chipWidth = min(content.width, max(0, proposed - button.width))
        let fitted = chip.sizeThatFits(ProposedViewSize(width: chipWidth, height: proposal.height))
        return CGSize(width: max(fitted.width + button.width, min(fill, proposed)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let buttonWidth = subviews[1].sizeThatFits(.unspecified).width
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width - buttonWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.minY),
            anchor: .topTrailing,
            proposal: ProposedViewSize(width: buttonWidth, height: bounds.height)
        )
    }
}

private extension Color {
    /// Whether text on this color should be dark. Resolved through AppKit
    /// because SwiftUI does not expose components, and the accent can be the
    /// system's own choice rather than one of ours.
    var isLight: Bool {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6
    }
}

/// The scope as a pull-down, for a header too narrow to show every option.
///
/// Not a `Picker`: the selection follows the committed snapshot, not the
/// gesture, and a picker that snaps back while the reload runs reads as a
/// refused choice.
struct ReviewScopeMenu: View {
    let scopes: [ReviewScope]
    let selection: ReviewScope
    var isEnabled = true
    let onSelect: (ReviewScope) -> Void

    var body: some View {
        Menu {
            ForEach(scopes, id: \.selfID) { scope in
                Button {
                    onSelect(scope)
                } label: {
                    scope.pickerLabel
                }
                .help(scope.pickerHelp)
            }
        } label: {
            selection.pickerLabel
                .font(LimpidFont.caption)
        }
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityLabel(Text("Review scope"))
        .accessibilityValue(selection.pickerAccessibilityLabel)
    }
}

extension ReviewScope {
    var pickerLabel: Text {
        switch self {
        case .uncommitted: Text("Uncommitted")
        case .turn: Text("This turn")
        case let .branch(base): Text(verbatim: base)
        }
    }

    var pickerAccessibilityLabel: Text {
        switch self {
        case .uncommitted: Text("Uncommitted")
        case .turn: Text("This turn")
        case let .branch(base): Text("Since \(base)")
        }
    }

    var pickerHelp: Text {
        switch self {
        case .uncommitted: Text("Staged, unstaged and untracked changes, listed separately.")
        case .turn: Text(ReviewLayer.turn.detail)
        case .branch: Text("Everything this branch adds, including work not committed yet.")
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
                segment(scope.pickerLabel, tag: scope)
                    .accessibilityLabel(scope.pickerAccessibilityLabel)
                    .help(scope.pickerHelp)
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

    nonisolated static func animatesSelection(
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
