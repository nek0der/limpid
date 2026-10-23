// WindowAlertTests.swift
// Limpid — a confirmation about a window is a sheet on it, stands on its own only when the window cannot take one, and is answered
// Cancel when its window closes or hides.

import AppKit
import Foundation
import Testing
@testable import Limpid

@Suite(.hostsWindows)
struct WindowAlertTests {
    /// A sheet only on a visible window with no sheet up: a second sheet
    /// would wait, unseen, until the first is answered.
    @Test(arguments: [
        (WindowAlert.Host?(.init(isVisible: true, hasSheet: false)), WindowAlert.Presentation.sheet),
        (nil, .appModal),
        (.init(isVisible: true, hasSheet: true), .appModal),
        (.init(isVisible: false, hasSheet: false), .appModal)
    ])
    func theAlert_isASheetOnlyOnAVisibleWindowWithNone(host: WindowAlert.Host?, expected: WindowAlert.Presentation) {
        #expect(WindowAlert.presentation(on: host) == expected)
    }

    @Test func aCloseConfirmation_goesToTheFirstDrawnPanesWindow() {
        let first = UUID()
        let second = UUID()
        let windows = [second: "second"]
        let window = WindowAlert.window(requested: String?.none, for: [first, second], windowOf: { windows[$0] }, fallback: "key")
        #expect(window == "second")
    }

    @Test func theWindowItWasAskedIn_comesBeforeThePanes() {
        let pane = UUID()
        let window = WindowAlert.window(requested: "asked", for: [pane], windowOf: { _ in "pane's" }, fallback: "key")
        #expect(window == "asked")
    }

    @Test func aTabWithNoDrawnPane_confirmsOnTheKeyWindow() {
        let window = WindowAlert.window(requested: String?.none, for: [UUID()], windowOf: { _ in String?.none }, fallback: "key")
        #expect(window == "key")
        #expect(WindowAlert.window(requested: String?.none, for: [], windowOf: { _ in String?.none }, fallback: String?.none) == nil)
    }

    // MARK: - Real sheets

    @MainActor
    @Test func aRealSheet_isAnsweredCancel_whenItsWindowCloses_andOnlyOneIsUpAtATime() {
        let window = Self.shownWindow()
        let record = SheetRecord()
        WindowAlert.begin(NSAlert(), on: window, isExclusive: true) { record.responses.append($0) }
        #expect(window.attachedSheet != nil)
        // A second close question while the first is up is dropped at once.
        let second = SheetRecord()
        WindowAlert.begin(NSAlert(), on: window, isExclusive: true) { second.responses.append($0) }
        #expect(second.responses == [.cancel])
        window.close()
        #expect(record.responses == [.cancel])
    }

    /// A close question, which is exclusive, and a link's confirmation,
    /// which is not.
    @MainActor
    @Test(arguments: [true, false])
    func aRealSheet_isAnsweredCancel_whenItsWindowIsHidden(isExclusive: Bool) {
        let window = Self.shownWindow()
        defer { window.close() }
        let record = SheetRecord()
        WindowAlert.begin(NSAlert(), on: window, isExclusive: isExclusive) { record.responses.append($0) }
        WindowAlert.cancelPending(on: window)
        window.orderOut(nil)
        #expect(record.responses == [.cancel])
        #expect(window.attachedSheet == nil)
    }

    /// A small window on screen, which a sheet can attach to.
    @MainActor
    private static func shownWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// What a sheet answered.
    @MainActor
    private final class SheetRecord {
        var responses: [NSApplication.ModalResponse] = []
    }
}
