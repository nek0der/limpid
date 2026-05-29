// ConflictDetectorL1Tests.swift
// Limpid — L1 detection coverage (spec §5 / §11). Exercises the pure
// `detect` algorithm (aggregation, multi-party, independent conflicts,
// dedup, single-worktree no-op) plus the @Observable wrapper's
// ignore/unignore and reevaluate-via-provider.

import Foundation
import Testing
@testable import Limpid

@Suite("ConflictDetector L1")
struct ConflictDetectorL1Tests {

    // MARK: - Builders

    private func worktree(_ id: String, branch: String) -> WatchedWorktree {
        WatchedWorktree(
            id: WorktreeID(raw: id),
            rootURL: URL(fileURLWithPath: "/tmp/\(id)"),
            projectID: ProjectID(raw: "p"),
            branch: branch,
            isPrimary: false,
            writerTabID: nil
        )
    }

    private func snapshot(_ id: String, branch: String, paths: Set<String>, at: Date) -> WorktreeSnapshot {
        let touched = Dictionary(uniqueKeysWithValues: paths.map { ($0, at) })
        return WorktreeSnapshot(
            worktree: worktree(id, branch: branch),
            changeSet: ChangeSet(
                workTreeID: WorktreeID(raw: id),
                changedPaths: paths,
                lastTouched: touched,
                capturedAt: at
            )
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var config: DetectorConfig {
        DetectorConfig()
    }

    // MARK: - Aggregation

    @Test("30 shared files between two worktrees → one conflict, 30 paths")
    func detect_thirtyOverlaps_aggregatesToOneConflict() {
        let paths = Set((0..<30).map { "src/file\($0).swift" })
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", branch: "rate-limit", paths: paths, at: t0),
                snapshot("B", branch: "payment", paths: paths, at: t0)
            ],
            existing: [],
            now: t0,
            config: config
        )
        #expect(conflicts.count == 1)
        #expect(conflicts[0].paths.count == 30)
        #expect(conflicts[0].parties.count == 2)
        // L1 → every file is potential, nothing confirmed yet.
        #expect(conflicts[0].topLevel == .potential)
        #expect(conflicts[0].confirmedCount == 0)
    }

    @Test("three worktrees on one file → a single 3-party conflict")
    func detect_threeWayOverlap_isOneConflictWithThreeParties() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["core/auth.ts"], at: t0),
                snapshot("B", branch: "b", paths: ["core/auth.ts"], at: t0),
                snapshot("C", branch: "c", paths: ["core/auth.ts"], at: t0)
            ],
            existing: [], now: t0, config: config
        )
        #expect(conflicts.count == 1)
        #expect(conflicts[0].parties.count == 3)
    }

    @Test("A↔B and C↔D overlap independently → two separate conflicts")
    func detect_independentOverlaps_areDistinctConflicts() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["x.swift"], at: t0),
                snapshot("B", branch: "b", paths: ["x.swift"], at: t0),
                snapshot("C", branch: "c", paths: ["y.swift"], at: t0),
                snapshot("D", branch: "d", paths: ["y.swift"], at: t0)
            ],
            existing: [], now: t0, config: config
        )
        #expect(conflicts.count == 2)
        #expect(conflicts.allSatisfy { $0.parties.count == 2 })
    }

    @Test("different party sets on different files → different conflicts")
    func detect_distinctPartySets_doNotMerge() {
        // file1 touched by {A,B}; file2 by {A,B,C}. Distinct sets.
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["f1", "f2"], at: t0),
                snapshot("B", branch: "b", paths: ["f1", "f2"], at: t0),
                snapshot("C", branch: "c", paths: ["f2"], at: t0)
            ],
            existing: [], now: t0, config: config
        )
        #expect(conflicts.count == 2)
        #expect(Set(conflicts.map(\.parties.count)) == [2, 3])
    }

    @Test("a file touched by a single worktree is not a conflict")
    func detect_singleWorktree_noConflict() {
        let conflicts = ConflictDetector.detect(
            [snapshot("A", branch: "a", paths: ["solo.swift", "alone.swift"], at: t0)],
            existing: [], now: t0, config: config
        )
        #expect(conflicts.isEmpty)
    }

    @Test("non-overlapping worktrees produce no conflict")
    func detect_noOverlap_noConflict() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["a.swift"], at: t0),
                snapshot("B", branch: "b", paths: ["b.swift"], at: t0)
            ],
            existing: [], now: t0, config: config
        )
        #expect(conflicts.isEmpty)
    }

    // MARK: - Dedup / id stability

    @Test("re-detecting the same overlap keeps one conflict with a stable id")
    func detect_redetection_isStable() {
        let first = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["x.swift"], at: t0),
                snapshot("B", branch: "b", paths: ["x.swift"], at: t0)
            ],
            existing: [], now: t0, config: config
        )
        let second = ConflictDetector.detect(
            [
                snapshot("A", branch: "a", paths: ["x.swift"], at: t0),
                snapshot("B", branch: "b", paths: ["x.swift"], at: t0)
            ],
            existing: first, now: t0.addingTimeInterval(60), config: config
        )
        #expect(second.count == 1)
        #expect(second[0].id == first[0].id)
        // detectedAt carried forward from the first detection.
        #expect(second[0].detectedAt == first[0].detectedAt)
    }

    @Test("conflict id is independent of file count and party order")
    func conflictID_dependsOnlyOnMemberSet() {
        let ab = ConflictID(members: [WorktreeID(raw: "A"), WorktreeID(raw: "B")])
        let ba = ConflictID(members: [WorktreeID(raw: "B"), WorktreeID(raw: "A")])
        #expect(ab == ba)
    }

    // MARK: - Ignore (pair-level, survives new files)

    @MainActor
    @Test("ignore is pair-level and persists as new files join the overlap")
    func ignore_persistsAcrossNewFiles() async throws {
        let provider = SnapshotBox()
        provider.set([
            snapshot("A", branch: "a", paths: ["x.swift"], at: t0),
            snapshot("B", branch: "b", paths: ["x.swift"], at: t0)
        ])
        let detector = ConflictDetector(now: { self.t0 }, snapshotProvider: { provider.snapshots })

        await detector.reevaluate()
        let id = try #require(detector.conflicts.first?.id)
        detector.ignore(id)
        #expect(detector.conflicts.first?.status == .ignored)

        // A new file joins the same pair; ignore must stick and the new
        // file must be included.
        provider.set([
            snapshot("A", branch: "a", paths: ["x.swift", "y.swift"], at: t0),
            snapshot("B", branch: "b", paths: ["x.swift", "y.swift"], at: t0)
        ])
        await detector.reevaluate()
        #expect(detector.conflicts.count == 1)
        #expect(detector.conflicts.first?.status == .ignored)
        #expect(detector.conflicts.first?.fileCount == 2)
    }

    @MainActor
    @Test("unignore returns the conflict to active")
    func unignore_returnsToActive() async throws {
        let provider = SnapshotBox()
        provider.set([
            snapshot("A", branch: "a", paths: ["x.swift"], at: t0),
            snapshot("B", branch: "b", paths: ["x.swift"], at: t0)
        ])
        let detector = ConflictDetector(now: { self.t0 }, snapshotProvider: { provider.snapshots })
        await detector.reevaluate()
        let id = try #require(detector.conflicts.first?.id)
        detector.ignore(id)
        detector.unignore(id)
        #expect(detector.conflicts.first?.status == .active)
    }
}

/// Tiny mutable holder so a test can swap the snapshots the detector's
/// provider returns between `reevaluate` calls.
private final class SnapshotBox: @unchecked Sendable {
    private var stored: [WorktreeSnapshot] = []
    func set(_ snapshots: [WorktreeSnapshot]) {
        stored = snapshots
    }

    var snapshots: [WorktreeSnapshot] {
        stored
    }
}
