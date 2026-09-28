// QuickTerminalHotKeyCenter.swift
// Limpid — keeps the quick terminal's global hotkey registered to match
// the setting, the keyboard layout, and the recorder.

import AppKit
import Carbon.HIToolbox
import Observation

/// Why the configured hotkey is not active. Shown under the recorder.
enum QuickTerminalHotKeyProblem: Equatable {
    /// libghostty failed to start, so there is no terminal to summon.
    case terminalUnavailable
    /// No key on the current keyboard layout types the stored key.
    case keyNotOnLayout
    /// `RegisterEventHotKey` refused the combination.
    case registrationFailed(OSStatus)
    /// A menu shortcut uses the same combination. The recorders reject
    /// this, but resetting a menu shortcut to its default can still land
    /// on the hotkey; the menu item keeps working and the hotkey stays off.
    case conflictsWithMenu(LimpidShortcutAction)
    /// A system-wide shortcut enabled in System Settings uses the same
    /// combination. The recorder rejects this, but the user can add or
    /// re-enable a system shortcut after saving the hotkey. Registering
    /// anyway would leave one of the two firing and the other silent.
    case takenBySystem

    /// Carbon's status for a combination another app already holds.
    static let alreadyTakenStatus = OSStatus(eventHotKeyExistsErr)
}

@MainActor
@Observable
final class QuickTerminalHotKeyCenter {
    /// Set when the configured hotkey could not be registered. `nil` while
    /// the hotkey is registered, unbound, or suspended for the recorder.
    private(set) var problem: QuickTerminalHotKeyProblem?

    /// One recorder's hold on the hotkey, returned by `suspend()`.
    struct Suspension: Hashable {
        fileprivate let id: UUID
    }

    /// Holds of the recorders that are capturing. Each recorder owns its
    /// own token rather than toggling a shared flag, so one recorder
    /// stopping cannot re-register the hotkey while another still needs
    /// the keystroke, and releasing the same token twice is harmless.
    private var suspensions: Set<Suspension> = []

    /// True while any Settings recorder is capturing. The hotkey is
    /// unregistered meanwhile: Carbon takes a registered hotkey before
    /// the app sees the keyDown, so pressing the current combination
    /// would toggle the panel instead of reaching the recorder.
    var isSuspended: Bool {
        !suspensions.isEmpty
    }

    @ObservationIgnored private let hotKeyProvider: @MainActor () -> StoredShortcut?
    @ObservationIgnored private let menuShortcutsProvider: @MainActor () -> KeyboardSettings?
    @ObservationIgnored private let isTerminalAvailable: Bool
    @ObservationIgnored private let layoutTranslator: @MainActor () -> ((UInt16) -> String?)?
    /// Read on every `apply()`, so a system shortcut added since the last
    /// one is noticed on the next settings change, layout switch, or
    /// recorder release. Carbon posts no notification for System Settings
    /// changes, and we do not poll for them.
    @ObservationIgnored private let systemHotKeysProvider: @MainActor () -> Set<HotKeyCombination>
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// What `hotKey` is registered with, so an unrelated settings write
    /// (the observation fires for any of them) does not re-register it.
    @ObservationIgnored private var registeredCombination: HotKeyCombination?
    @ObservationIgnored private let onPress: @MainActor () -> Void
    /// Registered once in `start()`; removed in `deinit`. `nonisolated(unsafe)`
    /// only so the deinit can hand it back to `DistributedNotificationCenter`;
    /// it is written once on the main actor before any deinit can run.
    @ObservationIgnored private nonisolated(unsafe) var inputSourceObserver: (any NSObjectProtocol)?

    init(
        isTerminalAvailable: Bool,
        hotKeyProvider: @escaping @MainActor () -> StoredShortcut?,
        menuShortcutsProvider: @escaping @MainActor () -> KeyboardSettings? = { nil },
        layoutTranslator: @escaping @MainActor () -> ((UInt16) -> String?)? = {
            StoredShortcut.currentLayoutTranslator()
        },
        systemHotKeysProvider: @escaping @MainActor () -> Set<HotKeyCombination> = {
            SystemHotKeys.current()
        },
        onPress: @escaping @MainActor () -> Void
    ) {
        self.isTerminalAvailable = isTerminalAvailable
        self.hotKeyProvider = hotKeyProvider
        self.menuShortcutsProvider = menuShortcutsProvider
        self.layoutTranslator = layoutTranslator
        self.systemHotKeysProvider = systemHotKeysProvider
        self.onPress = onPress
    }

    deinit {
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
    }

    /// Register the current setting and follow later changes to it and to
    /// the keyboard layout.
    func start() {
        observeRepeatedly { [weak self] in
            _ = self?.hotKeyProvider()
            _ = self?.menuShortcutsProvider()
        } onChange: { [weak self] in
            self?.apply()
        }
        // Letters and punctuation are stored as the character the layout
        // types, so switching layouts can move them to another keyCode.
        // We listen for the system-wide input source change rather than
        // `NSTextInputContext.keyboardSelectionDidChangeNotification`: that
        // one comes from our own text input contexts, so we cannot count
        // on it while another app is frontmost, which is when the hotkey
        // matters most. The system-wide one also fires for switches made
        // inside Limpid, so observing both would only apply twice.
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply()
            }
        }
        apply()
    }

    /// Unregister the hotkey until the returned token is passed to
    /// `resume(_:)`. Recorders call this when they start capturing.
    func suspend() -> Suspension {
        let suspension = Suspension(id: UUID())
        let wasSuspended = isSuspended
        suspensions.insert(suspension)
        if !wasSuspended {
            apply()
        }
        return suspension
    }

    /// Release `suspension`. The hotkey comes back once no recorder holds
    /// a suspension; an already released token is ignored.
    func resume(_ suspension: Suspension) {
        guard suspensions.remove(suspension) != nil, !isSuspended else { return }
        apply()
    }

    func apply() {
        guard isTerminalAvailable else {
            unregister()
            problem = hotKeyProvider() == nil ? nil : .terminalUnavailable
            return
        }
        guard !isSuspended, let shortcut = hotKeyProvider() else {
            unregister()
            problem = nil
            return
        }
        if let keyboard = menuShortcutsProvider(),
           let action = LimpidShortcutAction.allCases.first(where: { keyboard.shortcut(for: $0) == shortcut })
        {
            unregister()
            problem = .conflictsWithMenu(action)
            return
        }
        // Named keys resolve without a layout, so an input source with no
        // Unicode layout data only fails letters and punctuation.
        let translate = layoutTranslator() ?? { _ in nil }
        guard let combination = HotKeyMapping.combination(for: shortcut, translate: translate) else {
            unregister()
            problem = .keyNotOnLayout
            return
        }
        // Checked before the already-registered shortcut below, so a
        // system shortcut added since we registered turns the hotkey off.
        if systemHotKeysProvider().contains(combination) {
            unregister()
            problem = .takenBySystem
            return
        }
        if combination == registeredCombination, hotKey?.isRegistered == true {
            return
        }
        let hotKey = hotKey ?? GlobalHotKey { [weak self] in
            self?.onPress()
        }
        self.hotKey = hotKey
        let status = hotKey.register(combination)
        registeredCombination = status == noErr ? combination : nil
        problem = status == noErr ? nil : .registrationFailed(status)
    }

    /// Whether a shortcut macOS has enabled in System Settings uses
    /// `shortcut`, read through the same providers `apply()` uses. The
    /// recorder asks per keystroke rather than once per recording: the
    /// user may have System Settings open beside the pane.
    func isTakenBySystem(_ shortcut: StoredShortcut) -> Bool {
        let translate = layoutTranslator() ?? { _ in nil }
        return SystemHotKeys.contains(shortcut, in: systemHotKeysProvider(), translate: translate)
    }

    private func unregister() {
        hotKey?.unregister()
        registeredCombination = nil
    }
}
