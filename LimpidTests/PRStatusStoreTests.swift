// PRStatusStoreTests.swift
// Limpid — Swift Testing coverage for `PRStatusStore`. The store does
// very little, but three invariants matter for the rest of the graph:
//   1. Every mutation is idempotent at the dictionary level — writing
//      what is already there, or removing what is not, must not
//      notify. The syncer leans on this to keep Observation churn out
//      of the sidebar on every tick, and the guards are invisible in
//      the resulting state, so only the notification distinguishes a
//      working one from a missing one.
//   2. `update` with `nil` removes a previously-present entry. The
//      syncer writes nil when the CLI stops reporting a request for a
//      row that had one — the request was deleted, or the CLI lost its
//      credentials. A merged or closed request does not go down this
//      path; those still decode into a state we render.
//   3. `prune` forgets rows that have left the sidebar. Beyond
//      bounding growth, a stranded entry is still read by the syncer's
//      cadence check.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("PRStatusStore")
struct PRStatusStoreTests {

    @Test("update with a new info populates the map")
    func update_freshInsert_populatesMap() {
        let store = PRStatusStore()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let info = PRInfoFixture.make(number: 1, state: .open)
        store.update(container: id, info: info)
        #expect(store.info(for: id) == info)
    }

    /// The early return in `update` exists to stop Observation from
    /// firing when a refetch returns what we already had — the common
    /// case on every tick. Comparing the dictionary afterwards cannot
    /// detect a regression, because a redundant write stores a
    /// value-equal result and compares equal either way. Only
    /// observing the notification proves the guard is doing its job.
    @Test("re-writing the same value does not notify observers")
    func update_sameValue_doesNotNotifyObservers() {
        let store = PRStatusStore()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let info = PRInfoFixture.make(number: 1, state: .open)
        store.update(container: id, info: info)

        let notified = NotificationFlag()
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.fire()
        }
        store.update(container: id, info: info)
        #expect(!notified.didFire)

        // Control: a genuinely different value must still notify, so
        // the assertion above cannot pass by the tracking being dead.
        store.update(container: id, info: PRInfoFixture.make(number: 2, state: .open))
        #expect(notified.didFire)
    }

    /// Same reasoning for `clear`, whose guard is the one that keeps a
    /// disabled feature from waking every sidebar row on each toggle.
    @Test("clearing an already-empty store does not notify observers")
    func clear_whenEmpty_doesNotNotifyObservers() {
        let store = PRStatusStore()
        let notified = NotificationFlag()
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.fire()
        }
        store.clear()
        #expect(!notified.didFire)

        // Control: the tracking is live, so the assertion above is not
        // passing by the observer never having been registered.
        store.update(container: .project(UUID()), info: PRInfoFixture.make(number: 1, state: .open))
        #expect(notified.didFire)
    }

    @Test("update replaces an existing entry when the value differs")
    func update_changedValue_replaces() {
        let store = PRStatusStore()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        store.update(container: id, info: PRInfoFixture.make(number: 1, state: .open))
        let merged = PRInfoFixture.make(number: 1, state: .merged)
        store.update(container: id, info: merged)
        #expect(store.info(for: id)?.state == .merged)
    }

    @Test("update with nil removes a present entry")
    func update_nilOnPresent_removes() {
        let store = PRStatusStore()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        store.update(container: id, info: PRInfoFixture.make(number: 1, state: .open))
        store.update(container: id, info: nil)
        #expect(store.info(for: id) == nil)
    }

    /// What this pins is the `perContainer[container] != nil` guard in
    /// the nil branch. Asserting on the map afterwards cannot: a
    /// dictionary cannot hold nil, so an unguarded `removeValue` leaves
    /// it equally empty and every implementation passes. Only the
    /// notification separates the two — and without the guard the
    /// syncer would wake every sidebar row once per tick for each
    /// container that has no request, which is most of them.
    @Test("removing an absent key does not notify observers")
    func update_nilOnAbsent_doesNotNotifyObservers() {
        let store = PRStatusStore()
        let id = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let notified = NotificationFlag()
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.fire()
        }
        store.update(container: id, info: nil)
        #expect(!notified.didFire)
        #expect(store.perContainer.isEmpty)

        // Control, as in the tests above.
        store.update(container: id, info: PRInfoFixture.make(number: 1, state: .open))
        #expect(notified.didFire)
    }

    @Test("clear drops every entry")
    func clear_resetsMap() {
        let store = PRStatusStore()
        store.update(container: .project(UUID()), info: PRInfoFixture.make(number: 1, state: .open))
        store.update(
            container: .worktree(projectID: UUID(), worktreeID: UUID()),
            info: PRInfoFixture.make(number: 2, state: .merged)
        )
        store.clear()
        #expect(store.perContainer.isEmpty)
    }

    @Test("prune keeps the live containers and drops the rest")
    func prune_dropsContainersOutsideTheLiveSet() {
        let store = PRStatusStore()
        let live = ContainerID.project(UUID())
        let gone = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        store.update(container: live, info: PRInfoFixture.make(number: 1, state: .open))
        store.update(container: gone, info: PRInfoFixture.make(number: 2, state: .open))
        store.prune(keeping: [live])
        #expect(store.info(for: live) != nil)
        #expect(store.info(for: gone) == nil)
    }

    /// A hidden worktree whose last known state had checks running
    /// would otherwise hold `PRStatusSyncer.currentInterval` at the
    /// active cadence for the rest of the session — the reason pruning
    /// the store exists at all, beyond bounding its growth.
    @Test("prune removes an entry whose checks were still pending")
    func prune_dropsPendingEntry() {
        let store = PRStatusStore()
        let gone = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        store.update(
            container: gone,
            info: PRInfoFixture.make(number: 1, state: .open, checks: .pending)
        )
        store.prune(keeping: [])
        #expect(store.perContainer.isEmpty)
    }

    @Test("pruning against an unchanged live set does not notify observers")
    func prune_noStaleEntries_doesNotNotifyObservers() {
        let store = PRStatusStore()
        let live = ContainerID.project(UUID())
        store.update(container: live, info: PRInfoFixture.make(number: 1, state: .open))

        let notified = NotificationFlag()
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.fire()
        }
        store.prune(keeping: [live])
        #expect(!notified.didFire)

        // Control, as in the tests above.
        store.prune(keeping: [])
        #expect(notified.didFire)
    }

}

/// Records whether an Observation change fired. `withObservationTracking`
/// hands its callback to an arbitrary context, so the flag needs to be a
/// reference the closure can mutate rather than a captured local.
private final class NotificationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
