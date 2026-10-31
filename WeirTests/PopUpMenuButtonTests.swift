// PopUpMenuButtonTests.swift
// Weir — coverage for the AppKit menu a "⋯" button opens: the items it
// builds, the language their titles follow, and what the button tells
// VoiceOver.

import AppKit
import Testing
@testable import Weir

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

    @Test("a disabled item says why as its tooltip, in the locale SwiftUI is showing")
    func make_disabledItem_saysWhyInItsTooltip() {
        let entries: [PopUpMenuEntry] = [.item(PopUpMenuItem(
            title: "Start New Conversation",
            isEnabled: false,
            help: StopResumeRules.newConversationHelp(.notAtShell)
        ) {})]
        #expect(PopUpMenu.make(entries, locale: Locale(identifier: "ja")).items.first?.toolTip
            == "新しい会話で開始するには、ペインをシェルのプロンプトに戻してください。")
        #expect(PopUpMenu.make([.item(PopUpMenuItem(title: "Close Pane") {})], locale: Locale(identifier: "en"))
            .items.first?.toolTip == nil)
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

    @Test("a trigger with words of its own shows them as its tooltip, and opens nothing while off")
    func trigger_withHelpAndValue() {
        let trigger = PopUpMenuTriggerView()
        trigger.title = "Claude #2"
        trigger.help = "Claude #2 · 1 unviewed · Ended"
        trigger.value = "1 unviewed turn · Ended"
        var opened = 0
        trigger.makeMenu = {
            opened += 1
            return NSMenu()
        }
        trigger.isEnabled = false

        #expect(trigger.toolTip == "Claude #2 · 1 unviewed · Ended", "the AppKit tooltip under the pointer")
        #expect(trigger.accessibilityTitle() == "Claude #2")
        #expect(trigger.accessibilityValue() as? String == "1 unviewed turn · Ended")
        #expect(!trigger.isAccessibilityEnabled())
        #expect(trigger.accessibilityHelp() == nil, "the value says it; VoiceOver does not read it twice")
        #expect(!trigger.acceptsFirstResponder, "off, the keyboard does not reach it")
        #expect(!trigger.canBecomeKeyView)
        #expect(!trigger.accessibilityPerformPress(), "off, VoiceOver's press is refused")
        trigger.open()
        #expect(opened == 0)
    }

    /// The decision bar's ⋯ stays out of the ⇥ order, as the bar's buttons
    /// do, so ⇥ is the terminal's; VoiceOver still opens it.
    @Test("a trigger kept out of the Tab order never takes the keyboard, and VoiceOver still opens it")
    func trigger_keptOutOfTheTabOrder() {
        #expect(PopUpMenuTriggerView.takesKeyboard(isFullKeyboardAccessOn: true, isEnabled: true, allowsKeyboardFocus: true))
        #expect(!PopUpMenuTriggerView.takesKeyboard(isFullKeyboardAccessOn: true, isEnabled: true, allowsKeyboardFocus: false))
        #expect(!PopUpMenuTriggerView.takesKeyboard(isFullKeyboardAccessOn: false, isEnabled: true, allowsKeyboardFocus: true))
        #expect(!PopUpMenuTriggerView.takesKeyboard(isFullKeyboardAccessOn: true, isEnabled: false, allowsKeyboardFocus: true))

        let trigger = PopUpMenuTriggerView()
        trigger.allowsKeyboardFocus = false
        #expect(!trigger.acceptsFirstResponder)
        #expect(!trigger.canBecomeKeyView)
        #expect(trigger.isAccessibilityElement() && trigger.isAccessibilityEnabled(), "VoiceOver still reaches it")
    }

    @Test("a verbatim item keeps its words, its checkmark, and its tooltip")
    func make_verbatimItem() {
        let menu = PopUpMenu.make([
            .item(PopUpMenuItem(
                verbatim: "Claude #1 · 1",
                isChecked: true,
                help: "Claude #1 · 1 unviewed",
                accessibilityLabel: "Claude #1",
                accessibilityValue: "1 unviewed turn"
            ) {}),
            .item(PopUpMenuItem(verbatim: "Claude #2 · 0") {})
        ], locale: Locale(identifier: "ja"))

        #expect(menu.items.map(\.title) == ["Claude #1 · 1", "Claude #2 · 0"], "not looked up as a key")
        #expect(menu.items.map(\.state) == [.on, .off])
        #expect(menu.items.map(\.toolTip) == ["Claude #1 · 1 unviewed", nil])
        #expect(menu.items[0].accessibilityLabel() == "Claude #1")
        #expect(menu.items[0].accessibilityValue() as? String == "1 unviewed turn")
    }

    @Test("a heading carries its badge and name in their own colors, so it does not read as an item that is off")
    func make_headingKeepsItsColors() throws {
        let badge = NSImage(size: NSSize(width: 16, height: 12))
        let menu = PopUpMenu.make([
            .heading(PopUpMenuHeading(
                title: "Claude #4",
                subtitle: "Unviewed 2",
                image: { badge },
                accessibilityLabel: "Claude #4, 2 unviewed"
            ))
        ], locale: Locale(identifier: "en"))

        let item = try #require(menu.items.first)
        #expect(item.isSectionHeader)
        // A heading is drawn as a disabled item, which fades an item image:
        // the badge rides in the title instead.
        #expect(item.image == nil)
        let title = try #require(item.attributedTitle)
        #expect(title.string == "\u{FFFC} Claude #4\u{2028}Unviewed 2")
        let attachment = title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.image === badge)
        let name = (title.string as NSString).range(of: "Claude #4")
        #expect(title.attribute(.foregroundColor, at: name.location, effectiveRange: nil) as? NSColor == .labelColor)
        let state = (title.string as NSString).range(of: "Unviewed 2")
        #expect(title.attribute(.foregroundColor, at: state.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(item.accessibilityLabel() == "Claude #4, 2 unviewed")
    }
}
