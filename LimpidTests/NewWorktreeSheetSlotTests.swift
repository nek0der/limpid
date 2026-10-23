// NewWorktreeSheetSlotTests.swift
// Limpid — one window's new worktree sheet from the ask to its close: one at a time, and never a request left waiting.

import Foundation
import Testing
@testable import Limpid

struct NewWorktreeSheetSlotTests {
    private let project = UUID()

    @Test func anAsk_opensTheSheet() {
        var slot = NewWorktreeSheetSlot()
        let request = NewSessionSheetRequest(projectID: project)

        #expect(slot.open(request, isWindowCovered: false) == .opened)

        #expect(slot.request == request)
        #expect(!slot.isShown)
    }

    /// Up, the sheet keeps what the person typed: a second ask is refused.
    @Test func aSheetUp_refusesASecondAsk() {
        var slot = NewWorktreeSheetSlot()
        let first = NewSessionSheetRequest(projectID: project)
        _ = slot.open(first, isWindowCovered: false)
        slot.appeared(first.id)

        // Ours covers the window too once it is up; that refuses nothing more.
        #expect(slot.open(NewSessionSheetRequest(projectID: UUID()), isWindowCovered: true) == .refusedSheetUp)
        #expect(slot.open(NewSessionSheetRequest(projectID: UUID()), isWindowCovered: false) == .refusedSheetUp)

        #expect(slot.request == first)
        #expect(slot.isShown)
    }

    /// A request that never came up stands in the way of no later one.
    @Test func aRequestThatNeverCameUp_isReplacedByTheNext() {
        var slot = NewWorktreeSheetSlot()
        let stuck = NewSessionSheetRequest(projectID: project)
        _ = slot.open(stuck, isWindowCovered: false)
        let next = NewSessionSheetRequest(projectID: UUID())

        #expect(slot.open(next, isWindowCovered: false) == .opened)

        #expect(slot.request == next)
        // The replaced one's view appearing late marks nothing up.
        slot.appeared(stuck.id)
        #expect(!slot.isShown)
    }

    /// Under another sheet, ours could not come up: it is not kept, so
    /// nothing opens as that sheet goes.
    @Test func anAskUnderAnotherSheet_isNotKept() {
        var slot = NewWorktreeSheetSlot()

        #expect(slot.open(NewSessionSheetRequest(projectID: project), isWindowCovered: true) == .refusedWindowCovered)
        slot.coverEnded()

        #expect(slot.request == nil)
    }

    /// Ours, between the ask and its view appearing, covers the window
    /// itself: an ask then leaves it to come up.
    @Test func anAskWhileOursComesUp_leavesOursComingUp() {
        var slot = NewWorktreeSheetSlot()
        let ours = NewSessionSheetRequest(projectID: project)
        _ = slot.open(ours, isWindowCovered: false)

        #expect(slot.open(NewSessionSheetRequest(projectID: UUID()), isWindowCovered: true) == .refusedWindowCovered)
        slot.appeared(ours.id)

        #expect(slot.request == ours)
        #expect(slot.isShown)
    }

    /// A request another sheet took the moment from is dropped as the
    /// window's sheets end, rather than opening later, unasked.
    @Test func aRequestStillWaiting_asTheCoverEnds_isDropped() {
        var slot = NewWorktreeSheetSlot()
        _ = slot.open(NewSessionSheetRequest(projectID: project), isWindowCovered: false)

        slot.coverEnded()

        #expect(slot.request == nil)
        #expect(slot.open(NewSessionSheetRequest(projectID: project), isWindowCovered: false) == .opened)
    }

    /// The sheet's own cover ending leaves it up until it closes.
    @Test func theCoverEnding_leavesASheetUp_andClosingEmptiesTheSlot() {
        var slot = NewWorktreeSheetSlot()
        let request = NewSessionSheetRequest(projectID: project)
        _ = slot.open(request, isWindowCovered: false)
        slot.appeared(request.id)

        slot.coverEnded()
        #expect(slot.request == request)

        slot.close()
        #expect(slot.request == nil)
        #expect(!slot.isShown)
    }

    // MARK: - ⌥⌘N's note

    /// The note is said once the sheet carrying it is up, and only then.
    @Test func theNote_isSaidAsItsSheetComesUp_once() {
        var slot = NewWorktreeSheetSlot()
        let request = NewSessionSheetRequest(projectID: project)
        _ = slot.open(request, isWindowCovered: false, introducesInstantKey: true)

        let isSaid = slot.appeared(request.id)
        let isSaidAgain = slot.appeared(request.id)

        #expect(isSaid)
        #expect(!isSaidAgain, "a second appearance says nothing more")
    }

    /// A sheet with no note, or a note replaced before it came up, says
    /// nothing.
    @Test func noNote_orOneReplaced_isNotSaid() {
        var slot = NewWorktreeSheetSlot()
        let plain = NewSessionSheetRequest(projectID: project)
        _ = slot.open(plain, isWindowCovered: false)
        let isPlainSaid = slot.appeared(plain.id)
        #expect(!isPlainSaid)

        slot.close()
        let noted = NewSessionSheetRequest(projectID: project)
        _ = slot.open(noted, isWindowCovered: false, introducesInstantKey: true)
        let next = NewSessionSheetRequest(projectID: project)
        _ = slot.open(next, isWindowCovered: false)
        #expect(!slot.introducesInstantKey)
        let isReplacedSaid = slot.appeared(noted.id)
        let isNextSaid = slot.appeared(next.id)
        #expect(!isReplacedSaid)
        #expect(!isNextSaid)
    }

    /// Closing, or losing its moment, drops the note with its request.
    @Test func closing_orTheCoverEnding_dropsTheNote() {
        var slot = NewWorktreeSheetSlot()
        _ = slot.open(NewSessionSheetRequest(projectID: project), isWindowCovered: false, introducesInstantKey: true)
        slot.close()
        #expect(!slot.introducesInstantKey)

        _ = slot.open(NewSessionSheetRequest(projectID: project), isWindowCovered: false, introducesInstantKey: true)
        slot.coverEnded()
        #expect(!slot.introducesInstantKey)
    }
}
