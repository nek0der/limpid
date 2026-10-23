// FullScreenEntryQueueTests.swift
// Limpid — windows saved in full screen go back into it one at a time, and the line never stalls.

import Foundation
import Testing
@testable import Limpid

struct FullScreenEntryQueueTests {
    private let first = WindowID()
    private let second = WindowID()
    private let third = WindowID()

    @Test func oneWindowGoesAtATime_theNextOnceItArrives() {
        var queue = FullScreenEntryQueue()

        #expect(queue.add(first) == first)
        #expect(queue.add(second) == nil)
        queue.started(first)

        #expect(queue.settled(first) == second)
        #expect(queue.settled(second) == nil)
        #expect(queue.isIdle)
    }

    @Test func anotherWindowsArrival_doesNotLetTheNextGo() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)

        // The person took a third window into full screen meanwhile.
        #expect(queue.settled(third) == nil)
        #expect(queue.entering == first)
    }

    @Test func aRequestThatNeverBegan_letsTheNextGoInTime() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)

        #expect(queue.timedOut(first, attempt: queue.attempt) == second)

        // One that began is waited for, however long it takes.
        queue.started(second)
        #expect(queue.timedOut(second, attempt: queue.attempt) == nil)
        #expect(queue.entering == second)
    }

    @Test func aTimeLimitSetForAnEarlierRequest_leavesALaterOneOfTheSameWindow() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        let earlier = queue.attempt
        // Hidden and shown again before it began: asked a second time.
        _ = queue.withdraw(first)
        _ = queue.add(first)

        #expect(queue.timedOut(first, attempt: earlier) == nil)
        #expect(queue.entering == first)
        #expect(queue.timedOut(first, attempt: queue.attempt) == nil)
        #expect(queue.isIdle)
    }

    @Test func windowsNotInLine_changeNothing() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        let before = queue

        queue.started(second)
        #expect(queue.timedOut(second, attempt: queue.attempt) == nil)
        #expect(queue.settled(second) == nil)
        #expect(queue == before)
    }

    @Test func aWindowHiddenAfterItBegan_letsTheNextGo_whoseTimeLimitThenCounts() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)
        queue.started(first)

        #expect(queue.withdraw(first).next == second)
        #expect(!queue.hasStarted)
        #expect(queue.timedOut(second, attempt: queue.attempt) == nil)
        #expect(queue.isIdle)
    }

    @Test func hidingTheWindowOnItsWay_letsTheNextGo_andItGoesWhenShown() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)
        _ = queue.add(third)

        let hiddenWaiting = queue.withdraw(third)
        #expect(hiddenWaiting.wasPending)
        #expect(hiddenWaiting.next == nil)

        let hiddenOnItsWay = queue.withdraw(first)
        #expect(hiddenOnItsWay.wasPending)
        #expect(hiddenOnItsWay.next == second)

        let notInLine = queue.withdraw(first)
        #expect(!notInLine.wasPending)
        #expect(notInLine.next == nil)
    }

    @Test func theWindowLastUsed_comesToTheFrontOnceTheLineIsDone() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        queue.raiseWhenDone(second)

        #expect(queue.takeFrontIfDone() == nil)
        _ = queue.settled(first)
        #expect(queue.takeFrontIfDone() == second)
        #expect(queue.takeFrontIfDone() == nil)

        // Nothing in line: the window is in front already.
        queue.raiseWhenDone(third)
        #expect(queue.takeFrontIfDone() == nil)
    }

    @Test func aWindowHiddenOrPassedOver_isNotBroughtToTheFront() {
        var hidden = FullScreenEntryQueue()
        _ = hidden.add(first)
        hidden.raiseWhenDone(second)
        _ = hidden.withdraw(second)
        _ = hidden.settled(first)
        #expect(hidden.takeFrontIfDone() == nil)

        // Another window shown meanwhile is the person's choice.
        var chosen = FullScreenEntryQueue()
        _ = chosen.add(first)
        chosen.raiseWhenDone(second)
        chosen.shown(third)
        _ = chosen.settled(first)
        #expect(chosen.takeFrontIfDone() == nil)
    }

    @Test func aWindowAddedTwice_waitsOnce() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(first)
        _ = queue.add(second)
        _ = queue.add(second)

        #expect(queue.waiting == [second])
    }
}
