// QuickTerminalHotKeyCenterTests.swift
// Weir — the quick terminal hotkey center: the problem it reports, and the suspensions the Settings recorders hold.

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Weir

@Suite("QuickTerminal hotkey center")
@MainActor
struct QuickTerminalHotKeyCenterTests {

    // MARK: - Hotkey center

    /// The branches below stop before `RegisterEventHotKey`, so they run
    /// without claiming a system-wide hotkey on the test machine.
    private static func makeCenter(
        isTerminalAvailable: Bool = true,
        hotKey: StoredShortcut?,
        layout: [UInt16: String] = QuickTerminalKeyLayout.us,
        systemHotKeys: @escaping @MainActor () -> Set<HotKeyCombination> = { [] }
    ) -> QuickTerminalHotKeyCenter {
        QuickTerminalHotKeyCenter(
            isTerminalAvailable: isTerminalAvailable,
            hotKeyProvider: { hotKey },
            menuShortcutsProvider: { KeyboardSettings() },
            layoutTranslator: { QuickTerminalKeyLayout.translate(layout) },
            systemHotKeysProvider: systemHotKeys,
            onPress: {}
        )
    }

    @Test func hotKeyCenter_terminalUnavailable_withHotKey_reportsIt() {
        let center = Self.makeCenter(isTerminalAvailable: false, hotKey: .init(key: "k", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .terminalUnavailable)
    }

    @Test func hotKeyCenter_terminalUnavailable_withoutHotKey_reportsNothing() {
        let center = Self.makeCenter(isTerminalAvailable: false, hotKey: nil)
        center.apply()
        #expect(center.problem == nil)
    }

    @Test func hotKeyCenter_keyMissingFromLayout_reportsKeyNotOnLayout() {
        let center = Self.makeCenter(hotKey: .init(key: "ß", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .keyNotOnLayout)
    }

    /// A system shortcut added after the hotkey was saved keeps it off.
    /// The branch returns before `RegisterEventHotKey`.
    @Test func hotKeyCenter_takenBySystem_staysOff() {
        let hotKey = StoredShortcut(key: "k", modifiers: [.control, .option])
        let center = Self.makeCenter(hotKey: hotKey) {
            [HotKeyCombination(keyCode: 40, carbonModifiers: UInt32(controlKey | optionKey))]
        }
        center.apply()
        #expect(center.problem == .takenBySystem)
    }

    @Test func hotKeyCenter_suspended_clearsTheProblem() {
        let center = Self.makeCenter(hotKey: .init(key: "ß", modifiers: [.control, .option]))
        center.apply()
        #expect(center.problem == .keyNotOnLayout)

        let suspension = center.suspend()
        #expect(center.isSuspended)
        #expect(center.problem == nil)

        center.resume(suspension)
        #expect(!center.isSuspended)
        #expect(center.problem == .keyNotOnLayout)
    }

    /// Both Settings recorders can hold a suspension at once; the hotkey
    /// comes back only when the last one lets go, and releasing a token
    /// twice does not release anyone else's.
    @Test func hotKeyCenter_suspensions_areCountedPerOwner() {
        let center = Self.makeCenter(hotKey: nil)
        let keyboardRecorder = center.suspend()
        let quickTerminalRecorder = center.suspend()
        #expect(keyboardRecorder != quickTerminalRecorder)

        center.resume(keyboardRecorder)
        #expect(center.isSuspended)
        center.resume(keyboardRecorder)
        #expect(center.isSuspended, "a token released twice must not release another owner's hold")

        center.resume(quickTerminalRecorder)
        #expect(!center.isSuspended)
    }

    /// Resetting a menu shortcut to its default bypasses both recorders, so
    /// the hotkey center checks the effective menu bindings itself and
    /// leaves the hotkey unregistered rather than silencing the menu item.
    @Test func hotKeyCenter_menuShortcutResetOntoHotKey_staysOff() {
        let hotKey = StoredShortcut(key: "t", modifiers: [.command])
        // A reference the provider reads at each call, as the settings store
        // is: the reset below has to reach it after the center was made.
        final class Settings {
            var keyboard = KeyboardSettings()
        }
        let settings = Settings()
        settings.keyboard.setOverride(.init(key: "t", modifiers: [.command, .option]), for: .newTab)
        var pressCount = 0
        let center = QuickTerminalHotKeyCenter(
            isTerminalAvailable: true,
            hotKeyProvider: { hotKey },
            menuShortcutsProvider: { settings.keyboard },
            layoutTranslator: { QuickTerminalKeyLayout.translate([17: "t"]) },
            onPress: { pressCount += 1 }
        )

        settings.keyboard.resetOverride(for: .newTab)
        center.apply()

        #expect(center.problem == .conflictsWithMenu(.newTab))
        #expect(pressCount == 0)
    }
}
