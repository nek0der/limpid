// SidebarKeyboardCursorTests.swift
// Limpid — the sidebar's arrow keys and Return over headers, fold lines, and rows, and which project Option-Command arrows move.

import Foundation
import Testing
@testable import Limpid

struct SidebarKeyboardCursorTests {
    typealias Cursor = SidebarKeyboardCursor

    private static let open = UUID()
    private static let folded = UUID()
    private static let row = ContainerID.project(open)

    /// `open`'s header with a row and its folded "other" line, then
    /// `folded`'s header, then the scratch row.
    private static func lines(isOtherOpen: Bool = false) -> Cursor.Lines {
        Cursor.Lines(
            ids: [.header(open), .row(row), .fold(open, .other), .header(folded), .row(.loose)],
            isCollapsed: { $0 == folded },
            isFoldOpen: { _, _ in isOtherOpen }
        )
    }

    @Test func upAndDown_stepThroughEveryLine_andStopAtTheEnds() {
        let lines = Self.lines()
        #expect(Cursor.action(for: .down, isOption: false, at: .header(Self.open), in: lines) == .move(to: .row(Self.row)))
        #expect(Cursor.action(for: .down, isOption: false, at: .fold(Self.open, .other), in: lines) == .move(to: .header(Self.folded)))
        #expect(Cursor.action(for: .up, isOption: false, at: .header(Self.folded), in: lines) == .move(to: .fold(Self.open, .other)))
        #expect(Cursor.action(for: .down, isOption: false, at: .row(.loose), in: lines) == .move(to: .row(.loose)))
        #expect(Cursor.action(for: .up, isOption: false, at: .header(Self.open), in: lines) == .move(to: .header(Self.open)))
        #expect(Cursor.action(for: .down, isOption: false, at: nil, in: lines) == .move(to: .header(Self.open)))
    }

    @Test func rightAndLeft_openAndFoldAHeader() {
        let lines = Self.lines()
        #expect(Cursor.action(for: .right, isOption: false, at: .header(Self.folded), in: lines) == .setCollapsed(Self.folded, false))
        #expect(Cursor.action(for: .left, isOption: false, at: .header(Self.open), in: lines) == .setCollapsed(Self.open, true))
        #expect(Cursor.action(for: .left, isOption: false, at: .header(Self.folded), in: lines) == Cursor.Action.none)
    }

    /// → on an open header goes into its lines, as a list of folders does;
    /// ← on a row goes up to its header.
    @Test func rightOnAnOpenHeader_goesIn_andLeftOnARow_goesUpToItsHeader() {
        let lines = Self.lines()
        #expect(Cursor.action(for: .right, isOption: false, at: .header(Self.open), in: lines) == .move(to: .row(Self.row)))
        #expect(Cursor.action(for: .left, isOption: false, at: .row(Self.row), in: lines) == .move(to: .header(Self.open)))
        #expect(Cursor.action(for: .left, isOption: false, at: .row(.loose), in: lines) == Cursor.Action.none, "scratch has no header")
        #expect(Cursor.action(for: .right, isOption: false, at: .row(Self.row), in: lines) == Cursor.Action.none)
    }

    @Test func rightAndLeft_openAndFoldAFoldLine_andLeftOnAFoldedOne_goesUpToItsHeader() {
        let folded = Self.lines(isOtherOpen: false)
        let opened = Self.lines(isOtherOpen: true)
        #expect(Cursor.action(for: .right, isOption: false, at: .fold(Self.open, .other), in: folded) == .setFoldOpen(
            Self.open,
            .other,
            true
        ))
        #expect(Cursor.action(for: .right, isOption: false, at: .fold(Self.open, .other), in: opened) == Cursor.Action.none)
        #expect(Cursor.action(for: .left, isOption: false, at: .fold(Self.open, .other), in: opened) == .setFoldOpen(
            Self.open,
            .other,
            false
        ))
        #expect(Cursor.action(for: .left, isOption: false, at: .fold(Self.open, .other), in: folded) == .move(to: .header(Self.open)))
    }

    /// With ⌥, ← and → on a header fold or open every header.
    @Test func optionWithLeftOrRightOnAHeader_foldsOrOpensEveryHeader() {
        let lines = Self.lines()
        #expect(Cursor.action(for: .left, isOption: true, at: .header(Self.folded), in: lines) == .setAllCollapsed(true))
        #expect(Cursor.action(for: .right, isOption: true, at: .header(Self.open), in: lines) == .setAllCollapsed(false))
    }

    @Test func return_opensTheRow_orTogglesAHeaderOrAFoldLine() {
        let lines = Self.lines()
        #expect(Cursor.action(for: .return, isOption: false, at: .row(Self.row), in: lines) == .activate(Self.row))
        #expect(Cursor.action(for: .return, isOption: false, at: .header(Self.open), in: lines) == .setCollapsed(Self.open, true))
        #expect(Cursor.action(for: .return, isOption: false, at: .header(Self.folded), in: lines) == .setCollapsed(Self.folded, false))
        #expect(Cursor.action(for: .return, isOption: false, at: .fold(Self.open, .other), in: lines) == .setFoldOpen(
            Self.open,
            .other,
            true
        ))
        #expect(Cursor.action(for: .return, isOption: false, at: nil, in: lines) == Cursor.Action.none)
    }

    /// ⌥⌘↑ ⌥⌘↓ move the project of the line the keys are on, else the
    /// window's; the scratch row's is the window's.
    @Test func theProjectToMove_isTheLinesElseTheWindows() {
        let shown = UUID()
        #expect(Cursor.projectToMove(at: .row(Self.row), shown: shown) == Self.open)
        #expect(Cursor.projectToMove(at: .fold(Self.folded, .cleanable), shown: shown) == Self.folded)
        #expect(Cursor.projectToMove(at: .row(.loose), shown: shown) == shown)
        #expect(Cursor.projectToMove(at: nil, shown: shown) == shown)
        #expect(Cursor.projectToMove(at: nil, shown: nil) == nil)
    }
}
