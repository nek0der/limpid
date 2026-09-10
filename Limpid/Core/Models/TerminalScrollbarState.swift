// TerminalScrollbarState.swift
// Limpid — normalizes libghostty scrollback metrics and maps them to AppKit geometry.

import CoreGraphics
import Foundation

struct TerminalScrollbarState: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64

    init(total: UInt64, offset: UInt64, length: UInt64) {
        self.total = total
        self.length = min(length, total)
        self.offset = min(offset, total - self.length)
    }

    var maximumOffset: UInt64 {
        total - length
    }

    var isScrollable: Bool {
        length > 0 && maximumOffset > 0
    }

    /// Give NSScrollView a proportional document: its knob then represents
    /// `length / total` without depending on a separately reported cell size.
    func documentHeight(for viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, isScrollable else { return max(0, viewportHeight) }
        return viewportHeight * CGFloat(total) / CGFloat(length)
    }

    /// AppKit measures from the document bottom while libghostty's offset is
    /// from the history top, so the two progress in opposite directions.
    func documentOriginY(for viewportHeight: CGFloat) -> CGFloat {
        let travel = documentHeight(for: viewportHeight) - viewportHeight
        guard travel > 0, maximumOffset > 0 else { return 0 }
        let progress = CGFloat(offset) / CGFloat(maximumOffset)
        return travel * (1 - progress)
    }

    func rowOffset(forDocumentOriginY originY: CGFloat, viewportHeight: CGFloat) -> UInt64 {
        let travel = documentHeight(for: viewportHeight) - viewportHeight
        guard travel > 0, maximumOffset > 0 else { return 0 }
        let clamped = min(max(0, originY), travel)
        let progress = 1 - clamped / travel
        return UInt64((progress * CGFloat(maximumOffset)).rounded())
    }
}
