// VerticalSplitView.swift
// Limpid — `NSSplitView`-backed vertical split for the container slab.
//
// Why AppKit instead of SwiftUI's `VSplitView`: a SwiftUI `ScrollView`
// stacked above a sibling in a plain `VStack` stops delivering drop
// hit-tests to whatever row sits flush against its bottom frame edge —
// the last container row silently refused tab drops (no `dropEntered`,
// no highlight, no `performDrop`), observed on macOS 26. Hosting the two
// panes as real `NSSplitView` subviews fixes that. `VSplitView` fixes it
// too, but SwiftUI exposes no way to style its divider, and the slab is
// designed around an inset hairline rule rather than the system one.
// `dividerColor` and `drawDivider(in:)` can only be reached by
// overriding them, which needs the split view to be ours.
//
// The panes are `NSHostingView`s. They do inherit the enclosing SwiftUI
// environment through the representable, but callers are expected to
// hand in content that already carries every value its subtree reads
// rather than rely on that.

import AppKit
import SwiftUI

/// `NSSplitView` drawing the slab's inset hairline instead of the
/// system divider.
final class LimpidSplitView: NSSplitView {
    /// Height of the band that counts as the divider for input. Both the
    /// drag area and the double-click area are derived from it, so the
    /// two can't disagree about where the divider is.
    static let grabThickness: CGFloat = 8

    /// Inset so the rule doesn't run edge-to-edge into the sidebar
    /// frame; matches the header's horizontal padding, as the
    /// hand-rolled rule this view replaced did.
    static let ruleInset: CGFloat = 18

    /// Invoked when the divider itself is double-clicked.
    var onDividerDoubleClick: (() -> Void)?

    /// True while `NSSplitView` tracks a divider drag, which it runs
    /// from `mouseDown` until the mouse comes up. It is the only signal
    /// that separates the user moving the divider from a layout pass:
    /// the divider index AppKit puts in the resize notification is set
    /// for layout too, and gating on it let the initial even split
    /// overwrite a stored share.
    private(set) var isTrackingDividerDrag = false

    /// Invoked one run-loop hop after the first `layout()` with a real
    /// height. `updateNSView` can't be used for this: SwiftUI only
    /// calls it on state changes, so it may never fire after AppKit
    /// hands the split view its size.
    var onFirstLayout: (() -> Void)?

    override var dividerColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.1)
    }

    /// Held at a hairline independently of `dividerStyle`, which is what
    /// the default thickness follows.
    override var dividerThickness: CGFloat {
        1
    }

    /// `dividerColor` alone fills edge to edge; the slab's rule is
    /// inset, so we draw it ourselves.
    override func drawDivider(in rect: NSRect) {
        let inset = rect.insetBy(dx: Self.ruleInset, dy: 0)
        guard inset.width > 0 else { return }
        dividerColor.setFill()
        inset.fill()
    }

    override func layout() {
        super.layout()
        guard bounds.height > 0, onFirstLayout != nil else { return }
        // Deferred by a run-loop hop so the share resolves against the
        // view's real height rather than the intermediate one the first
        // pass runs at — measured at launch as 366pt before 866pt. The
        // hook is cleared inside the hop, not before it: if the view
        // lost its height in the meantime we leave it armed for the
        // next layout rather than dropping the restore on the floor.
        Task { @MainActor [weak self] in
            guard let self, self.bounds.height > 0, let hook = self.onFirstLayout else { return }
            self.onFirstLayout = nil
            hook()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard dividerBand()?.contains(convert(event.locationInWindow, from: nil).y) == true else {
            super.mouseDown(with: event)
            return
        }
        // Taken before `super`, which would otherwise begin tracking a
        // drag on this same event.
        if event.clickCount == 2, let reset = onDividerDoubleClick {
            reset()
            return
        }
        isTrackingDividerDrag = true
        super.mouseDown(with: event)
        isTrackingDividerDrag = false
    }

    /// The drawn divider grown to the grab band, for
    /// `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)`.
    func grabRect(around drawnRect: NSRect) -> NSRect {
        drawnRect.insetBy(dx: 0, dy: -grabPadding(forDividerHeight: drawnRect.height))
    }

    private func grabPadding(forDividerHeight height: CGFloat) -> CGFloat {
        max(0, (Self.grabThickness - height) / 2)
    }

    /// Y range the divider occupies, widened by the same padding
    /// `grabRect(around:)` applies so the double-click area matches the
    /// drag area. Derived from the two panes rather than assumed, so it
    /// holds whichever way the view's coordinate system is flipped.
    private func dividerBand() -> ClosedRange<CGFloat>? {
        guard arrangedSubviews.count == 2 else { return nil }
        let frames = arrangedSubviews.map(\.frame).sorted { $0.minY < $1.minY }
        let lower = frames[0].maxY
        let upper = frames[1].minY
        guard upper >= lower else { return nil }
        let pad = grabPadding(forDividerHeight: upper - lower)
        return (lower - pad)...(upper + pad)
    }
}

/// Two SwiftUI panes stacked vertically with a draggable hairline
/// divider between them.
struct VerticalSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    /// Floor for the upper pane, declared through the split view's
    /// divider limits.
    let topMinHeight: CGFloat
    /// Floor for the lower pane, resolved together with
    /// `bottomFractionRange` wherever the divider is positioned.
    let bottomMinHeight: CGFloat
    /// Share of the split the lower pane is kept within, on every path
    /// that positions the divider, so the caller can store what it is
    /// handed without clamping it again.
    let bottomFractionRange: ClosedRange<CGFloat>
    /// The stored share the lower pane is laid out from: applied a
    /// run-loop hop after the first layout pass, and again on every
    /// window resize so the pane holds this share instead of drifting.
    /// A drag moves the divider away from it, and the caller feeds the
    /// new share back through `onBottomFractionChanged`.
    let bottomInitialFraction: CGFloat
    /// Share to restore on a divider double-click.
    let bottomDefaultFraction: CGFloat
    /// Fires while the user drags the divider, and once on a
    /// double-click reset — the two moments the share is the user's
    /// choice rather than a consequence of the current window height.
    let onBottomFractionChanged: (CGFloat) -> Void
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    func makeNSView(context: Context) -> LimpidSplitView {
        let split = LimpidSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let topHost = NSHostingView(rootView: top())
        let bottomHost = NSHostingView(rootView: bottom())
        context.coordinator.topHost = topHost
        context.coordinator.bottomHost = bottomHost
        split.addArrangedSubview(topHost)
        split.addArrangedSubview(bottomHost)

        // `NSSplitView` has no double-click-to-reset of its own; the
        // hand-rolled divider it replaced had one, so we re-add it.
        split.onDividerDoubleClick = { [weak split] in
            guard let split else { return }
            context.coordinator.resetDivider(in: split)
        }
        split.onFirstLayout = { [weak split] in
            guard let split else { return }
            context.coordinator.applyInitialPosition(in: split)
        }

        return split
    }

    func updateNSView(_: LimpidSplitView, context: Context) {
        context.coordinator.parent = self
        // Hand the current bodies back to the hosts so values the
        // closures captured reach the panes — Observation covers the
        // stores they read, not what the call site closed over.
        context.coordinator.topHost?.rootView = top()
        context.coordinator.bottomHost?.rootView = bottom()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var parent: VerticalSplitView
        var topHost: NSHostingView<Top>?
        var bottomHost: NSHostingView<Bottom>?

        init(_ parent: VerticalSplitView) {
            self.parent = parent
        }

        /// Called one run-loop hop after the split view's first layout
        /// pass with a real height. Reading the height from the split
        /// view rather than from SwiftUI is what lets the stored share
        /// apply that early.
        func applyInitialPosition(in split: LimpidSplitView) {
            guard split.bounds.height > 0 else { return }
            setBottom(fraction: parent.bottomInitialFraction, in: split)
        }

        func resetDivider(in split: LimpidSplitView) {
            setBottom(fraction: parent.bottomDefaultFraction, in: split)
            // Stored from the intent rather than read back from the
            // frame: a short window floors the pane above the default,
            // and storing that would move the divider again next launch.
            parent.onBottomFractionChanged(parent.bottomDefaultFraction)
        }

        private func setBottom(fraction: CGFloat, in split: LimpidSplitView) {
            let total = split.bounds.height
            guard total > 0 else { return }
            let allowed = bottomHeightRange(forTotal: total)
            let target = min(max(total * fraction, allowed.lowerBound), allowed.upperBound)
            split.setPosition(
                max(0, total - target - split.dividerThickness),
                ofDividerAt: 0
            )
        }

        /// Height the lower pane is allowed to occupy at this total —
        /// the point floor and the share band resolved together. Every
        /// limit on the lower pane's own height comes from here, so the
        /// drag, the restore, the reset, and the window resize can't
        /// disagree. `topMinHeight` is applied separately, in
        /// `constrainMinCoordinate`.
        /// `upperBound` is floored at `lowerBound` so a window too short
        /// for both still yields a valid range.
        private func bottomHeightRange(forTotal total: CGFloat) -> ClosedRange<CGFloat> {
            let lower = max(parent.bottomMinHeight, total * parent.bottomFractionRange.lowerBound)
            let upper = max(lower, total * parent.bottomFractionRange.upperBound)
            return lower...upper
        }

        func splitView(
            _ splitView: NSSplitView,
            effectiveRect _: NSRect,
            forDrawnRect drawnRect: NSRect,
            ofDividerAt _: Int
        ) -> NSRect {
            (splitView as? LimpidSplitView)?.grabRect(around: drawnRect) ?? drawnRect
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt _: Int
        ) -> CGFloat {
            // Smallest position = largest lower pane, so this is where
            // the band's upper bound lands.
            let total = splitView.bounds.height
            let ceiling = total
                - bottomHeightRange(forTotal: total).upperBound
                - splitView.dividerThickness
            return max(proposedMinimumPosition, parent.topMinHeight, ceiling)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt _: Int
        ) -> CGFloat {
            let total = splitView.bounds.height
            let floor = total
                - bottomHeightRange(forTotal: total).lowerBound
                - splitView.dividerThickness
            return min(proposedMaximumPosition, max(0, floor))
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
            // `adjustSubviews` scales both panes by one factor and does
            // not apply the delegate's limits, so a shrinking window
            // walks the lower pane straight past `bottomMinHeight` —
            // measured at 52pt in a 400pt-tall window. Re-deriving the
            // split from the stored share holds the floor at every
            // window size, and because the result is a function of
            // (height, share) alone the pane returns to where the user
            // put it when the window grows back, instead of carrying a
            // floored share forward.
            splitView.adjustSubviews()
            guard let split = splitView as? LimpidSplitView else { return }
            setBottom(fraction: parent.bottomInitialFraction, in: split)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Only a drag is the user's choice. Everything else that
            // moves these panes — the initial even split, the restore,
            // a window resize — sizes them against the window, and the
            // `bottomMinHeight` floor makes that a different share from
            // the one the user set. Storing it replaced a saved 0.15
            // with the floored share on the first launch into a short
            // window.
            guard let split = notification.object as? LimpidSplitView,
                  split.isTrackingDividerDrag,
                  split.arrangedSubviews.count == 2
            else { return }
            let total = split.bounds.height
            guard total > 0 else { return }
            parent.onBottomFractionChanged(
                split.arrangedSubviews[1].frame.height / total
            )
        }
    }
}
