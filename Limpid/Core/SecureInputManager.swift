// SecureInputManager.swift
// Limpid — scopes macOS Secure Event Input to the focused password pane.

import AppKit
import Carbon
import GhosttyKit
import OSLog

private let log = Logger.limpid("secure-input")

/// The three state transitions libghostty can request from an apprt.
enum SecureInputMode: Equatable {
    case on
    case off
    case toggle

    init?(_ rawValue: ghostty_action_secure_input_e) {
        switch rawValue {
        case GHOSTTY_SECURE_INPUT_ON:
            self = .on
        case GHOSTTY_SECURE_INPUT_OFF:
            self = .off
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            self = .toggle
        default:
            return nil
        }
    }
}

/// Injectable boundary around the process-wide Carbon API.
@MainActor
struct SecureInputSystemCalls {
    let enable: () -> OSStatus
    let disable: () -> OSStatus

    static let live = SecureInputSystemCalls(
        enable: EnableSecureEventInput,
        disable: DisableSecureEventInput
    )
}

/// Balances the process-wide Secure Event Input API while keeping each
/// libghostty surface's password request independent. A surface only contributes
/// to the desired state while it owns keyboard focus in the key window.
@MainActor
final class SecureInputManager {
    private struct Scope {
        var isFocused: Bool
        let resolveFocus: () -> Bool
    }

    private let notificationCenter: NotificationCenter
    private let systemCalls: SecureInputSystemCalls
    private var observers: [any NSObjectProtocol] = []
    private var scopes: [ObjectIdentifier: Scope] = [:]
    private var isApplicationActive: Bool
    private var isAutomaticEnabled = true
    private(set) var isEnabled = false

    init(
        notificationCenter: NotificationCenter = .default,
        systemCalls: SecureInputSystemCalls = .live,
        isApplicationActive: Bool = NSApplication.shared.isActive
    ) {
        self.notificationCenter = notificationCenter
        self.systemCalls = systemCalls
        self.isApplicationActive = isApplicationActive

        observe(NSApplication.didBecomeActiveNotification) { manager in
            manager.isApplicationActive = true
            manager.refreshFocusAndApply()
        }
        observe(NSApplication.didResignActiveNotification) { manager in
            manager.isApplicationActive = false
            manager.apply()
        }
        observe(NSWindow.didBecomeKeyNotification) { manager in
            manager.refreshFocusAndApply()
        }
        observe(NSWindow.didResignKeyNotification) { manager in
            manager.refreshFocusAndApply()
        }
    }

    isolated deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        if isEnabled {
            _ = systemCalls.disable()
        }
    }

    func set(_ mode: SecureInputMode, for view: SurfaceView) {
        set(
            mode,
            scope: ObjectIdentifier(view),
            isFocused: view.hasSecureInputFocus,
            resolveFocus: { [weak view] in view?.hasSecureInputFocus == true }
        )
    }

    func focusDidChange(for view: SurfaceView, isFocused: Bool) {
        focusDidChange(scope: ObjectIdentifier(view), isFocused: isFocused)
    }

    func remove(_ view: SurfaceView) {
        remove(scope: ObjectIdentifier(view))
    }

    func setAutomaticEnabled(_ isEnabled: Bool) {
        isAutomaticEnabled = isEnabled
        apply()
    }

    func removeAll() {
        scopes.removeAll()
        apply()
    }

    /// Test seam for the state machine without constructing a libghostty view.
    func set(
        _ mode: SecureInputMode,
        scope id: ObjectIdentifier,
        isFocused: Bool,
        resolveFocus: @escaping () -> Bool = { false }
    ) {
        switch mode {
        case .on:
            scopes[id] = Scope(isFocused: isFocused, resolveFocus: resolveFocus)
        case .off:
            scopes.removeValue(forKey: id)
        case .toggle:
            if scopes.removeValue(forKey: id) == nil {
                scopes[id] = Scope(isFocused: isFocused, resolveFocus: resolveFocus)
            }
        }
        apply()
    }

    func focusDidChange(scope id: ObjectIdentifier, isFocused: Bool) {
        guard scopes[id] != nil else { return }
        scopes[id]?.isFocused = isFocused
        apply()
    }

    func remove(scope id: ObjectIdentifier) {
        scopes.removeValue(forKey: id)
        apply()
    }

    private var isRequestedByFocusedSurface: Bool {
        scopes.values.contains(where: \.isFocused)
    }

    private func refreshFocusAndApply() {
        for id in Array(scopes.keys) {
            guard let resolveFocus = scopes[id]?.resolveFocus else { continue }
            scopes[id]?.isFocused = resolveFocus()
        }
        apply()
    }

    private func apply() {
        let desired = isApplicationActive && isAutomaticEnabled && isRequestedByFocusedSurface
        guard desired != isEnabled else { return }

        let status = desired ? systemCalls.enable() : systemCalls.disable()
        guard status == noErr else {
            log.error("Secure Event Input transition failed: \(status, privacy: .public)")
            return
        }
        isEnabled = desired
        log.debug("Secure Event Input enabled=\(desired, privacy: .public)")
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (SecureInputManager) -> Void
    ) {
        let observer = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(observer)
    }
}
