// MenuShortcutTests.swift
// Limpid — coverage for the shortcuts Limpid's own menus show: which
// command reads which shortcut, that a rebinding is what the menu shows,
// and the AppKit menu item each shortcut turns into.

import AppKit
import Testing
@testable import Limpid

@Suite("MenuShortcut")
@MainActor
struct MenuShortcutTests {
    @Test("each menu command reads the shortcut of the action that performs it")
    func shortcutSource_mapsEveryCommand() {
        let expected: [MenuCommand: MenuShortcutSource] = [
            .copy: .standardEdit(StoredShortcut(key: "c", modifiers: [.command])),
            .paste: .standardEdit(StoredShortcut(key: "v", modifiers: [.command])),
            .selectAll: .standardEdit(StoredShortcut(key: "a", modifiers: [.command])),
            .find: .action(.find),
            .splitRight: .action(.splitRight),
            .splitDown: .action(.splitDown),
            .togglePaneZoom: .action(.toggleSplitZoom),
            .closePane: .action(.closeSurface),
            .renameTab: .action(.renameTab),
            .closeTab: .action(.closeTab),
            .newWorktree: .action(.newWorktree),
            .keyboardShortcuts: .action(.keyboardShortcuts)
        ]
        #expect(Set(expected.keys) == Set(MenuCommand.allCases))
        for command in MenuCommand.allCases {
            #expect(command.shortcutSource == expected[command], "\(command)")
        }
    }

    @Test("with no overrides a menu shows each action's default")
    func shortcut_defaults_matchActionDefaults() {
        let keyboard = KeyboardSettings()
        #expect(MenuCommand.splitRight.shortcut(in: keyboard) == StoredShortcut(key: "d", modifiers: [.command]))
        #expect(
            MenuCommand.togglePaneZoom.shortcut(in: keyboard)
                == StoredShortcut(key: "return", modifiers: [.command, .shift])
        )
        #expect(MenuCommand.closePane.shortcut(in: keyboard) == StoredShortcut(key: "w", modifiers: [.command]))
    }

    @Test("a rebound action shows the user's shortcut, not the default")
    func shortcut_override_isShown() {
        var keyboard = KeyboardSettings()
        let rebound = StoredShortcut(key: "f5", modifiers: [.control])
        keyboard.setOverride(rebound, for: .splitRight)

        #expect(MenuCommand.splitRight.shortcut(in: keyboard) == rebound)
        // Only the rebound action moves.
        #expect(MenuCommand.splitDown.shortcut(in: keyboard) == LimpidShortcutAction.splitDown.defaultShortcut)

        let item = NSMenuItem(title: "Split Right", action: nil, keyEquivalent: "")
        item.showShortcut(MenuCommand.splitRight.shortcut(in: keyboard))
        #expect(item.keyEquivalent == String(Character(Self.scalar(NSF5FunctionKey))))
        #expect(item.keyEquivalentModifierMask == .control)
    }

    @Test("an action with no shortcut shows no key, while the Edit keys stay")
    func shortcut_unboundAction_showsNothing() {
        for command in MenuCommand.allCases {
            let shortcut = command.shortcut { _ in nil }
            switch command.shortcutSource {
            case .action: #expect(shortcut == nil, "\(command)")
            case let .standardEdit(fixed): #expect(shortcut == fixed, "\(command)")
            }
        }

        let item = NSMenuItem(title: "Probe", action: nil, keyEquivalent: "x")
        item.keyEquivalentModifierMask = .command
        item.showShortcut(nil)
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test("a hand-edited key no menu can show leaves the item without one")
    func shortcut_unknownStoredKey_showsNothing() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(StoredShortcut(key: "not_a_key", modifiers: [.command]), for: .closeSurface)
        #expect(MenuCommand.closePane.shortcut(in: keyboard)?.menuKeyEquivalent == nil)

        let item = NSMenuItem(title: "Close Pane", action: nil, keyEquivalent: "")
        item.showShortcut(MenuCommand.closePane.shortcut(in: keyboard))
        #expect(item.keyEquivalent.isEmpty)
    }

    @Test("a letter goes in lowercase, with Shift carried by the mask")
    func menuKeyEquivalent_letter_isLowercaseWithMask() throws {
        let rename = try #require(StoredShortcut(key: "r", modifiers: [.command, .shift]).menuKeyEquivalent)
        #expect(rename.key == "r")
        #expect(rename.modifiers == [.command, .shift])

        let upper = try #require(StoredShortcut(key: "T", modifiers: [.command]).menuKeyEquivalent)
        #expect(upper.key == "t")
        #expect(upper.modifiers == .command)

        let punctuation = try #require(StoredShortcut(key: "=", modifiers: [.command, .option]).menuKeyEquivalent)
        #expect(punctuation.key == "=")
        #expect(punctuation.modifiers == [.command, .option])
    }

    @Test("every modifier maps to its AppKit flag")
    func appKitModifierFlags_mapsEach() {
        let all: ShortcutModifiers = [.command, .shift, .option, .control]
        #expect(all.appKitModifierFlags == [.command, .shift, .option, .control])
        #expect(ShortcutModifiers().appKitModifierFlags.isEmpty)
    }

    @Test("every named key is AppKit's character for that key", arguments: NamedKey.allCases)
    func menuKeyEquivalent_namedKey_isAppKitCharacter(key: NamedKey) throws {
        let equivalent = try #require(StoredShortcut(key: key.rawValue, modifiers: [.command]).menuKeyEquivalent)
        let expected = try #require(Self.appKitCharacters[key], "no AppKit character listed for \(key)")
        #expect(Array(equivalent.key.unicodeScalars).map(\.value) == [UInt32(expected)])
    }

    /// The zoom default is the one named-key shortcut a menu shows out of the
    /// box; check the item it becomes answers that key, so the glyph shown is
    /// the key that works.
    @Test("the zoom item shows and answers ⌘⇧↩, not another key")
    func zoomItem_firesOnShortcut() throws {
        let target = MenuItemProbe()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Zoom Pane", action: #selector(MenuItemProbe.fire(_:)), keyEquivalent: "")
        item.target = target
        item.showShortcut(MenuCommand.togglePaneZoom.shortcut(in: KeyboardSettings()))
        menu.addItem(item)
        #expect(item.keyEquivalent == "\r")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        #expect(try menu.performKeyEquivalent(with: Self.keyDown("\r", keyCode: 36, modifiers: [.command, .shift])))
        #expect(target.fireCount == 1)
        #expect(try !menu.performKeyEquivalent(with: Self.keyDown("\t", keyCode: 48, modifiers: [.command, .shift])))
        #expect(target.fireCount == 1)
    }

    @Test("a view answering the Copy key matches exactly the shortcut its menu shows")
    func isPressed_matchesKeyAndModifiersExactly() throws {
        let copy = StandardEditShortcut.copy
        #expect(try copy.isPressed(in: Self.keyDown("c", keyCode: 8, modifiers: .command)))
        // Caps Lock and the fn key are not part of a shortcut.
        #expect(try copy.isPressed(in: Self.keyDown("c", keyCode: 8, modifiers: [.command, .capsLock])))
        #expect(try !copy.isPressed(in: Self.keyDown("C", keyCode: 8, modifiers: [.command, .shift])))
        #expect(try !copy.isPressed(in: Self.keyDown("c", keyCode: 8, modifiers: [.command, .option])))
        #expect(try !copy.isPressed(in: Self.keyDown("v", keyCode: 9, modifiers: .command)))
        #expect(try !copy.isPressed(in: Self.keyDown("c", keyCode: 8, modifiers: [])))
    }

    // MARK: - Helpers

    /// AppKit's character for each named key, from AppKit's own constants
    /// where it has one.
    private static let appKitCharacters: [NamedKey: Int] = [
        .return: NSCarriageReturnCharacter,
        .tab: NSTabCharacter,
        .space: 0x20,
        // AppKit names no constant for Escape; menus use the ASCII control.
        .escape: 0x1B,
        .backspace: NSBackspaceCharacter,
        .delete: NSDeleteFunctionKey,
        .home: NSHomeFunctionKey,
        .end: NSEndFunctionKey,
        .pageUp: NSPageUpFunctionKey,
        .pageDown: NSPageDownFunctionKey,
        .left: NSLeftArrowFunctionKey,
        .right: NSRightArrowFunctionKey,
        .up: NSUpArrowFunctionKey,
        .down: NSDownArrowFunctionKey,
        .f1: NSF1FunctionKey,
        .f2: NSF2FunctionKey,
        .f3: NSF3FunctionKey,
        .f4: NSF4FunctionKey,
        .f5: NSF5FunctionKey,
        .f6: NSF6FunctionKey,
        .f7: NSF7FunctionKey,
        .f8: NSF8FunctionKey,
        .f9: NSF9FunctionKey,
        .f10: NSF10FunctionKey,
        .f11: NSF11FunctionKey,
        .f12: NSF12FunctionKey,
        .f13: NSF13FunctionKey,
        .f14: NSF14FunctionKey,
        .f15: NSF15FunctionKey,
        .f16: NSF16FunctionKey,
        .f17: NSF17FunctionKey,
        .f18: NSF18FunctionKey,
        .f19: NSF19FunctionKey,
        .f20: NSF20FunctionKey
    ]

    private static func scalar(_ value: Int) -> Unicode.Scalar {
        Unicode.Scalar(UInt32(value)) ?? "\u{0}"
    }

    private static func keyDown(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

/// Counts how often the probe menu item runs its action.
@MainActor
private final class MenuItemProbe: NSObject {
    private(set) var fireCount = 0

    @objc func fire(_: NSMenuItem) {
        fireCount += 1
    }
}
