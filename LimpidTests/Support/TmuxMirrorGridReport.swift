// TmuxMirrorGridReport.swift
// Limpid — sizes a mirror tab's tmux window in tests through the reports the app sends.

import CoreGraphics
import Foundation
@testable import Limpid

extension TmuxConnectionStore {
    /// One cell of every mirror surface these tests pretend to have.
    static let testCellSize = CellSize(width: 8, height: 16)

    /// The pane area that fits exactly `columns` x `rows` test cells inside
    /// the pinned padding. The extra point keeps the floor division off an
    /// exact boundary.
    static func testAreaSize(columns: Int, rows: Int) -> CGSize {
        CGSize(
            width: columns * 8 + 2 * OuterPadding.pinned.horizontal + 1,
            height: rows * 16 + 2 * OuterPadding.pinned.vertical + 1
        )
    }

    /// Size mirror tab `tabID` to `columns` x `rows` as the app does: leaf
    /// `leafID` reports its cell size, and the pane area reports its size.
    /// The mirror sends `refresh-client -C` only when the grid moved.
    func reportTestGrid(columns: Int, rows: Int, tabID: UUID, leafID: UUID) {
        cellSizeChanged(Self.testCellSize, paneID: leafID)
        areaSizeChanged(Self.testAreaSize(columns: columns, rows: rows), tabID: tabID)
    }
}
