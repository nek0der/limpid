// ProjectWindowState+SidebarWidth.swift
// Limpid — the width a window's sidebar is drawn at, from the layout's constants.

import CoreGraphics

extension ProjectWindowState {
    /// The width this window's sidebar is drawn at, against the body last
    /// measured (`SupervisionWindowWidths.sidebarDrawnWidth`). Read by
    /// everything that needs the sidebar's width on screen (the sidebar,
    /// its divider, the changes panel's layout, and the approval card), so
    /// none of them goes by the saved width while the window holds the
    /// sidebar narrower.
    var sidebarDrawnWidth: CGFloat {
        SupervisionWindowWidths.sidebarDrawnWidth(
            saved: selection.sidebarWidth,
            range: LimpidLayout.Supervision.sidebarWidthRange,
            bodyWidth: changesPanelSharedWidth,
            surfaceGap: LimpidLayout.Supervision.surfaceGap,
            sessionMinWidth: LimpidLayout.reviewMinWidth
        )
    }

    /// The widest the sidebar can be drawn in this window now
    /// (`SupervisionWindowWidths.sidebarDrawnMaxWidth`).
    var sidebarDrawnMaxWidth: CGFloat {
        SupervisionWindowWidths.sidebarDrawnMaxWidth(
            range: LimpidLayout.Supervision.sidebarWidthRange,
            bodyWidth: changesPanelSharedWidth,
            surfaceGap: LimpidLayout.Supervision.surfaceGap,
            sessionMinWidth: LimpidLayout.reviewMinWidth
        )
    }
}
