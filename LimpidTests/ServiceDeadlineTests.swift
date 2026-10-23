// ServiceDeadlineTests.swift
// Limpid — the time left on a request, carried forward on our clock.

import Foundation
import Testing
@testable import Limpid

struct ServiceDeadlineTests {
    private static let received = SuspendingClock().now

    @Test func remaining_isTheServiceDifferenceMinusTimeSinceReceipt() {
        let deadline = ServiceDeadline(deadlineMs: 600_000, serviceNowMs: 30000, receivedAt: Self.received)

        #expect(deadline.remaining(at: Self.received) == .seconds(570))
        #expect(deadline.remaining(at: Self.received.advanced(by: .seconds(70))) == .seconds(500))
    }

    @Test func remaining_neverGoesNegative() {
        let deadline = ServiceDeadline(deadlineMs: 10000, serviceNowMs: 0, receivedAt: Self.received)
        #expect(deadline.remaining(at: Self.received.advanced(by: .seconds(11))) == .zero)
    }

    @Test func remaining_aDeadlineAlreadyPassedAtTheService_isZero() {
        let deadline = ServiceDeadline(deadlineMs: 1000, serviceNowMs: 5000, receivedAt: Self.received)
        #expect(deadline.remaining(at: Self.received) == .zero)
    }

    @Test func remaining_aReadingBeforeReceipt_doesNotAddTime() {
        let deadline = ServiceDeadline(deadlineMs: 10000, serviceNowMs: 0, receivedAt: Self.received)
        #expect(deadline.remaining(at: Self.received.advanced(by: .seconds(-3))) == .seconds(10))
    }
}
