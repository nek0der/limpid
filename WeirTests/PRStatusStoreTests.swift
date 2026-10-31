// PRStatusStoreTests.swift
// Weir — Swift Testing coverage for `PRStatusStore`. The store does
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
@testable import Weir

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

        let notified = Recorded(false)
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.value = true
        }
        store.update(container: id, info: info)
        #expect(!notified.value)

        // Control: a genuinely different value must still notify, so
        // the assertion above cannot pass by the tracking being dead.
        store.update(container: id, info: PRInfoFixture.make(number: 2, state: .open))
        #expect(notified.value)
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
        let notified = Recorded(false)
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.value = true
        }
        store.update(container: id, info: nil)
        #expect(!notified.value)
        #expect(store.perContainer.isEmpty)

        // Control, as in the tests above.
        store.update(container: id, info: PRInfoFixture.make(number: 1, state: .open))
        #expect(notified.value)
    }

    /// A hidden worktree whose last known state had checks running
    /// would otherwise hold `PRStatusSyncer.currentInterval` at the
    /// active cadence for the rest of the session — the reason pruning
    /// the store exists at all, beyond bounding its growth.
    @Test("prune keeps the live containers and drops the rest")
    func prune_dropsContainersOutsideTheLiveSet() {
        let store = PRStatusStore()
        let live = ContainerID.project(UUID())
        let gone = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        store.update(container: live, info: PRInfoFixture.make(number: 1, state: .open))
        store.update(container: gone, info: PRInfoFixture.make(number: 2, state: .open, checks: .pending))
        store.prune(keeping: [live])
        #expect(store.info(for: live) != nil)
        #expect(store.info(for: gone) == nil)
    }

    @Test("pruning against an unchanged live set does not notify observers")
    func prune_noStaleEntries_doesNotNotifyObservers() {
        let store = PRStatusStore()
        let live = ContainerID.project(UUID())
        store.update(container: live, info: PRInfoFixture.make(number: 1, state: .open))

        let notified = Recorded(false)
        withObservationTracking {
            _ = store.perContainer
        } onChange: {
            notified.value = true
        }
        store.prune(keeping: [live])
        #expect(!notified.value)

        // Control, as in the tests above.
        store.prune(keeping: [])
        #expect(notified.value)
    }

    @Test("the forge a lookup found stays until its row goes")
    func forge_isKeptUntilPruned() {
        let store = PRStatusStore()
        let kept = ContainerID.project(UUID())
        let gone = ContainerID.project(UUID())
        store.update(container: kept, info: nil, forge: .gitHub)
        store.update(container: gone, info: nil, forge: .gitLab)
        #expect(store.forge(for: kept) == .gitHub)
        store.prune(keeping: [kept])
        #expect(store.forge(for: gone) == nil)
        store.update(container: kept, info: nil, forge: nil)
        #expect(store.forge(for: kept) == nil)
    }
}
