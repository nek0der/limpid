// TmuxSurfaceReports.swift
// Limpid — what the surfaces of tmux leaves and the pane areas of mirror tabs last reported.

import CoreGraphics
import Foundation

/// The last value each surface and pane area reported, kept whether or not a
/// mirror is feeding them. libghostty and SwiftUI report these only when they
/// change, so a mirror attached to a leaf whose surface already exists would
/// otherwise never learn them: it could not size the tmux window, and its
/// panes would stay paused waiting for a grid that was reported before it
/// existed. `TmuxConnectionStore` owns the only copy; a mirror reads it when
/// it starts and whenever the store forwards a new report.
struct TmuxSurfaceReports: Equatable {
    /// One cell in points, per leaf.
    private(set) var cellSizes: [UUID: CellSize] = [:]
    /// The grid libghostty last gave the leaf's surface. Present only once
    /// the surface has started its IO.
    private(set) var grids: [UUID: TmuxWindowMirror.Grid] = [:]
    /// The pane area in points, per tab. Only a tab that was on screen has
    /// one; it keeps the last size while the tab is in the background.
    private(set) var areaSizes: [UUID: CGSize] = [:]

    mutating func setCellSize(_ size: CellSize, paneID: UUID) {
        cellSizes[paneID] = size
    }

    mutating func setGrid(_ grid: TmuxWindowMirror.Grid, paneID: UUID) {
        grids[paneID] = grid
    }

    mutating func setAreaSize(_ size: CGSize, tabID: UUID) {
        areaSizes[tabID] = size
    }

    /// Forget every leaf and tab that is no longer listed.
    mutating func retain(leaves: Set<UUID>, tabs: Set<UUID>) {
        cellSizes = cellSizes.filter { leaves.contains($0.key) }
        grids = grids.filter { leaves.contains($0.key) }
        areaSizes = areaSizes.filter { tabs.contains($0.key) }
    }
}
