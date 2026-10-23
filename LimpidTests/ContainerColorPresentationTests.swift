// ContainerColorPresentationTests.swift
// Limpid — the project color picker's floating panel: opening, replacing,
// following its dot, and closing on a pick, on Escape and on a click outside.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

@MainActor
struct ContainerColorPresentationTests {
    private let project = UUID()
    private let other = UUID()
    private let dot = CGRect(x: 20, y: 120, width: 18, height: 18)

    @Test func open_hangsThePickerFromTheDot() throws {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        let request = try #require(presentation.request)
        #expect(request.projectID == project)
        #expect(request.anchor == dot)
    }

    @Test func open_anotherRowReplacesTheOpenPicker() throws {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        let first = try #require(presentation.request)
        presentation.open(projectID: other, anchor: dot.offsetBy(dx: 0, dy: 40))
        let second = try #require(presentation.request)
        #expect(second.projectID == other)
        #expect(second.id != first.id, "a new opening is measured afresh")
    }

    @Test func updateAnchor_followsOnlyTheOwningRow() {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        presentation.updateAnchor(projectID: other, anchor: .zero)
        #expect(presentation.request?.anchor == dot)
        let scrolled = dot.offsetBy(dx: 0, dy: -30)
        presentation.updateAnchor(projectID: project, anchor: scrolled)
        #expect(presentation.request?.anchor == scrolled)
    }

    @Test func pick_returnsTheChoiceAndCloses() throws {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        let pick = try #require(presentation.pick(7))
        #expect(pick.projectID == project)
        #expect(pick.paletteIndex == 7)
        #expect(presentation.request == nil)
        #expect(presentation.pick(2) == nil, "nothing open, nothing to apply")
    }

    @Test func escape_closesAndIsSpent_otherKeysAreNot() {
        let presentation = ContainerColorPresentation()
        #expect(!presentation.keyPressed(isEscape: true), "nothing open, nothing spent")

        presentation.open(projectID: project, anchor: dot)
        #expect(!presentation.keyPressed(isEscape: false), "other keys go where they were going")
        #expect(presentation.request != nil)
        #expect(presentation.keyPressed(isEscape: true), "Escape must reach neither the terminal nor the sheet")
        #expect(presentation.request == nil)
    }

    @Test func clickOutside_closes() {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        presentation.pointerPressedOutside()
        #expect(presentation.request == nil)
    }

    @Test func rowDisappearing_closesOnlyItsOwnPicker() {
        let presentation = ContainerColorPresentation()
        presentation.open(projectID: project, anchor: dot)
        presentation.rowDisappeared(projectID: other)
        #expect(presentation.request != nil)
        presentation.rowDisappeared(projectID: project)
        #expect(presentation.request == nil)
    }
}
