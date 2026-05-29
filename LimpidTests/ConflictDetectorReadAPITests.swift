// ConflictDetectorReadAPITests.swift
// Limpid — the read API the UI consumes (Step 6a): visibleConflicts /
// conflicts(involving:) / isParty, and the bridge's id helpers. States
// are driven through the public API (reevaluate / ignore / grace) rather
// than a test backdoor, so the status→visibility mapping is exercised
// end to end.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("ConflictDetector read API")
struct ConflictDetectorReadAPITests {

    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    private func snap(_ id: String, paths: Set<String>, at: Date) -> WorktreeSnapshot {
        WorktreeSnapshot(
            worktree: WatchedWorktree(
                id: WorktreeID(raw: id),
                rootURL: URL(fileURLWithPath: "/tmp/\(id)"),
                projectID: ProjectID(raw: "p"),
                branch: id,
                isPrimary: false,
                writerTabID: nil
            ),
            changeSet: ChangeSet(
                workTreeID: WorktreeID(raw: id),
                changedPaths: paths,
                lastTouched: Dictionary(uniqueKeysWithValues: paths.map { ($0, at) }),
                capturedAt: at
            )
        )
    }

    @Test("active is visible; ignored is hidden; isParty follows")
    func visible_activeAndIgnored() async {
        let box = SnapshotBox()
        box.set([
            snap("A", paths: ["x"], at: t0), snap("B", paths: ["x"], at: t0),
            snap("C", paths: ["y"], at: t0), snap("D", paths: ["y"], at: t0)
        ])
        let detector = ConflictDetector(now: { self.t0 }, snapshotProvider: { box.snapshots })
        await detector.reevaluate()
        #expect(detector.visibleConflicts.count == 2)
        #expect(detector.isParty(WorktreeID(raw: "A")))
        #expect(detector.conflicts(involving: WorktreeID(raw: "A")).count == 1)

        detector.ignore(ConflictID(members: [WorktreeID(raw: "C"), WorktreeID(raw: "D")]))
        #expect(detector.visibleConflicts.count == 1)
        #expect(detector.isParty(WorktreeID(raw: "C")) == false)
        #expect(detector.isParty(WorktreeID(raw: "A")))

        // Ignored is silenced from `isParty` but still reachable: the
        // muted ⚠ re-entry must find it so the user can un-ignore.
        #expect(detector.ignoredConflicts(involving: WorktreeID(raw: "C")).count == 1)
        #expect(detector.anyOpenableConflict(involving: WorktreeID(raw: "C")) != nil)
        // An uninvolved worktree has neither.
        #expect(detector.ignoredConflicts(involving: WorktreeID(raw: "Z")).isEmpty)
        #expect(detector.anyOpenableConflict(involving: WorktreeID(raw: "Z")) == nil)
    }

    @Test("resolving stays visible; resolved (dropped) does not")
    func visible_resolvingThenResolved() async {
        let box = SnapshotBox()
        box.set([snap("A", paths: ["x"], at: t0), snap("B", paths: ["x"], at: t0)])
        var clock = t0
        var config = DetectorConfig()
        config.gracePeriod = 12
        let detector = ConflictDetector(config: config, now: { clock }, snapshotProvider: { box.snapshots })

        await detector.reevaluate() // active
        #expect(detector.visibleConflicts.count == 1)

        box.set([]) // overlap gone
        clock = t0.addingTimeInterval(5)
        await detector.reevaluate() // within grace → resolving, still shown
        #expect(detector.visibleConflicts.count == 1)
        #expect(detector.isParty(WorktreeID(raw: "A")))

        clock = t0.addingTimeInterval(60)
        await detector.reevaluate() // past grace → resolved + dropped
        #expect(detector.visibleConflicts.isEmpty)
        #expect(detector.isParty(WorktreeID(raw: "A")) == false)
    }

    @Test("bridge id helpers match the ids minted for watched worktrees")
    func bridgeIDHelpers_matchWatchedIDs() {
        let projectID = UUID()
        let worktreeRowID = UUID()
        #expect(ConflictWorktreeBridge.id(forProject: projectID) == WorktreeID(raw: projectID.uuidString))
        #expect(ConflictWorktreeBridge.id(forWorktree: worktreeRowID) == WorktreeID(raw: worktreeRowID.uuidString))
    }
}

/// Mutable holder so a test can swap the provider's snapshots between
/// `reevaluate` calls.
private final class SnapshotBox: @unchecked Sendable {
    private var stored: [WorktreeSnapshot] = []
    func set(_ snapshots: [WorktreeSnapshot]) {
        stored = snapshots
    }

    var snapshots: [WorktreeSnapshot] {
        stored
    }
}
