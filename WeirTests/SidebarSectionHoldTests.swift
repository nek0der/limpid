// SidebarSectionHoldTests.swift
// Weir — a row keeps its section while the pointer, the keyboard, or a drag holds the sidebar.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct SidebarSectionHoldTests {
    private static func next(
        presented: [String: SidebarSection],
        computed: [String: SidebarSection],
        isHeld: Bool,
        selected: String? = nil
    ) -> [String: SidebarSection] {
        SidebarSectionHold.next(presented: presented, computed: computed, isHeld: isHeld, selected: selected)
    }

    /// A row whose section changed (its last tab closed) stays where it is
    /// shown while the sidebar is held.
    @Test func whileHeld_aRowKeepsTheSectionItIsShownIn() {
        let shown = Self.next(presented: ["a": .working, "b": .working], computed: ["a": .cleanable, "b": .working], isHeld: true)
        #expect(shown == ["a": .working, "b": .working])
    }

    /// Once nothing holds the sidebar, every row goes where it belongs.
    @Test func released_everyRowGoesWhereItBelongs() {
        let shown = Self.next(presented: ["a": .working], computed: ["a": .cleanable], isHeld: false)
        #expect(shown == ["a": .cleanable])
    }

    /// What is added or removed is not held: a new row is placed where it
    /// belongs, a row that is gone goes.
    @Test func whileHeld_aNewRowIsPlaced_andAGoneRowGoes() {
        let shown = Self.next(
            presented: ["a": .working, "gone": .working],
            computed: ["a": .other, "new": .other],
            isHeld: true
        )
        #expect(shown == ["a": .working, "new": .other])
    }

    /// A row coming into the working rows is not held back: one folded
    /// away that now waits on the person shows while they point at the
    /// sidebar.
    @Test func whileHeld_aRowComingIntoTheWorkingRows_comesAtOnce() {
        let shown = Self.next(presented: ["a": .other, "b": .cleanable], computed: ["a": .working, "b": .working], isHeld: true)
        #expect(shown == ["a": .working, "b": .working])
    }

    /// The selected row is always a working one, held or not.
    @Test(arguments: [true, false])
    func theSelectedRow_isAlwaysWorking(isHeld: Bool) {
        let shown = Self.next(presented: ["a": .other], computed: ["a": .other, "b": .cleanable], isHeld: isHeld, selected: "a")
        #expect(shown["a"] == .working)
        #expect(shown["b"] == .cleanable)
    }

    /// A selected row the project does not list (the scratch row) is not
    /// added.
    @Test func aSelectedRowNotListed_isNotAdded() {
        let shown = Self.next(presented: [:], computed: ["a": .other], isHeld: false, selected: "scratch")
        #expect(shown == ["a": .other])
    }
}

/// The window's hold: the pointer, the keyboard, a drag, and a row the
/// person moved themselves.
@MainActor
struct ProjectWindowSectionHoldTests {
    private static func window() -> (window: ProjectWindowState, row: ContainerID) {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let row = ContainerID.worktree(projectID: project.id, worktreeID: UUID())
        return (ProjectWindowState(selection: session.primarySelection), row)
    }

    private static func sections(_ row: ContainerID, _ section: SidebarSection) -> SidebarPresentedSections {
        SidebarPresentedSections(sections: [row: section])
    }

    /// Each hold keeps the row where it was drawn.
    @Test(arguments: ["pointer", "keyboard", "drag"])
    func eachHold_keepsTheRowWhereItWasDrawn(hold: String) {
        let (window, row) = Self.window()
        window.present(Self.sections(row, .working))
        window.isPointerInSidebar = hold == "pointer"
        window.isSidebarKeyboardActive = hold == "keyboard"

        let shown = window.presentedSections(computed: Self.sections(row, .cleanable), isDragging: hold == "drag")
        #expect(shown.section(of: row) == .working)

        window.isPointerInSidebar = false
        window.isSidebarKeyboardActive = false
        #expect(window.presentedSections(computed: Self.sections(row, .cleanable), isDragging: false).section(of: row) == .cleanable)
    }

    /// A row the person moved themselves goes where it belongs at once,
    /// with the pointer still on the sidebar.
    @Test func aRowThePersonMoved_isNotHeld() {
        let (window, row) = Self.window()
        window.present(Self.sections(row, .working))
        window.isPointerInSidebar = true

        window.releaseHold(on: row)

        #expect(window.presentedSections(computed: Self.sections(row, .other), isDragging: false).section(of: row) == .other)
    }
}
