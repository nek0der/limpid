// ContainerColorPresentationTests.swift
// Limpid — the container color picker's floating panel: opening, replacing,
// following its dot, closing on a pick, on Escape and on a click outside,
// and applying the pick to a group or a project.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@MainActor
struct ContainerColorPresentationTests {
    private let group = GroupOrProjectID.group(UUID())
    private let project = GroupOrProjectID.project(UUID())
    private let dot = CGRect(x: 20, y: 120, width: 18, height: 18)

    @Test func open_hangsThePickerFromTheDot() throws {
        let presentation = ContainerColorPresentation()
        presentation.open(container: group, anchor: dot)
        let request = try #require(presentation.request)
        #expect(request.container == group)
        #expect(request.anchor == dot)
    }

    @Test func open_anotherRowReplacesTheOpenPicker() throws {
        let presentation = ContainerColorPresentation()
        presentation.open(container: group, anchor: dot)
        let first = try #require(presentation.request)
        presentation.open(container: project, anchor: dot.offsetBy(dx: 0, dy: 40))
        let second = try #require(presentation.request)
        #expect(second.container == project)
        #expect(second.id != first.id, "a new opening is measured afresh")
    }

    @Test func updateAnchor_followsOnlyTheOwningRow() {
        let presentation = ContainerColorPresentation()
        presentation.open(container: group, anchor: dot)
        presentation.updateAnchor(container: project, anchor: .zero)
        #expect(presentation.request?.anchor == dot)
        let scrolled = dot.offsetBy(dx: 0, dy: -30)
        presentation.updateAnchor(container: group, anchor: scrolled)
        #expect(presentation.request?.anchor == scrolled)
    }

    @Test(arguments: [true, false])
    func pick_returnsTheChoiceAndCloses(forGroup: Bool) throws {
        let container = forGroup ? group : project
        let presentation = ContainerColorPresentation()
        presentation.open(container: container, anchor: dot)
        let pick = try #require(presentation.pick(7))
        #expect(pick.container == container)
        #expect(pick.paletteIndex == 7)
        #expect(presentation.request == nil)
        #expect(presentation.pick(2) == nil, "nothing open, nothing to apply")
    }

    @Test func escape_closesAndIsSpent_otherKeysAreNot() {
        let presentation = ContainerColorPresentation()
        #expect(!presentation.keyPressed(isEscape: true), "nothing open, nothing spent")

        presentation.open(container: group, anchor: dot)
        #expect(!presentation.keyPressed(isEscape: false), "other keys go where they were going")
        #expect(presentation.request != nil)
        #expect(presentation.keyPressed(isEscape: true), "Escape must reach neither the terminal nor the sheet")
        #expect(presentation.request == nil)
    }

    @Test func clickOutside_closes() {
        let presentation = ContainerColorPresentation()
        presentation.open(container: group, anchor: dot)
        presentation.pointerPressedOutside()
        #expect(presentation.request == nil)
    }

    @Test func rowDisappearing_closesOnlyItsOwnPicker() {
        let presentation = ContainerColorPresentation()
        presentation.open(container: group, anchor: dot)
        presentation.rowDisappeared(container: project)
        #expect(presentation.request != nil)
        presentation.rowDisappeared(container: group)
        #expect(presentation.request == nil)
    }

    @Test func pickedColor_landsOnTheGroupOrTheProject() throws {
        let session = WindowSession()
        let group = GroupOrProjectID.group(session.addGroup(name: "Group").id)
        let presentation = ContainerColorPresentation()

        presentation.open(container: group, anchor: dot)
        let groupPick = try #require(presentation.pick(5))
        session.setPaletteIndex(groupPick.paletteIndex, for: groupPick.container)
        #expect(session.paletteIndex(of: group) == 5)

        let projectID = UUID()
        session.projects.append(Project(
            id: projectID,
            name: "Project",
            rootURL: URL(fileURLWithPath: "/tmp/limpid-color-test")
        ))
        let project = GroupOrProjectID.project(projectID)
        presentation.open(container: project, anchor: dot)
        let projectPick = try #require(presentation.pick(9))
        session.setPaletteIndex(projectPick.paletteIndex, for: projectPick.container)
        #expect(session.paletteIndex(of: project) == 9)
        #expect(session.paletteIndex(of: group) == 5, "the other container keeps its color")
        #expect(session.paletteIndex(of: .project(UUID())) == nil)
    }
}
