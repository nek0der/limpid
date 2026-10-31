// ApprovalControllerConnectionTests.swift
// Weir — what the app reads out of the broker's replies: the pending list,
// how tracked requests ended, the service clock, and a refused decision.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalControllerConnectionTests {
    private static let now = SuspendingClock.now

    /// One row of the broker's snapshot index for `approval`.
    private static func index(
        _ approval: ApprovalPresentation,
        status: String = "pending",
        deadline: UInt64 = 600_000
    ) -> [String: Any] {
        [
            "run_id": approval.runID.uuidString,
            "request_id": approval.requestID.uuidString,
            "provider": "claude",
            "status": status,
            "deadline_ms": NSNumber(value: deadline),
            "sequence": NSNumber(value: 1)
        ]
    }

    /// The broker's reply to a lookup of one request, in `state`.
    private static func detail(_ state: [String: Any]) -> [String: Any] {
        [
            "type": "approval.result",
            "body": [
                "request": [
                    "provider": "claude",
                    "tool_name": "Bash",
                    "input": ["command": "make test"]
                ],
                "state": state,
                "created_at_ms": NSNumber(value: 0),
                "deadline_ms": NSNumber(value: 600_000),
                "sequence": NSNumber(value: 1)
            ]
        ]
    }

    private static func error(_ code: String) -> [String: Any] {
        ["type": "error", "body": ["code": code, "message": "refused"]]
    }

    // MARK: - The projection

    @Test func aProjection_readsPendingAndLooksUpOnlyTrackedEndings() throws {
        let epoch = UUID()
        let pending = ApprovalPresentation.test(epoch: epoch)
        let tracked = ApprovalPresentation.test(epoch: epoch)
        let untracked = ApprovalPresentation.test(epoch: epoch)
        let evicted = ApprovalPresentation.test(epoch: epoch)
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": [
                "sequence": NSNumber(value: 7),
                "requests": [
                    Self.index(pending, status: "pending"),
                    Self.index(tracked, status: "resolved"),
                    Self.index(untracked, status: "expired")
                ]
            ]
        ]
        var fetched: [UUID] = []

        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: epoch,
            receivedAt: Self.now,
            trackedIDs: [tracked.id, evicted.id]
        ) { _, requestID in
            fetched.append(requestID)
            if requestID == pending.requestID {
                return Self.detail(["status": "pending"])
            }
            return Self.detail(["status": "resolved", "result": ["decision": "delegate"]])
        }

        #expect(projection.sequence == 7)
        #expect(projection.requests.map(\.id) == [pending.id])
        #expect(projection.terminals == [tracked.id: .resolved(.delegate)])
        #expect(projection.missingIDs == [evicted.id])
        // No split reported: every record counts.
        #expect(projection.unevictableCount == 3)
        #expect(Set(fetched) == [pending.requestID, tracked.requestID])
    }

    @Test func aLookupThatFindsNothing_countsAsMissing() throws {
        let epoch = UUID()
        let tracked = ApprovalPresentation.test(epoch: epoch)
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": ["sequence": NSNumber(value: 1), "requests": [Self.index(tracked, status: "canceled")]]
        ]

        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: epoch,
            receivedAt: Self.now,
            trackedIDs: [tracked.id]
        ) { _, _ in
            Self.error("not_found")
        }

        #expect(projection.missingIDs == [tracked.id])
        #expect(projection.terminals.isEmpty)
    }

    @Test func aReportedSplit_isWhatCapacityCounts() throws {
        let response: [String: Any] = [
            "type": "approval.snapshot.result",
            "body": ["sequence": NSNumber(value: 1), "requests": [], "unevictable_records": NSNumber(value: 40)]
        ]
        let projection = try ApprovalControllerConnection.projection(
            from: response,
            epoch: UUID(),
            receivedAt: Self.now,
            trackedIDs: []
        ) { _, _ in [:] }
        #expect(projection.unevictableCount == 40)
    }

    @Test func brokerStates_mapToEndings() {
        func ending(_ state: [String: Any]) -> BrokerTerminal? {
            ApprovalControllerConnection.brokerTerminal(fromDetail: ["type": "approval.result", "body": ["state": state]])
        }
        #expect(ending(["status": "resolved", "result": ["decision": "allow_once"]]) == .resolved(.allowOnce))
        #expect(ending(["status": "resolved", "result": ["decision": "deny", "message": "no"]]) == .resolved(.deny))
        #expect(ending(["status": "resolved", "result": ["decision": "answer", "answers": ["Q": "A"]]])
            == .resolved(.answer(["Q": "A"])))
        #expect(ending(["status": "canceled"]) == .canceled)
        #expect(ending(["status": "expired"]) == .expired)
        #expect(ending(["status": "pending"]) == nil)
        #expect(ending(["status": "resolved", "result": ["decision": "answer", "answers": "garbled"]]) == nil)
        #expect(ending(["status": "resolved", "result": ["decision": "allow_always"]]) == nil)
    }

    @Test func decode_questions_readsSnapshotShape() {
        let decoded = ApprovalQuestion.decode([
            [
                "header": "Color",
                "prompt": "Which color?",
                "multi_select": true,
                "options": [["label": "Red", "description": "warm"], ["label": "Blue"]]
            ],
            ["prompt": "Which size?"]
        ])
        #expect(decoded.count == 2)
        #expect(decoded[0].isMultiSelect)
        #expect(decoded[0].options[1].description == nil)
        #expect(decoded[1].options.isEmpty)
        #expect(ApprovalQuestion.decode(nil).isEmpty)
    }

    @Test func presentationID_matchesTheKeyReadFromTheIndex() {
        let approval = ApprovalPresentation.test(epoch: UUID())
        #expect(approval.id == ApprovalPresentation.id(
            epoch: approval.epoch,
            runID: approval.runID,
            requestID: approval.requestID
        ))
    }

    // MARK: - The service clock

    @Test func snapshotBody_givesEachPendingRequestItsTimeLeft() {
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let answered = ApprovalPresentation.test(epoch: epoch)
        let body: [String: Any] = [
            "sequence": NSNumber(value: 4),
            "now_ms": NSNumber(value: 30000),
            "requests": [Self.index(held), Self.index(answered, status: "resolved")]
        ]

        let deadlines = ApprovalControllerConnection.serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: Self.now)

        #expect(deadlines.keys.sorted() == [held.id])
        #expect(deadlines[held.id]?.remaining(at: Self.now) == .seconds(570))
    }

    @Test func aBodyWithoutTheServiceClock_givesNoDeadlines() {
        let epoch = UUID()
        let body: [String: Any] = [
            "sequence": NSNumber(value: 1),
            "requests": [Self.index(ApprovalPresentation.test(epoch: epoch))]
        ]

        let deadlines = ApprovalControllerConnection.serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: Self.now)

        #expect(deadlines.isEmpty)
    }

    // MARK: - A refused decision

    @Test func alreadyTerminal_asksTheBrokerHowItEnded() throws {
        var fetches = 0
        let refusal = try ApprovalControllerConnection.refusal(of: Self.error("already_terminal")) {
            fetches += 1
            return Self.detail(["status": "resolved", "result": ["decision": "delegate"]])
        }

        #expect(refusal == .alreadySettled(.resolved(.delegate)))
        #expect(fetches == 1)
    }

    /// A record the broker no longer has is missing whether the refusal says
    /// so itself, which needs no lookup, or the lookup after it does.
    @Test(arguments: [("not_found", 0), ("already_terminal", 1)])
    func notFound_isAMissingRecord(code: String, expectedFetches: Int) throws {
        var fetches = 0
        let refusal = try ApprovalControllerConnection.refusal(of: Self.error(code)) {
            fetches += 1
            return Self.error("not_found")
        }

        #expect(refusal == .recordMissing)
        #expect(fetches == expectedFetches)
    }

    /// A lookup that says the request is still pending contradicts the
    /// refusal, and any other code is no settlement at all: both leave the
    /// decision to be tried again.
    @Test(arguments: ["already_terminal", "epoch_mismatch"])
    func anUnsettledRefusal_isAFailureToRetry(code: String) {
        #expect(throws: AgentIntegrationError.self) {
            try ApprovalControllerConnection.refusal(of: Self.error(code)) {
                Self.detail(["status": "pending"])
            }
        }
    }

    @Test func aLookupThatFails_passesItsErrorOn() {
        struct LookupFailed: Error {}
        #expect(throws: LookupFailed.self) {
            try ApprovalControllerConnection.refusal(of: Self.error("already_terminal")) {
                throw LookupFailed()
            }
        }
    }
}
