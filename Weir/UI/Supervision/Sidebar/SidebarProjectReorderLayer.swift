// SidebarProjectReorderLayer.swift
// Weir — the layer of project headers laid over the sidebar's list while one is dragged.

import SwiftUI

/// Every project's header, one after another, over a list left as it was.
struct SidebarProjectReorderLayer: View {
    let drag: SidebarProjectDrag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = WeirLayout.Supervision

    /// Nearly opaque: the list's words read as clutter behind the headers, and
    /// a trace of them says the list is still there.
    private static let scrimOpacity = 0.96

    var body: some View {
        ZStack(alignment: .topLeading) {
            SupervisionTokens.window.color
                .opacity(drag.hidesList ? Self.scrimOpacity : 0)
                .animation(reduceMotion ? nil : WeirMotion.dropIndicator, value: drag.hidesList)
            if drag.phase != nil {
                ForEach(drag.entries) { entry in
                    row(entry)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var motion: Animation? {
        reduceMotion ? nil : WeirMotion.reorder
    }

    private func row(_ entry: SidebarProjectDrag.Entry) -> some View {
        let isLifted = drag.isLifted(entry.id)
        let shape = RoundedRectangle(cornerRadius: Layout.sessionRowCornerRadius, style: .continuous)
        return HStack(spacing: Layout.spaceSnug) {
            ProjectAvatar(name: entry.name, paletteIndex: entry.paletteIndex, size: .header)
            Text(verbatim: entry.name)
                // As the list's header draws it, so nothing changes as the layer
                // takes over from it.
                .font(.supervision(.label, weight: entry.isCollapsed ? .medium : .bold))
                .foregroundStyle(entry.isCollapsed ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                .lineLimit(1)
                .supervisionTruncation(.name)
                .layoutPriority(1)
            Rectangle()
                .fill(SupervisionTokens.line.color)
                .frame(height: 1)
                .frame(minWidth: Layout.spaceM)
        }
        .padding(.horizontal, Layout.sessionRowHorizontalInset)
        .frame(height: Layout.sidebarProjectHeaderHeight)
        .background {
            if isLifted {
                shape.fill(SupervisionTokens.popover.color).modifier(FloatingSurfaceShadow())
            }
        }
        .padding(.horizontal, Layout.sidebarListInset)
        .offset(y: drag.top(of: entry.id))
        .opacity(drag.isShown(entry.id) ? 1 : 0)
        .animation(reduceMotion ? nil : WeirMotion.dropIndicator, value: drag.isShown(entry.id))
        // The held header stays on the pointer; the others slide.
        .animation(isLifted ? nil : motion, value: drag.top(of: entry.id))
    }
}

/// What the list's drag reads of the scroll view, and the layer over it.
struct SidebarProjectDragSurface: ViewModifier {
    /// What the pointer's height in the list is measured against.
    nonisolated static let space = "sidebarProjectList"

    let drag: SidebarProjectDrag

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drag.visibleHeight = $0 }
            .overlay { SidebarProjectReorderLayer(drag: drag) }
    }
}
