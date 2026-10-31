// SidebarProjectSection.swift
// Weir — one project in the sidebar's list: its pinned header and the lines under it.

import SwiftUI

/// Where the arrow keys scroll a line to: the line and, above it, the room
/// of the header pinned at the list's top, which would otherwise cover the
/// line they reached going up.
struct KeyboardScrollAnchor: Hashable {
    let line: SidebarItemID
}

/// Cuts a line where it passes under the header pinned at the top of the list.
/// Only a line crossing the header's bottom changes as the list scrolls, as
/// the height stays 0 below it and whole above it, so scrolling redraws one.
private struct SidebarPinnedLineClip: ViewModifier {
    /// The line went under the header, or came out, which the scroll view's
    /// own account of what is in sight does not know.
    let onCovered: (Bool) -> Void
    @State private var hiddenHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .clipShape(TopCut(height: hiddenHeight))
            .onGeometryChange(for: CGFloat.self) { geometry in
                SidebarPinnedLine.hiddenHeight(
                    lineTop: geometry.frame(in: .scrollView).minY,
                    lineHeight: geometry.size.height,
                    pinnedBottom: WeirLayout.Supervision.sidebarProjectHeaderHeight
                )
            } action: { old, new in
                hiddenHeight = new
                if (old > 0) != (new > 0) {
                    onCovered(new > 0)
                }
            }
            .onDisappear { onCovered(false) }
    }

    /// Everything but the top `height` of the line. What a line draws past
    /// its own edges is kept while nothing is cut.
    private struct TopCut: Shape {
        var height: CGFloat

        func path(in rect: CGRect) -> Path {
            // Past anything a line draws outside itself (a drop mark).
            let outset: CGFloat = 80
            let top = height > 0 ? rect.minY + height : rect.minY - outset
            return Path(CGRect(x: rect.minX - outset, y: top, width: rect.width + 2 * outset, height: rect.maxY + outset - top))
        }
    }
}

/// One project in the sidebar's list: its header, which stays at the top
/// while its rows pass under it, and its rows.
struct SidebarProjectSection<Header: View, Line: View>: View {
    let group: SidebarListModel.Group
    let isLast: Bool
    let drag: SidebarProjectDrag
    let onLineCovered: (SidebarItemID, Bool) -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let line: (SessionSidebarModel.Item) -> Line

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Section {
            ForEach(group.rows?.items ?? []) { item in
                line(item)
                    // The header has no ground of its own, which on a
                    // see-through surface would show as a band and let the
                    // lines through. A line is cut at the header instead.
                    .modifier(SidebarPinnedLineClip { onLineCovered(item.id, $0) })
                    .background {
                        Color.clear
                            .id(KeyboardScrollAnchor(line: item.id))
                            .padding(.top, -Layout.sidebarProjectHeaderHeight)
                    }
                    .id(item.id)
            }
            // The gap that sets the next project apart. It ends this section
            // rather than tops the next header, so a pinned header has no
            // gap above it.
            if !isLast {
                Color.clear
                    .frame(height: Layout.sidebarProjectGap - Layout.sessionRowSpacing)
                    .accessibilityHidden(true)
            }
        } header: {
            header()
                // Where the reorder layer's headers gather from and return to.
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named(SidebarProjectDragSurface.space)).minY
                } action: { drag.setHeaderTop($0, of: group.id) }
                .onDisappear { drag.setHeaderTop(nil, of: group.id) }
                .background { Color.clear.id(KeyboardScrollAnchor(line: .header(group.id))) }
                .id(SidebarItemID.header(group.id))
        }
    }
}
