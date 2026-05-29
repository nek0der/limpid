// ConflictDetectorHysteresisTests.swift
// Limpid — staleness filter + grace-period hysteresis (spec §5 steps
// 2 & 7, checklist §10-5). All deterministic via injected `now` on the
// pure `detect`.

import Foundation
import Testing
@testable import Limpid

@Suite("ConflictDetector staleness + hysteresis")
struct ConflictDetectorHysteresisTests {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// A worktree touching `paths`, each at time `at`.
    private func snapshot(_ id: String, paths: Set<String>, at: Date) -> WorktreeSnapshot {
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

    private func config(staleness: TimeInterval = 600, grace: TimeInterval = 12) -> DetectorConfig {
        var c = DetectorConfig()
        c.stalenessWindow = staleness
        c.gracePeriod = grace
        return c
    }

    // MARK: - Staleness filter

    @Test("a stale touch is excluded, so the overlap is not a conflict")
    func staleness_oldTouchDropsTheOverlap() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", paths: ["x.swift"], at: t0.addingTimeInterval(-700)), // stale (>600)
                snapshot("B", paths: ["x.swift"], at: t0) // fresh
            ],
            existing: [], now: t0, config: config(staleness: 600)
        )
        // Only B is fresh on x.swift → single party → no conflict.
        #expect(conflicts.isEmpty)
    }

    @Test("two fresh touches still conflict")
    func staleness_bothFresh_conflict() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", paths: ["x.swift"], at: t0.addingTimeInterval(-100)),
                snapshot("B", paths: ["x.swift"], at: t0)
            ],
            existing: [], now: t0, config: config(staleness: 600)
        )
        #expect(conflicts.count == 1)
    }

    @Test("a touch exactly at the staleness floor is kept (>= boundary)")
    func staleness_boundaryInclusive() {
        let conflicts = ConflictDetector.detect(
            [
                snapshot("A", paths: ["x.swift"], at: t0.addingTimeInterval(-600)), // exactly at floor
                snapshot("B", paths: ["x.swift"], at: t0)
            ],
            existing: [], now: t0, config: config(staleness: 600)
        )
        #expect(conflicts.count == 1)
    }

    // MARK: - Hysteresis

    private func overlap(at: Date) -> [WorktreeSnapshot] {
        [snapshot("A", paths: ["x.swift"], at: at), snapshot("B", paths: ["x.swift"], at: at)]
    }

    @Test("a vanished active conflict enters grace as .resolving, not removed")
    func hysteresis_vanished_becomesResolving() {
        let active = ConflictDetector.detect(overlap(at: t0), existing: [], now: t0, config: config())
        #expect(active.first?.status == .active)

        // Overlap gone (e.g. one side committed). Within grace it must
        // stay, as .resolving.
        let resolving = ConflictDetector.detect([], existing: active, now: t0.addingTimeInterval(5), config: config(grace: 12))
        #expect(resolving.count == 1)
        if case .resolving = resolving.first?.status {} else {
            Issue.record("expected .resolving, got \(String(describing: resolving.first?.status))")
        }
    }

    @Test("a resolving conflict past the grace period is dropped")
    func hysteresis_pastGrace_resolvedAndDropped() {
        let active = ConflictDetector.detect(overlap(at: t0), existing: [], now: t0, config: config())
        let resolving = ConflictDetector.detect([], existing: active, now: t0.addingTimeInterval(5), config: config(grace: 12))
        // 5s into grace at the resolving snapshot; now jump well past it.
        let resolved = ConflictDetector.detect([], existing: resolving, now: t0.addingTimeInterval(30), config: config(grace: 12))
        #expect(resolved.isEmpty)
    }

    @Test("re-detection within grace snaps back to active without flicker")
    func hysteresis_redetectedWithinGrace_returnsToActive() throws {
        let active = ConflictDetector.detect(overlap(at: t0), existing: [], now: t0, config: config())
        let id = try #require(active.first?.id)
        let detectedAt = try #require(active.first?.detectedAt)

        let resolving = ConflictDetector.detect([], existing: active, now: t0.addingTimeInterval(5), config: config(grace: 12))
        // Saved again before grace elapses → overlap returns.
        let back = ConflictDetector.detect(
            overlap(at: t0.addingTimeInterval(8)),
            existing: resolving,
            now: t0.addingTimeInterval(8),
            config: config(grace: 12)
        )

        #expect(back.count == 1)
        #expect(back.first?.status == .active)
        #expect(back.first?.id == id)
        // Same conflict throughout — detectedAt preserved (no new id, no
        // flicker).
        #expect(back.first?.detectedAt == detectedAt)
    }

    @Test("a vanished ignored conflict is dropped (no flicker to absorb)")
    func hysteresis_ignoredVanished_dropped() {
        var active = ConflictDetector.detect(overlap(at: t0), existing: [], now: t0, config: config())
        active[0].status = .ignored
        let after = ConflictDetector.detect([], existing: active, now: t0.addingTimeInterval(1), config: config())
        #expect(after.isEmpty)
    }
}
