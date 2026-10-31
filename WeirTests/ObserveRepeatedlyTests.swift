// ObserveRepeatedlyTests.swift
// Weir — `observeRepeatedly` re-arms on every change and still lets its owner go: an owner that subscribes to a `WorkspaceSession` change
// stream deinits when released, rather than living on with a `Task` working against it.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ObserveRepeatedlyTests {
    /// Subscribes to `session.primarySelection.activeTabID` the way the
    /// coordinators do, with both closures capturing it weakly.
    @MainActor
    private final class TestObserver {
        let session: WorkspaceSession
        var fireCount: Int = 0

        init(session: WorkspaceSession) {
            self.session = session
        }

        func start() {
            observeRepeatedly { [weak self] in
                _ = self?.session.primarySelection.activeTabID
            } onChange: { [weak self] in
                self?.fireCount += 1
            }
        }
    }

    @Test func anOwnerReleased_afterTheChainReArmed_deinits() async {
        let session = WorkspaceSession()

        weak var weakObserver: TestObserver?
        do {
            let observer = TestObserver(session: session)
            weakObserver = observer
            observer.start()
            // Two changes: the second is seen only if the first re-armed
            // the observation, so the owner is released with the chain
            // already re-armed and no change in flight.
            _ = session.openTabInActiveScope()
            await pollUntil { observer.fireCount == 1 }
            _ = session.openTabInActiveScope()
            await pollUntil { observer.fireCount == 2 }
            #expect(observer.fireCount == 2)
        }

        #expect(weakObserver == nil, "the observation chain holds its owner only weakly")
    }
}
