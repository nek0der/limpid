// GlobalHotKey.swift
// Limpid — one system-wide hotkey through Carbon's
// `RegisterEventHotKey`, which needs no Accessibility permission.

import Carbon.HIToolbox
import OSLog

private let log = Logger.limpid("hotkey")

/// Owns at most one registered hotkey and calls `onPress` when it fires.
///
/// Carbon delivers the hotkey event through a C handler installed on the
/// application event target. The handler cannot capture context, so it
/// receives this object as an unretained `userData` pointer. That is safe
/// because `deinit` removes the handler before the object goes away.
@MainActor
final class GlobalHotKey {
    /// `'LmQt'`, distinguishing our hotkey events from any other the
    /// process might receive on the same target.
    nonisolated static let signature: OSType = 0x4C6D_5174

    private let onPress: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    isolated deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    /// Replace any current registration with `combination`. Returns the
    /// Carbon status, which the Settings pane shows when it is not
    /// `noErr` — `eventHotKeyExistsErr` (-9878) means another app
    /// already holds the combination.
    @discardableResult
    func register(_ combination: HotKeyCombination) -> OSStatus {
        unregister()
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return handlerStatus }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            log.error("RegisterEventHotKey failed: \(status, privacy: .public)")
        }
        return status
    }

    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &ref
        )
        if status == noErr {
            handlerRef = ref
        } else {
            log.error("InstallEventHandler failed: \(status, privacy: .public)")
        }
        return status
    }

    fileprivate func fire() {
        onPress()
    }
}

/// Non-capturing C handler for `kEventHotKeyPressed`. Handlers on the
/// application event target run on the main thread, inside the main
/// event loop's dispatch, which is what makes `assumeIsolated` sound.
private let globalHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    // A raw pointer is not `Sendable`, so we carry its address into the
    // isolated closure as an integer and rebuild the pointer there.
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    return noErr
}
