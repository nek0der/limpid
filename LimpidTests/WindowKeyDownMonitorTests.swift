// WindowKeyDownMonitorTests.swift
// Limpid — the key-down monitor a surface sets on its own window: its window's keys only, and none once it is gone.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite(.hostsWindows)
@MainActor
struct WindowKeyDownMonitorTests {
    /// What a monitor was handed, in order.
    @MainActor
    final class Seen {
        var keys: [String] = []
    }

    /// A window showing a monitor that records what it sees in `seen` and
    /// takes every key.
    private static func window(recordingInto seen: Seen) -> NSWindow {
        let monitor = WindowKeyDownMonitor { event, _ in
            seen.keys.append(event.characters ?? "")
            return true
        }
        return hostedInWindow(monitor.frame(width: 10, height: 10), width: 200, height: 100).window
    }

    /// Posts `characters` to `window` through the app's event queue, where
    /// local monitors see it.
    private static func post(_ characters: String, to window: NSWindow) throws {
        let event = try NSEvent.testKeyDown(
            keyCode: 0,
            characters: characters,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber
        )
        NSApp.postEvent(event, atStart: false)
    }

    /// Waits for the last key posted to come round. The key itself is the
    /// signal, and the app's event queue is real, so a loaded run can hold it
    /// a good while: the deadline is only for a key that never comes.
    private static func waitForDelivery(_ condition: () -> Bool) async {
        await pollUntil(timeout: .seconds(30), interval: .milliseconds(5), condition)
    }

    @Test func theMonitor_seesItsOwnWindowsKeys_andNoneOnceGone() async throws {
        let seen = Seen()
        // A second window's monitor sees the keys posted to it in the order
        // they were posted: once it has seen one, every key posted before
        // it has been handed on.
        let witnessed = Seen()
        let own = Self.window(recordingInto: seen)
        let other = Self.window(recordingInto: witnessed)
        defer {
            own.close()
            other.close()
        }
        own.orderFront(nil)
        other.orderFront(nil)
        for window in [own, other] {
            let content = try #require(window.contentView)
            await settle(content) { descendants(of: content).contains { $0 is WindowKeyDownMonitor.HostView } }
        }

        try Self.post("a", to: own)
        try Self.post("b", to: other)
        await Self.waitForDelivery { witnessed.keys == ["b"] }
        #expect(witnessed.keys == ["b"], "another window's keys are its own")
        #expect(seen.keys == ["a"])

        own.contentView = nil
        try Self.post("c", to: own)
        try Self.post("d", to: other)
        await Self.waitForDelivery { witnessed.keys == ["b", "d"] }
        #expect(witnessed.keys == ["b", "d"])
        #expect(seen.keys == ["a"], "removed with its view")
    }

    /// The sidebar's monitor sees ⌥⌘↑ ⌥⌘↓ at the window, before the window
    /// sends them on to the menus (where the pane menu holds the same keys),
    /// and takes only those: a plain arrow, or one with ⇧ too, goes on.
    @Test func theSidebarsMonitor_takesOptionCommandArrows_andLetsTheRestGoOn() async throws {
        let taken = Seen()
        let passed = Seen()
        let monitor = WindowKeyDownMonitor { event, window in
            let route = SidebarKeyRoute.route(
                for: event,
                keyboard: KeyboardSettings(),
                hasKeyboard: true,
                isComposing: window.isComposingText
            )
            let name = event.charactersIgnoringModifiers.map { $0 == Self.up ? "up" : $0 == Self.down ? "down" : $0 } ?? ""
            let flags = event.modifierFlags.contains(.shift) ? "⇧" : ""
            if case .moveProject = route {
                taken.keys.append(flags + name)
                return true
            }
            passed.keys.append(flags + name)
            return false
        }
        let window = hostedInWindow(monitor.frame(width: 10, height: 10), width: 200, height: 100).window
        defer { window.close() }
        window.orderFront(nil)
        let content = try #require(window.contentView)
        await settle(content) { descendants(of: content).contains { $0 is WindowKeyDownMonitor.HostView } }

        for (keyCode, characters, modifiers) in [
            (UInt16(126), Self.up, NSEvent.ModifierFlags([.command, .option])),
            (125, Self.down, [.command, .option]),
            (126, Self.up, []),
            (126, Self.up, [.command, .option, .shift]),
            (0, "a", [])
        ] {
            let event = try NSEvent.testKeyDown(
                keyCode: keyCode,
                modifiers: modifiers.union(keyCode == 0 ? [] : [.numericPad, .function]),
                characters: characters,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber
            )
            NSApp.postEvent(event, atStart: false)
        }
        await Self.waitForDelivery { passed.keys.last == "a" }

        #expect(taken.keys == ["up", "down"])
        #expect(passed.keys == ["up", "⇧up", "a"])
    }

    private static let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey)).map(Character.init) ?? " ")
    private static let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
}
