// PopUpMenuButtonTests.swift
// Limpid — coverage for the AppKit menu a "⋯" button opens: the items it
// builds, the language their titles follow, and what the button tells
// VoiceOver.

import AppKit
import Testing
@testable import Limpid

@Suite("PopUpMenuButton")
@MainActor
struct PopUpMenuButtonTests {
    @Test("entries become items and separators in order, each with its own enabled state")
    func make_buildsItemsInOrder() {
        let menu = PopUpMenu.make([
            .item(PopUpMenuItem(title: "Rename Pane…", systemImage: "pencil") {}),
            .separator,
            .item(PopUpMenuItem(title: "Close All Tabs", isEnabled: false) {})
        ], locale: Locale(identifier: "en"))

        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.title) == ["Rename Pane…", "", "Close All Tabs"])
        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false])
        #expect(menu.items[0].isEnabled)
        #expect(!menu.items[2].isEnabled)
        #expect(menu.items[0].image != nil)
        #expect(menu.items[2].image == nil)
    }

    @Test("titles follow the locale SwiftUI is showing, not the launch language")
    func make_titlesFollowLocale() {
        let entries: [PopUpMenuEntry] = [.item(PopUpMenuItem(title: "Close Pane") {})]
        #expect(PopUpMenu.make(entries, locale: Locale(identifier: "en")).items.first?.title == "Close Pane")
        #expect(PopUpMenu.make(entries, locale: Locale(identifier: "ja")).items.first?.title == "ペインを閉じる")
    }

    @Test("an item shows its shortcut, and an item without one shows no key")
    func make_showsShortcut() {
        let menu = PopUpMenu.make([
            .item(PopUpMenuItem(
                title: "Zoom Pane",
                shortcut: MenuCommand.togglePaneZoom.shortcut(in: KeyboardSettings())
            ) {}),
            .item(PopUpMenuItem(title: "Move Pane to New Tab") {})
        ], locale: Locale(identifier: "en"))

        #expect(menu.items[0].keyEquivalent == "\r")
        #expect(menu.items[0].keyEquivalentModifierMask == [.command, .shift])
        #expect(menu.items[1].keyEquivalent.isEmpty)
    }

    @Test("a destructive item is drawn like any other, as SwiftUI draws one in a menu")
    func make_destructiveItem_isPlain() throws {
        let menu = PopUpMenu.make([
            .item(PopUpMenuItem(title: "Close Pane", systemImage: "xmark.square") {}),
            .item(PopUpMenuItem(title: "Close Pane", systemImage: "xmark.square", isDestructive: true) {})
        ], locale: Locale(identifier: "en"))
        let plain = try #require(menu.items[0] as? PopUpMenuActionItem)
        let destructive = try #require(menu.items[1] as? PopUpMenuActionItem)

        #expect(destructive.isDestructive)
        #expect(!plain.isDestructive)
        #expect(destructive.title == plain.title)
        #expect(destructive.attributedTitle == nil)
        #expect(destructive.image?.isTemplate == true)
    }

    @Test("choosing an item runs its action once")
    func performItem_runsAction() {
        var runs = 0
        let menu = PopUpMenu.make(
            [.item(PopUpMenuItem(title: "Mark All as Read") { runs += 1 })],
            locale: Locale(identifier: "en")
        )
        menu.performActionForItem(at: 0)
        #expect(runs == 1)
    }

    @Test("the trigger is a menu button named by its title, which is also the tooltip")
    func trigger_isMenuButton() {
        let trigger = PopUpMenuTriggerView()
        trigger.title = "Pane actions"

        #expect(trigger.isAccessibilityElement())
        #expect(trigger.accessibilityRole() == .menuButton)
        #expect(trigger.accessibilityTitle() == "Pane actions")
        #expect(trigger.toolTip == "Pane actions")
    }

    @Test("a resource resolves in the locale it is given")
    func resolvedIn_usesLocale() {
        let resource: LocalizedStringResource = "Pane actions"
        #expect(resource.resolved(in: Locale(identifier: "en")) == "Pane actions")
        #expect(resource.resolved(in: Locale(identifier: "ja")) == "ペインの操作")
    }
}
