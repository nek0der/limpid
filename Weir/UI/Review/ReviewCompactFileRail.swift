// ReviewCompactFileRail.swift
// Weir — switches the Review file list between an inline rail and a
// transient drawer while preserving the diff's readable width.

import SwiftUI

extension ReviewWorkspaceView {
    /// Asked of the surface's width alone. This view must not read the rail's
    /// width: a drag changes it every frame, and the workspace that read it
    /// rebuilt the diff table beside the list on each one.
    var showsInlineFileRail: Bool {
        !reviewSession.files.isEmpty && ReviewRail.isInline(in: available)
    }

    /// Leave enough uncovered diff to make the drawer's overlay relationship
    /// visible and to provide a generous outside-click dismissal target.
    private var compactFileRailWidth: CGFloat {
        let maximum = min(ReviewRail.maximum, max(ReviewRail.minimum, available - 44))
        return min(max(reviewPresentation.railWidth, ReviewRail.minimum), maximum)
    }

    func presentCompactFileRail() {
        guard !composer.isOpen, !search.isPresented else { return }
        guard !isCompactFileRailPresented else { return }
        isCompactFileRailMounted = true
        if reduceMotion {
            isCompactFileRailPresented = true
            return
        }
        Task { @MainActor in
            // Give SwiftUI one update with the drawer at its offscreen offset
            // before changing the value that animates it into place.
            await Task.yield()
            guard isCompactFileRailMounted else { return }
            withAnimation(WeirMotion.sidebarToggle) {
                isCompactFileRailPresented = true
            }
        }
    }

    func dismissCompactFileRail() {
        guard isCompactFileRailMounted else { return }
        if reduceMotion {
            isCompactFileRailPresented = false
            isCompactFileRailMounted = false
            return
        }
        withAnimation(WeirMotion.sidebarToggle, completionCriteria: .removed) {
            isCompactFileRailPresented = false
        } completion: {
            guard !isCompactFileRailPresented else { return }
            isCompactFileRailMounted = false
        }
    }

    private func selectFromCompactFileRail(_ id: String) {
        select(id)
        dismissCompactFileRail()
    }

    var reviewContentArea: some View {
        ZStack(alignment: .leading) {
            ReviewInlineSplit(available: available, presentation: reviewPresentation, showsRail: showsInlineFileRail) {
                inlineFileRail
            } diff: {
                diffColumn
                    .allowsHitTesting(!isCompactFileRailPresented)
                    .accessibilityHidden(isCompactFileRailPresented)
            }
            compactFileRailOverlay
        }
        // Exactly the width offered, laid from the leading edge. The list
        // and the diff add up to it (`ReviewRail.maximumWidth(in:)`), but a
        // row that came out wider anyway would otherwise widen the surface
        // and re-center the chrome above it; here it is cut off at the
        // trailing edge instead.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(!reviewSession.isLoading)
        // The drawer's leading-edge motion would otherwise paint into the tab
        // column during the first and last animation frames.
        .clipped()
    }

    /// The inline list, which yields when it cannot coexist with a readable
    /// diff (`showsInlineFileRail`). The same list remains available as a
    /// transient drawer from the bar over the stacked diff (`ReviewStackBar`).
    private var inlineFileRail: some View {
        ReviewFileRail(
            root: reviewSession.root,
            files: reviewSession.files,
            stats: reviewSession.stats,
            commentCounts: reviewSession.commentCounts,
            viewed: Set(reviewSession.viewed.keys),
            selection: fileID,
            isTree: $isTreeLayout,
            hidesViewed: $hidesViewedFiles,
            onSelect: select,
            onToggleViewed: toggleViewed,
            available: available,
            widthOverride: nil,
            onClose: nil
        )
        .modifier(ReviewTabPrimaryKey())
    }

    @ViewBuilder
    private var compactFileRailOverlay: some View {
        if !showsInlineFileRail, isCompactFileRailMounted {
            if isCompactFileRailPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissCompactFileRail)
                    .accessibilityHidden(true)
            }
            ReviewFileRail(
                root: reviewSession.root,
                files: reviewSession.files,
                stats: reviewSession.stats,
                commentCounts: reviewSession.commentCounts,
                viewed: Set(reviewSession.viewed.keys),
                selection: fileID,
                isTree: $isTreeLayout,
                hidesViewed: $hidesViewedFiles,
                onSelect: selectFromCompactFileRail,
                onToggleViewed: toggleViewed,
                available: available,
                widthOverride: compactFileRailWidth,
                onClose: dismissCompactFileRail
            )
            .modifier(ReviewTabPrimaryKey())
            .background(WeirColor.reviewRailSolidFill)
            // In a stack, as the inline list's edge is (`ReviewRailEdge`).
            .overlay(alignment: .trailing) { HStack(spacing: 0) { Divider() } }
            .transientLeadingPanelShadow()
            .offset(x: isCompactFileRailPresented ? 0 : -compactFileRailWidth)
            .opacity(reduceMotion && !isCompactFileRailPresented ? 0 : 1)
            .allowsHitTesting(isCompactFileRailPresented)
            .accessibilityHidden(!isCompactFileRailPresented)
            .animation(
                reduceMotion ? nil : WeirMotion.sidebarToggle,
                value: isCompactFileRailPresented
            )
        }
    }
}

/// The inline file list, its edge, and the diff beside it, side by side:
/// the one place the three are put together, which the review and its
/// layout tests both draw. The list and the diff add up to the width
/// offered — the list clamped by `ReviewRail.maximumWidth(in:)`, the diff
/// at least `ReviewRail.diffMinimum` — only while nothing else stands
/// between them; the edge is drawn inside the list for that reason.
struct ReviewInlineSplit<Rail: View, Diff: View>: View {
    let available: CGFloat
    let presentation: ReviewPresentation
    /// Whether the list is inline (`ReviewRail.isInline(in:)`); the diff
    /// takes the whole width when it is not.
    let showsRail: Bool
    @ViewBuilder var rail: () -> Rail
    @ViewBuilder var diff: () -> Diff

    var body: some View {
        HStack(spacing: 0) {
            if showsRail {
                rail()
                    .modifier(ReviewRailEdge(available: available, presentation: presentation))
            }
            // The diff column's floor is the one the rail math is built on:
            // with the list inline, the two add up to
            // `ReviewRail.inlineMinimumWidth`, which is what the window
            // layout keeps clear for the surface. Any other number here
            // makes the column wider than that sum and the surface wider
            // than the window.
            diff()
                .frame(minWidth: ReviewRail.diffMinimum, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The inline list's trailing edge: its divider, with the grab area riding
/// on it.
///
/// Drawn over the list's last point rather than beside it, as the drawer's
/// is. As a sibling the divider was a point the rail's clamp did not count,
/// so at the cap the list and the diff came to a point wider than the
/// surface. The grab area rides on the divider for the reason it always
/// did: beside it, it takes six points and leaves a gap in the row colors.
struct ReviewRailEdge: ViewModifier {
    let available: CGFloat
    /// Handed in rather than read from the environment, so a hosted test can
    /// lay the edge out without a review around it. Only the handle's
    /// closures read its width, so the view applying this does not.
    let presentation: ReviewPresentation

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            // In a stack of its own so it is a vertical rule: a `Divider`
            // outside a stack lies across, and alone in an overlay it is a
            // line through the middle of the list — which is what the
            // drawer's edge was.
            HStack(spacing: 0) {
                Divider()
            }
            .overlay {
                DividerResizeHandle(
                    currentWidth: { presentation.railWidth },
                    setWidth: { presentation.resizeRail(to: $0, in: available) },
                    minWidth: ReviewRail.minimum,
                    maxWidth: ReviewRail.maximumWidth(in: available),
                    defaultWidth: ReviewRail.default,
                    accessibilityLabel: Text("File List Width")
                )
            }
        }
    }
}
