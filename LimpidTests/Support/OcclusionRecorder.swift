// OcclusionRecorder.swift
// Limpid — records each visible set the window registry hands the terminals.

import Foundation
@testable import Limpid

/// Stands in for the surface registry's occlusion so a test can read which
/// panes were told they are visible, in order, without an AppKit window.
@MainActor
final class OcclusionRecorder: PaneOcclusionApplying {
    var applied: [Set<UUID>] = []

    func updateOcclusion(visibleIDs: Set<UUID>) {
        applied.append(visibleIDs)
    }
}
