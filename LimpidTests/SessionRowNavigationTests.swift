// SessionRowNavigationTests.swift
// Limpid — the step from one sidebar row to the next: arrow keys stop at the ends, the session keys wrap around.

import Foundation
import Testing
@testable import Limpid

struct SessionRowNavigationTests {
    @Test func arrowKeysInTheSidebar_stopAtTheEnds() {
        let first = ContainerID.project(UUID())
        let rows = [first, .loose]
        #expect(SessionRowNavigation.keyboardStep(from: first, in: rows, forward: true) == .loose)
        #expect(SessionRowNavigation.keyboardStep(from: .loose, in: rows, forward: true) == .loose)
        #expect(SessionRowNavigation.keyboardStep(from: first, in: rows, forward: false) == first)
        #expect(SessionRowNavigation.keyboardStep(from: nil, in: rows, forward: false) == .loose)
        #expect(SessionRowNavigation.keyboardStep(from: nil, in: [ContainerID](), forward: true) == nil)
    }

    /// The arrow keys stop on the headers and the fold lines too, in the
    /// order the list draws them.
    @Test func arrowKeysInTheSidebar_stopOnTheHeadersAndFoldLines() {
        let project = UUID()
        let row = SidebarItemID.row(.project(project))
        let lines: [SidebarItemID] = [.header(project), row, .fold(project, .cleanable), .fold(project, .other), .row(.loose)]
        #expect(SessionRowNavigation.keyboardStep(from: row, in: lines, forward: true) == .fold(project, .cleanable))
        #expect(SessionRowNavigation.keyboardStep(from: .fold(project, .cleanable), in: lines, forward: true) == .fold(project, .other))
        #expect(SessionRowNavigation.keyboardStep(from: .fold(project, .other), in: lines, forward: false) == .fold(project, .cleanable))
        #expect(SessionRowNavigation.keyboardStep(from: row, in: lines, forward: false) == .header(project))
    }

    @Test func sessionKeys_walkTheRows_andWrapAround() {
        let first = ContainerID.project(UUID())
        let second = ContainerID.loose
        let rows = [first, second]

        #expect(SessionRowNavigation.step(from: first, in: rows, forward: true) == second)
        #expect(SessionRowNavigation.step(from: second, in: rows, forward: true) == first)
        #expect(SessionRowNavigation.step(from: first, in: rows, forward: false) == second)
        // From a container the sidebar does not list (a project gone).
        #expect(SessionRowNavigation.step(from: .project(UUID()), in: rows, forward: true) == first)
        #expect(SessionRowNavigation.step(from: first, in: [], forward: true) == nil)
    }

    /// ⌃⌘n goes to a working row only: the menu's "Go to Worktree n"
    /// is off past the last of them, and with none, every number is off.
    @Test(arguments: [(1, 3, true), (3, 3, true), (4, 3, false), (9, 3, false), (1, 0, false), (0, 3, false)])
    func goToWorktreeN_isLiveOnlyUpToTheWorkingRows(number: Int, count: Int, isLive: Bool) {
        #expect(SessionRowNavigation.hasRow(number: number, workingRowCount: count) == isLive)
    }
}
