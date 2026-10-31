// ApprovalPresentationStore+Projection.swift
// Weir — broker projections handed to a store the way the service's arrive.

import Foundation
import Testing
@testable import Weir

extension ApprovalControllerConnection.Projection {
    /// A projection listing `pending`, with how the tracked requests that
    /// left ended (`terminals`), the ones the broker no longer has
    /// (`missing`), and the service clock's reading (`deadlines`).
    static func test(
        pending: [ApprovalPresentation],
        terminals: [String: BrokerTerminal] = [:],
        missing: Set<String> = [],
        deadlines: [String: ServiceDeadline] = [:]
    ) -> Self {
        Self(
            sequence: 1,
            requests: pending,
            terminals: terminals,
            missingIDs: missing,
            unevictableCount: pending.count,
            deadlines: deadlines
        )
    }
}

extension ApprovalPresentationStore {
    /// Applies a projection listing `pending` in `epoch`, as the service's
    /// arrive (`apply`): the ledger takes each request before the pending
    /// list does, so a test never sees a request pending that the ledger
    /// does not hold. `epoch` defaults to the first request's; an empty
    /// list names its own.
    func receive(
        _ pending: [ApprovalPresentation],
        epoch: UUID? = nil,
        terminals: [String: BrokerTerminal] = [:],
        missing: Set<String> = [],
        seenAt: Date = Date(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let epoch = epoch ?? pending.first?.epoch else {
            Issue.record("An empty projection names its epoch", sourceLocation: sourceLocation)
            return
        }
        apply(
            .test(pending: pending, terminals: terminals, missing: missing),
            epoch: epoch,
            now: SuspendingClock.now,
            seenAt: seenAt
        )
    }
}
