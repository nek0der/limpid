// CwdEventTrackerTests.swift
// Limpid — pins the cwd event tracker's dispatch rules before the projection
// takes them over. The tracker shipped without tests, so these describe what it
// does today rather than what it should do; the Rust port is checked against
// them.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("CwdEventTracker")
struct CwdEventTrackerTests {
    private func record(
        pane: UUID,
        newCwd: String = "/tmp/after",
        oldCwd: String? = "/tmp/before",
        updatedAt: String
    ) -> CwdEventRecord {
        CwdEventRecord(
            schemaVersion: 1,
            paneId: pane.uuidString,
            newCwd: newCwd,
            oldCwd: oldCwd,
            updatedAt: updatedAt
        )
    }

    @Test("bootstrap snapshots existing records without dispatching them")
    func bootstrap_snapshotsWithoutDispatching() throws {
        try withTempDir { dir in
            let store = CwdEventStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:00:00Z"))

            var dispatched: [CwdEventRecord] = []
            let tracker = CwdEventTracker(store: store)
            tracker.bootstrap(into: session) { dispatched.append($0) }

            #expect(dispatched.isEmpty)

            // The snapshot is what suppresses it: a scan over the same record
            // stays silent, so a stale event from a prior launch never fires.
            tracker.scanAndDispatch()
            #expect(dispatched.isEmpty)
        }
    }

    @Test("a record with a new timestamp dispatches exactly once")
    func freshRecord_dispatchesOnce() throws {
        try withTempDir { dir in
            let store = CwdEventStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()

            var dispatched: [CwdEventRecord] = []
            let tracker = CwdEventTracker(store: store)
            tracker.bootstrap(into: session) { dispatched.append($0) }

            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:01:00Z"))
            tracker.scanAndDispatch()
            #expect(dispatched.count == 1)
            #expect(dispatched.first?.newCwd == "/tmp/after")

            // Freshness is the timestamp, not the file: rescanning the same
            // record is a no-op even though the file is still there.
            tracker.scanAndDispatch()
            #expect(dispatched.count == 1)

            try store.save(record(pane: paneID, newCwd: "/tmp/later", updatedAt: "2026-09-14T12:02:00Z"))
            tracker.scanAndDispatch()
            #expect(dispatched.count == 2)
            #expect(dispatched.last?.newCwd == "/tmp/later")
        }
    }

    @Test("an event for a pane that is gone is marked seen but not dispatched")
    func recordForDeadPane_isSeenButNotDispatched() throws {
        try withTempDir { dir in
            let store = CwdEventStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let absent = UUID()

            var dispatched: [CwdEventRecord] = []
            let tracker = CwdEventTracker(store: store)
            tracker.bootstrap(into: session) { dispatched.append($0) }

            try store.save(record(pane: absent, updatedAt: "2026-09-14T12:01:00Z"))
            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:01:00Z"))
            tracker.scanAndDispatch()

            // Only the live pane's move is worth suggesting; the other pane's
            // event is moot because there is nothing left to move.
            #expect(dispatched.count == 1)
            #expect(dispatched.first?.paneId == paneID.uuidString)
            #expect(store.record(forPaneID: absent) == nil)
        }
    }

    @Test("a scan drops the files of panes that are no longer alive")
    func scan_cleansUpRecordsForClosedPanes() throws {
        try withTempDir { dir in
            let store = CwdEventStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            let closed = UUID()
            try store.save(record(pane: closed, updatedAt: "2026-09-14T12:00:00Z"))
            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:00:00Z"))

            let tracker = CwdEventTracker(store: store)
            tracker.bootstrap(into: session) { _ in }
            tracker.scanAndDispatch()

            #expect(store.record(forPaneID: closed) == nil)
            #expect(store.record(forPaneID: paneID) != nil)
        }
    }

    @Test("didClosePane forgets the pane so a reused id starts clean")
    func didClosePane_forgetsAndDeletes() throws {
        try withTempDir { dir in
            let store = CwdEventStore(directory: dir)
            let (session, _, paneID) = WindowSessionFixture.withLooseTab()
            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:00:00Z"))

            var dispatched: [CwdEventRecord] = []
            let tracker = CwdEventTracker(store: store)
            tracker.bootstrap(into: session) { dispatched.append($0) }
            tracker.didClosePane(paneID)
            #expect(store.record(forPaneID: paneID) == nil)

            // A restore can hand the same id to a new pane. Because the closed
            // pane's timestamp was forgotten, the first event on the reused id
            // is fresh again.
            try store.save(record(pane: paneID, updatedAt: "2026-09-14T12:00:00Z"))
            tracker.scanAndDispatch()
            #expect(dispatched.count == 1)
        }
    }
}
