// SecureInputManagerTests.swift
// Limpid — verifies scoped and lifecycle-safe Secure Event Input transitions.

import AppKit
import GhosttyKit
import Testing
@testable import Limpid

@MainActor
struct SecureInputManagerTests {
    @Test func modeDecodesEveryLibghosttyTransition() {
        #expect(SecureInputMode(GHOSTTY_SECURE_INPUT_ON) == .on)
        #expect(SecureInputMode(GHOSTTY_SECURE_INPUT_OFF) == .off)
        #expect(SecureInputMode(GHOSTTY_SECURE_INPUT_TOGGLE) == .toggle)
    }

    @Test func focusedRequestEnablesAndOffDisables() {
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls)
        let scope = NSObject()

        manager.set(.on, scope: ObjectIdentifier(scope), isFocused: true)
        #expect(manager.isEnabled)
        #expect(calls.enableCount == 1)

        manager.set(.off, scope: ObjectIdentifier(scope), isFocused: true)
        #expect(!manager.isEnabled)
        #expect(calls.disableCount == 1)
    }

    @Test func requestOnlyAppliesWhileItsSurfaceIsFocused() {
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls)
        let scope = NSObject()
        let id = ObjectIdentifier(scope)

        manager.set(.on, scope: id, isFocused: false)
        #expect(!manager.isEnabled)

        manager.focusDidChange(scope: id, isFocused: true)
        #expect(manager.isEnabled)
        manager.focusDidChange(scope: id, isFocused: false)
        #expect(!manager.isEnabled)
        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 1)
    }

    @Test func anotherFocusedRequestPreventsEarlyDisable() {
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls)
        let first = NSObject()
        let second = NSObject()

        manager.set(.on, scope: ObjectIdentifier(first), isFocused: true)
        manager.set(.on, scope: ObjectIdentifier(second), isFocused: true)
        manager.remove(scope: ObjectIdentifier(first))

        #expect(manager.isEnabled)
        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 0)

        manager.remove(scope: ObjectIdentifier(second))
        #expect(!manager.isEnabled)
        #expect(calls.disableCount == 1)
    }

    @Test func appDeactivationYieldsAndActivationReacquires() {
        let center = NotificationCenter()
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls, notificationCenter: center)
        let scope = NSObject()

        manager.set(.on, scope: ObjectIdentifier(scope), isFocused: true, resolveFocus: { true })
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!manager.isEnabled)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(manager.isEnabled)
        #expect(calls.enableCount == 2)
        #expect(calls.disableCount == 1)
    }

    @Test func keyWindowChangeRefreshesSurfaceFocus() {
        let center = NotificationCenter()
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls, notificationCenter: center)
        let scope = NSObject()
        var isFocused = true

        manager.set(
            .on,
            scope: ObjectIdentifier(scope),
            isFocused: true,
            resolveFocus: { isFocused }
        )
        isFocused = false
        center.post(name: NSWindow.didResignKeyNotification, object: nil)

        #expect(!manager.isEnabled)
        #expect(calls.disableCount == 1)
    }

    @Test func failedTransitionDoesNotCorruptAppliedStateAndRetries() {
        let calls = RecordingSecureInputCalls()
        calls.enableStatuses = [-1, noErr]
        let manager = makeManager(calls: calls)
        let scope = NSObject()
        let id = ObjectIdentifier(scope)

        manager.set(.on, scope: id, isFocused: true)
        #expect(!manager.isEnabled)
        manager.set(.on, scope: id, isFocused: true)

        #expect(manager.isEnabled)
        #expect(calls.enableCount == 2)
    }

    @Test func automaticOptOutYieldsWithoutDiscardingPromptState() {
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls)
        let scope = NSObject()

        manager.set(.on, scope: ObjectIdentifier(scope), isFocused: true)
        manager.setAutomaticEnabled(false)
        #expect(!manager.isEnabled)

        manager.setAutomaticEnabled(true)
        #expect(manager.isEnabled)
        #expect(calls.enableCount == 2)
        #expect(calls.disableCount == 1)
    }

    @Test func removingAllScopesBalancesAnActiveEnable() {
        let calls = RecordingSecureInputCalls()
        let manager = makeManager(calls: calls)
        let scope = NSObject()

        manager.set(.on, scope: ObjectIdentifier(scope), isFocused: true)
        manager.removeAll()

        #expect(!manager.isEnabled)
        #expect(calls.enableCount == 1)
        #expect(calls.disableCount == 1)
    }

    private func makeManager(
        calls: RecordingSecureInputCalls,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> SecureInputManager {
        SecureInputManager(
            notificationCenter: notificationCenter,
            systemCalls: SecureInputSystemCalls(
                enable: { calls.enable() },
                disable: { calls.disable() }
            ),
            isApplicationActive: true
        )
    }
}

@MainActor
private final class RecordingSecureInputCalls {
    var enableStatuses: [OSStatus] = []
    var disableStatuses: [OSStatus] = []
    private(set) var enableCount = 0
    private(set) var disableCount = 0

    func enable() -> OSStatus {
        defer { enableCount += 1 }
        return enableStatuses.isEmpty ? noErr : enableStatuses.removeFirst()
    }

    func disable() -> OSStatus {
        defer { disableCount += 1 }
        return disableStatuses.isEmpty ? noErr : disableStatuses.removeFirst()
    }
}
