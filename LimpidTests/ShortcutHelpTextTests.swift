// ShortcutHelpTextTests.swift
// Limpid — a control's tooltip names its key only when one is bound.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ShortcutHelpTextTests {
    @Test func aControlsTooltip_namesTheKey_onlyWhenOneIsBound() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")

        #expect(ShortcutHelpText.make(name: "Keyboard Shortcuts", shortcut: "⌘/", locale: english) == "Keyboard Shortcuts (⌘/)")
        #expect(ShortcutHelpText.make(name: "Keyboard Shortcuts", shortcut: "⌘/", locale: japanese) == "キーボードショートカット（⌘/）")
        #expect(ShortcutHelpText.make(name: "All Projects", shortcut: nil, locale: english) == "All Projects")
        #expect(ShortcutHelpText.make(name: "All Projects", shortcut: "", locale: english) == "All Projects")
    }

    @Test func theRailsSettingsIcon_namesCommandComma() {
        let key = OpenSettingsCommand.shortcutDisplay
        #expect(ShortcutHelpText.make(name: "Settings", shortcut: key, locale: Locale(identifier: "en")) == "Settings (⌘,)")
        #expect(ShortcutHelpText.make(name: "Settings", shortcut: key, locale: Locale(identifier: "ja")) == "設定（⌘,）")
    }

    /// The review's find bar names the field's own keys, as the pane's
    /// search does.
    @Test func theFindBarsButtons_nameTheFieldsKeys() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(ShortcutHelpText.make(name: "Next Match", shortcut: "⏎", locale: english) == "Next Match (⏎)")
        #expect(ShortcutHelpText.make(name: "Previous Match", shortcut: "⇧⏎", locale: japanese) == "前の一致（⇧⏎）")
        #expect(ShortcutHelpText.make(name: "Close Find Bar", shortcut: "⎋", locale: japanese) == "検索バーを閉じる（⎋）")
    }
}
