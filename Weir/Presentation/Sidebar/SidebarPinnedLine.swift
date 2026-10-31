// SidebarPinnedLine.swift
// Weir — how a sidebar line sits against the project header pinned at the top of the list.

import Foundation

enum SidebarPinnedLine {
    /// How much of the line's top is under the header.
    static func hiddenHeight(lineTop: CGFloat, lineHeight: CGFloat, pinnedBottom: CGFloat) -> CGFloat {
        min(lineHeight, max(0, pinnedBottom - lineTop))
    }
}
