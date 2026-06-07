// LifecycleTests.swift
// Limpid — guards for `observeRepeatedly`'s `[weak self]` contract.
// Every coordinator that subscribes to a `WindowSession` mutation
// stream relies on the recursive observation chain *not* preventing
// the owner from deiniting; a strong capture there would leak the
// owner past its intended lifetime and the on-mutation `Task` would
// keep doing real work against a logically-dead object.
//
// The companion `SurfaceView` lifecycle test (observer install /
// teardown + deinit with nil `ghosttyApp`) needs a real libghostty
// app + an `NSWindow` to land non-trivially; it lives with the
// integration suite planned in Phase 3 of the architecture roadmap.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct LifecycleTests {

    // MARK: - observeRepeatedly owner deinit

    /// Observer harness: subscribes to `session.activeTabID` via
    /// `observeRepeatedly`. Both closures `[weak self]`-capture so a
    /// release of the owner must let it deinit even though the
    /// observation chain re-arms itself on every mutation.
    @MainActor
    private final class TestObserver {
        let session: WindowSession
        var fireCount: Int = 0

        init(session: WindowSession) {
            self.session = session
        }

        func start() {
            observeRepeatedly { [weak self] in
                _ = self?.session.activeTabID
            } onChange: { [weak self] in
                self?.fireCount += 1
            }
        }
    }

    @Test func observeRepeatedly_allowsOwnerDeinit_whenObservableOutlivesIt() async {
        let session = WindowSession()

        weak var weakObserver: TestObserver?
        do {
            let observer = TestObserver(session: session)
            weakObserver = observer
            observer.start()
            // Fire one mutation so the chain re-arms at least once
            // — confirms the [weak self] captures take effect rather
            // than the test ending before any observation work runs.
            session.setActiveTab(nil)
            // Drain pending @MainActor Tasks so the next-round
            // observeRepeatedly call (which captures the closures
            // again) has a chance to land before the observer drops
            // out of scope.
            await Task.yield()
        }

        // Give any in-flight observation Task a chance to release
        // its captures before we check the weak ref.
        await Task.yield()
        await Task.yield()

        #expect(weakObserver == nil, "observeRepeatedly's chain must not strong-capture the owner")
    }

}
