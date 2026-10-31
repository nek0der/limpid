// WindowAlertTests.swift
// Limpid — a confirmation about a window is a sheet on it, stands on its own only when the window cannot take one, and is answered
// Cancel when its window closes or hides.

import AppKit
import Foundation
import SwiftUI
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
    /// which is not. Hidden the way the app hides one, through the registry
    /// and the presenter, which is what answers the sheet.
    @MainActor
    @Test(arguments: [true, false])
    func aRealSheet_isAnsweredCancel_whenItsWindowIsHidden(isExclusive: Bool) throws {
        let session = WorkspaceSession()
        let registry = WindowRegistry(primary: session.primarySelection)
        let presenter = ProjectWindowPresenter(session: session, registry: registry) { _ in AnyView(EmptyView()) }
        registry.presenter = presenter
        // The host app may own a window of its own: only the one this `show`
        // added is the test's.
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        registry.show(registry.primary.id)
        let window = try #require(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) })
        defer { registry.hide(registry.primary.id) }
        let record = SheetRecord()
        WindowAlert.begin(NSAlert(), on: window, isExclusive: isExclusive) { record.responses.append($0) }
        #expect(window.attachedSheet != nil)
        #expect(record.responses.isEmpty)

        registry.hide(registry.primary.id)

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
