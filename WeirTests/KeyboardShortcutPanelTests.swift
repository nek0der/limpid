// KeyboardShortcutPanelTests.swift
// Weir — the keyboard shortcuts panel over its window: its layers, its keys, its controls, and its height.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct KeyboardShortcutPanelTests {
    @Test func opening_closesTheWindowsOtherLayers_butNotAnotherWindowsPalette() {
        let session = WorkspaceSession()
        let window = ProjectWindowState(selection: WindowSelection())
        window.titleBarMenu = TitleBarMenuRequest(menu: .project, anchor: .zero)
        window.notificationHistory.isPresented = true
        window.isAllProjectsPresented = true
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)

        KeyboardShortcutPanelActions.toggle(window, session: session, registry: RecordingSurfaceRegistry())

        #expect(window.keyboardShortcuts.isPresented)
        #expect(window.titleBarMenu == nil)
        #expect(!window.notificationHistory.isPresented)
        #expect(!window.isAllProjectsPresented)
        #expect(session.commandPaletteState == nil)
        #expect(!window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))

        // Another window's palette is that window's own.
        KeyboardShortcutPanelActions.toggle(window, session: session, registry: RecordingSurfaceRegistry())
        #expect(!window.keyboardShortcuts.isPresented)
        let other = WindowID()
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: other)
        KeyboardShortcutPanelActions.open(window, session: session)
        #expect(session.commandPaletteState?.windowID == other)
        #expect(!window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
    }

    @Test func eachOtherLayerOfTheWindow_isOneThePanelGivesWayTo() {
        let session = WorkspaceSession()
        let window = ProjectWindowState(selection: WindowSelection())
        #expect(!window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
        window.isAllProjectsPresented = true
        #expect(window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
        window.isAllProjectsPresented = false
        window.notificationHistory.isPresented = true
        #expect(window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
        window.notificationHistory.isPresented = false
        window.titleBarMenu = TitleBarMenuRequest(menu: .project, anchor: .zero)
        #expect(window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
        window.titleBarMenu = nil
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)
        #expect(window.isAnotherLayerOpen(than: .keyboardShortcuts, session: session))
    }

    @Test func allProjects_opensAsTheWindowsOneLayer_asThePanelDoes() {
        let session = WorkspaceSession()
        let window = ProjectWindowState(selection: WindowSelection())
        window.keyboardShortcuts.isPresented = true
        window.notificationHistory.isPresented = true
        window.titleBarMenu = TitleBarMenuRequest(menu: .project, anchor: .zero)
        session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)

        window.openWindowOverlay(.allProjects, session: session)

        #expect(window.openLayers(session: session) == [.allProjects])
        #expect(!window.isAnotherLayerOpen(than: .allProjects, session: session))
        // The panel opened by its key is another layer All Projects gives way to.
        window.keyboardShortcuts.isPresented = true
        #expect(window.isAnotherLayerOpen(than: .allProjects, session: session))
        window.closeWindowOverlays()
        #expect(window.openLayers(session: session).isEmpty)
    }

    @Test func escTabAndReturn_areThePanels_andALetterOrAShortcutIsNot() throws {
        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> KeyboardShortcutPanelKeys.Key? {
            try KeyboardShortcutPanelKeys.key(for: NSEvent.testKeyDown(keyCode: keyCode, modifiers: modifiers))
        }
        #expect(try key(53) == .close)
        #expect(try key(48) == .nextControl)
        #expect(try key(48, .shift) == .previousControl)
        #expect(try key(36) == .press)
        #expect(try key(76) == .press)
        // A letter and the arrows are the field's; ⌘/ is the menu's,
        // which closes the panel by its toggle.
        #expect(try key(0) == nil)
        #expect(try key(126) == nil)
        #expect(try key(44, .command) == nil)
        #expect(try key(53, .option) == nil)
    }

    @Test func escAndTab_areThePanels_whileAnApprovalCardIsOnlyOnScreen() {
        typealias Route = WindowOverlayKeyRoute<KeyboardShortcutPanelKeys.Key>
        func route(_ key: KeyboardShortcutPanelKeys.Key?, _ holder: Route.Holder, modifier: Bool = false) -> Route {
            Route.route(key: key, holder: holder, isPresented: true, isComposing: false, hasShortcutModifier: modifier)
        }
        // A card open over the panel while the panel's field has the
        // keyboard: the card takes no key, so Esc and Tab are the panel's.
        #expect(route(.close, .field) == .take(.close))
        #expect(route(.nextControl, .field) == .take(.nextControl))
        // The keyboard in the card: its keys are the card's.
        #expect(route(.close, .approvalCard) == .pass)
        #expect(route(.nextControl, .approvalCard) == .pass)
        // Another layer's field, and a letter for the panel's own field.
        #expect(route(.close, .otherLayer) == .pass)
        #expect(route(nil, .field) == .pass)
        // A terminal under the panel: a letter is dropped and the field
        // takes the keyboard back; a shortcut goes to the menus.
        #expect(route(nil, .terminal) == .reclaim)
        #expect(route(nil, .terminal, modifier: true) == .pass)
        #expect(route(.close, .window) == .take(.close))
        // Composing, or the panel closing: nothing is the panel's.
        #expect(Route.route(key: .close, holder: .field, isPresented: true, isComposing: true, hasShortcutModifier: false) == .pass)
        #expect(Route.route(key: .close, holder: .field, isPresented: false, isComposing: false, hasShortcutModifier: false) == .pass)
    }

    @Test func tab_goesRoundThePanelsControls() {
        typealias Control = KeyboardShortcutPanelKeys.Control
        #expect(Control.search.next(backward: false) == .customize)
        #expect(Control.customize.next(backward: false) == .close)
        #expect(Control.close.next(backward: false) == .search)
        #expect(Control.search.next(backward: true) == .close)
        #expect(Control.close.next(backward: true) == .customize)
    }

    @Test func thePanel_fitsItsWindow_betweenItsLeastAndPreferredHeights() {
        let margin = WeirLayout.Supervision.sheetWindowMargin
        #expect(KeyboardShortcutOverlay.panelHeight(forWindowHeight: 2000) == KeyboardShortcutPanel.preferredHeight)
        #expect(KeyboardShortcutOverlay.panelHeight(forWindowHeight: 500) == 500 - margin)
        #expect(KeyboardShortcutOverlay.panelHeight(forWindowHeight: 200) == KeyboardShortcutPanel.minimumHeight)
    }
}
