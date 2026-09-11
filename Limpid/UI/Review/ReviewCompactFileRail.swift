// ReviewCompactFileRail.swift
// Limpid — switches the Review file list between an inline rail and a
// transient drawer while preserving the diff's readable width.

import SwiftUI

extension ReviewWorkspaceView {
    var showsInlineFileRail: Bool {
        !store.files.isEmpty && ReviewRail.width(reviewPresentation.railWidth, in: available) != nil
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
            withAnimation(LimpidMotion.sidebarToggle) {
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
        withAnimation(LimpidMotion.sidebarToggle, completionCriteria: .removed) {
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
            HStack(spacing: 0) {
                inlineFileRail
                diffColumn
                    .allowsHitTesting(!isCompactFileRailPresented)
                    .accessibilityHidden(isCompactFileRailPresented)
            }
            compactFileRailOverlay
        }
        // The drawer's leading-edge motion would otherwise paint into the tab
        // column during the first and last animation frames.
        .clipped()
    }

    /// The inline list yields when it cannot coexist with a readable diff.
    /// The same list remains available as a transient drawer from the file bar.
    @ViewBuilder
    private var inlineFileRail: some View {
        if showsInlineFileRail {
            ReviewFileRail(
                files: store.files,
                stats: store.stats,
                commentCounts: store.commentCounts,
                viewed: Set(store.viewed.keys),
                selection: fileID,
                isTree: $isTreeLayout,
                hidesViewed: $hidesViewedFiles,
                onSelect: select,
                onToggleViewed: toggleViewed,
                available: available,
                widthOverride: nil,
                onClose: nil
            )
            // The grab area rides on the divider rather than beside it. As a
            // sibling it takes six points and leaves a gap in the row colors.
            Divider()
                .overlay {
                    DividerResizeHandle(
                        currentWidth: { reviewPresentation.railWidth },
                        setWidth: { reviewPresentation.railWidth = $0 },
                        minWidth: ReviewRail.minimum,
                        maxWidth: max(
                            ReviewRail.minimum,
                            min(ReviewRail.maximum, available - ReviewRail.diffMinimum)
                        ),
                        defaultWidth: ReviewRail.default,
                        accessibilityLabel: Text("File List Width")
                    )
                }
        }
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
                files: store.files,
                stats: store.stats,
                commentCounts: store.commentCounts,
                viewed: Set(store.viewed.keys),
                selection: fileID,
                isTree: $isTreeLayout,
                hidesViewed: $hidesViewedFiles,
                onSelect: selectFromCompactFileRail,
                onToggleViewed: toggleViewed,
                available: available,
                widthOverride: compactFileRailWidth,
                onClose: dismissCompactFileRail
            )
            .background(LimpidColor.tabColumnSolidFill)
            .overlay(alignment: .trailing) { Divider() }
            .transientLeadingPanelShadow()
            .offset(x: isCompactFileRailPresented ? 0 : -compactFileRailWidth)
            .opacity(reduceMotion && !isCompactFileRailPresented ? 0 : 1)
            .allowsHitTesting(isCompactFileRailPresented)
            .accessibilityHidden(!isCompactFileRailPresented)
            .animation(
                reduceMotion ? nil : LimpidMotion.sidebarToggle,
                value: isCompactFileRailPresented
            )
        }
    }
}
