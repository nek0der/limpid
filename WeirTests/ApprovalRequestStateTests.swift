// ApprovalRequestStateTests.swift
// Weir — every transition of an approval or question request.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct ApprovalRequestStateTests {
    private struct Move {
        let state: ApprovalRequestState
        let event: ApprovalEvent
        let next: ApprovalRequestState

        init(_ state: ApprovalRequestState, _ event: ApprovalEvent, _ next: ApprovalRequestState) {
            self.state = state
            self.event = event
            self.next = next
        }
    }

    private static let earlier = SuspendingClock().now
    private static let now = earlier.advanced(by: .seconds(5))

    private static let sendingAllow = ApprovalRequestState.sending(.allowOnce, since: earlier)
    private static let sendingDelegate = ApprovalRequestState.sending(.delegate, since: earlier)
    private static let failed = ApprovalRequestState.sendFailed(.deny, error: "offline")
    private static let handed = ApprovalRequestState.handedToTerminal(since: earlier)

    /// At least one value of each state, and of each kind of event, for the
    /// grid to cross.
    private static let states: [ApprovalRequestState] = [
        .held, sendingAllow, sendingDelegate, failed, handed, .timedOut, .withdrawn, .unknownResult, .answered(.allowOnce)
    ]
    private static let events: [ApprovalEvent] = [
        .userDecided(.allowOnce), .userDecided(.delegate), .paneBecameVisible, .sendSucceeded, .sendFailed("offline"),
        .brokerTerminal(.resolved(.deny)), .brokerTerminal(.resolved(.answer(["q": "a"]))),
        .brokerTerminal(.resolved(.delegate)), .brokerTerminal(.canceled),
        .brokerTerminal(.expired), .brokerRecordMissing, .deadlinePassed
    ]

    /// The cases, without their values. A new case of the real enum does not
    /// compile until `kind(of:)` maps it here, and once it is listed here
    /// `grid_coversEveryCase` fails until the grid has a value for it.
    private enum StateCase: CaseIterable {
        case held, sending, handedToTerminal, timedOut, withdrawn, unknownResult, sendFailed, answered
    }

    private enum EventCase: CaseIterable {
        case userDecided, paneBecameVisible, sendSucceeded, sendFailed, brokerTerminal, brokerRecordMissing,
             deadlinePassed
    }

    private static func kind(of state: ApprovalRequestState) -> StateCase {
        switch state {
        case .held: .held
        case .sending: .sending
        case .handedToTerminal: .handedToTerminal
        case .timedOut: .timedOut
        case .withdrawn: .withdrawn
        case .unknownResult: .unknownResult
        case .sendFailed: .sendFailed
        case .answered: .answered
        }
    }

    private static func kind(of event: ApprovalEvent) -> EventCase {
        switch event {
        case .userDecided: .userDecided
        case .paneBecameVisible: .paneBecameVisible
        case .sendSucceeded: .sendSucceeded
        case .sendFailed: .sendFailed
        case .brokerTerminal: .brokerTerminal
        case .brokerRecordMissing: .brokerRecordMissing
        case .deadlinePassed: .deadlinePassed
        }
    }

    /// Held and a failed send are open: they take the same events.
    private static let openMoves: [(ApprovalEvent, ApprovalRequestState)] = [
        (.userDecided(.allowOnce), .sending(.allowOnce, since: now)),
        (.userDecided(.delegate), .sending(.delegate, since: now)),
        (.paneBecameVisible, .sending(.delegate, since: now)),
        (.brokerTerminal(.resolved(.deny)), .answered(.deny)),
        (.brokerTerminal(.resolved(.answer(["q": "a"]))), .answered(.answer(["q": "a"]))),
        (.brokerTerminal(.resolved(.delegate)), .handedToTerminal(since: now)),
        (.brokerTerminal(.canceled), .withdrawn),
        (.brokerTerminal(.expired), .timedOut),
        (.brokerRecordMissing, .unknownResult),
        (.deadlinePassed, .timedOut)
    ]

    /// A send in flight waits for its own result or the broker's word; a
    /// visible pane and our deadline do not interrupt it.
    private static let brokerMoves: [(ApprovalEvent, ApprovalRequestState)] = [
        (.brokerTerminal(.resolved(.deny)), .answered(.deny)),
        (.brokerTerminal(.resolved(.answer(["q": "a"]))), .answered(.answer(["q": "a"]))),
        (.brokerTerminal(.resolved(.delegate)), .handedToTerminal(since: now)),
        (.brokerTerminal(.canceled), .withdrawn),
        (.brokerTerminal(.expired), .timedOut),
        (.brokerRecordMissing, .unknownResult)
    ]

    private static let otherMoves: [Move] = [
        Move(sendingAllow, .sendSucceeded, .answered(.allowOnce)),
        Move(sendingDelegate, .sendSucceeded, .handedToTerminal(since: now)),
        Move(sendingAllow, .sendFailed("offline"), .sendFailed(.allowOnce, error: "offline")),
        Move(sendingDelegate, .sendFailed("offline"), .sendFailed(.delegate, error: "offline")),
        // Handed to the TUI: no event moves it; it leaves with its turn.
        // Timed out by our clock: the broker's own outcome still wins.
        Move(.timedOut, .brokerRecordMissing, .unknownResult),
        Move(.timedOut, .brokerTerminal(.resolved(.deny)), .answered(.deny)),
        Move(.timedOut, .brokerTerminal(.resolved(.answer(["q": "a"]))), .answered(.answer(["q": "a"]))),
        Move(.timedOut, .brokerTerminal(.resolved(.delegate)), .handedToTerminal(since: now)),
        Move(.timedOut, .brokerTerminal(.canceled), .withdrawn)
    ]

    /// Every pair that moves. Any pair of the grid not listed must leave the
    /// state as it is.
    private static var moves: [Move] {
        let open = [ApprovalRequestState.held, failed].flatMap { state in
            openMoves.map { Move(state, $0.0, $0.1) }
        }
        let sending = [sendingAllow, sendingDelegate].flatMap { state in
            brokerMoves.map { Move(state, $0.0, $0.1) }
        }
        return open + sending + otherMoves
    }

    @Test func grid_coversEveryCase() {
        let stateCases = Set(Self.states.map { Self.kind(of: $0) })
        let eventCases = Set(Self.events.map { Self.kind(of: $0) })
        #expect(stateCases == Set(StateCase.allCases))
        #expect(eventCases == Set(EventCase.allCases))
    }

    @Test func transition_everyPairOfTheGrid() {
        let moves = Self.moves
        for state in Self.states {
            for event in Self.events {
                let expected = moves.first { $0.state == state && $0.event == event }?.next
                let actual = ApprovalRequestState.transition(state, event, now: Self.now)
                #expect(actual == expected, "\(state) + \(event)")
            }
        }
    }

    @Test func acceptsDecision_onlyWhileOpen() {
        let open: [ApprovalRequestState] = [.held, Self.failed]
        let closed: [ApprovalRequestState] = [
            Self.sendingAllow, Self.handed, .timedOut, .withdrawn, .unknownResult, .answered(.deny)
        ]
        let doAllOpenAccept = open.allSatisfy(\.acceptsDecision)
        #expect(doAllOpenAccept)
        #expect(!closed.contains { $0.acceptsDecision })
    }

    @Test func hasLeftTheQueue_onlyWhenSettledForGood() {
        let gone: [ApprovalRequestState] = [.withdrawn, .answered(.allowOnce)]
        let staying: [ApprovalRequestState] = [
            .held, Self.sendingAllow, Self.handed, .timedOut, .unknownResult, Self.failed
        ]
        let haveAllGoneLeft = gone.allSatisfy(\.hasLeftTheQueue)
        #expect(haveAllGoneLeft)
        #expect(!staying.contains { $0.hasLeftTheQueue })
    }

    @Test(arguments: [
        (ApprovalRequestState.held, true),
        (.sending(.allowOnce, since: SuspendingClock.now), true),
        (.sendFailed(.deny, error: "offline"), true),
        // With the TUI, it still leads to the pane where it waits.
        (.handedToTerminal(since: SuspendingClock.now), true),
        (.timedOut, false),
        (.answered(.allowOnce), false),
        (.withdrawn, false),
        (.unknownResult, false)
    ])
    func aRequestsBanner_staysOnlyWhileItLeadsSomewhere(_ state: ApprovalRequestState, _ keeps: Bool) {
        #expect(state.keepsBanner == keeps)
    }
}
