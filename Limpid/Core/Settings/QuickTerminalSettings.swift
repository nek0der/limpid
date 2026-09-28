// QuickTerminalSettings.swift
// Limpid — settings for the quick terminal: the global hotkey that
// summons it, where it slides in from, how much of the screen it takes,
// and whether it hides itself when focus leaves it.

import Foundation

/// Screen edge the quick terminal slides in from, or `center` for a
/// panel that fades in over the middle of the screen.
enum QuickTerminalPosition: String, Codable, CaseIterable {
    case top
    case bottom
    case left
    case right
    case center

    /// A raw value from a newer build falls back to the default instead of
    /// failing the whole settings decode.
    static let unknownFallback: QuickTerminalPosition = .top

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QuickTerminalPosition(rawValue: raw) ?? .unknownFallback
    }
}

struct QuickTerminalSettings: Codable, Equatable {
    static let defaultSizePercent = 50
    static let sizePercentRange: ClosedRange<Int> = 30...90
    static let sizePercentStep = 10
    /// Every size the Settings picker offers.
    static let allowedSizePercents = Array(stride(
        from: sizePercentRange.lowerBound,
        through: sizePercentRange.upperBound,
        by: sizePercentStep
    ))

    /// System-wide shortcut that toggles the panel. Unbound by default:
    /// a global hotkey takes the combination away from every other app,
    /// so we never claim one the user did not choose.
    var hotKey: StoredShortcut?

    var position: QuickTerminalPosition = .top

    /// Share of the screen's visible frame along the axis the panel
    /// slides on (height for top / bottom / center, width for left /
    /// right). Always one of `allowedSizePercents`.
    var sizePercent: Int = Self.defaultSizePercent

    /// Hide the panel when it loses keyboard focus.
    var hidesOnFocusLoss = true

    /// See `LimpidSettings.unknownFields`.
    var unknownFields: [String: LimpidJSONValue] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hotKey = try c.decodeIfPresent(StoredShortcut.self, forKey: .hotKey)
        self.position = try c.decodeIfPresent(QuickTerminalPosition.self, forKey: .position) ?? .top
        let rawSize = try c.decodeIfPresent(Int.self, forKey: .sizePercent) ?? Self.defaultSizePercent
        self.sizePercent = Self.normalizedSizePercent(rawSize)
        self.hidesOnFocusLoss = try c.decodeIfPresent(Bool.self, forKey: .hidesOnFocusLoss) ?? true
        self.unknownFields = try CodableSidecar.decodeUnknownFields(
            from: decoder,
            knownKeys: Self.knownKeyStrings
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hotKey, forKey: .hotKey)
        try c.encode(position, forKey: .position)
        try c.encode(sizePercent, forKey: .sizePercent)
        try c.encode(hidesOnFocusLoss, forKey: .hidesOnFocusLoss)
        try CodableSidecar.encodeUnknownFields(unknownFields, to: encoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hotKey, position, sizePercent, hidesOnFocusLoss
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// Clamp a hand-edited size into the allowed range and snap it to the
    /// picker's step, so the Settings picker always has a matching row.
    static func normalizedSizePercent(_ raw: Int) -> Int {
        let clamped = min(max(raw, sizePercentRange.lowerBound), sizePercentRange.upperBound)
        let steps = (Double(clamped - sizePercentRange.lowerBound) / Double(sizePercentStep)).rounded()
        return sizePercentRange.lowerBound + Int(steps) * sizePercentStep
    }

    /// Check a hotkey the recorder captured. `keyboard` supplies the
    /// effective bindings of every `LimpidShortcutAction`: Carbon takes a
    /// registered hotkey before the menu bar sees it, so sharing a
    /// combination would silence that menu item in every window.
    /// `isTakenBySystem` answers whether a shortcut macOS has enabled in
    /// System Settings uses the combination; production passes
    /// `QuickTerminalHotKeyCenter.isTakenBySystem`.
    ///
    /// Ordinary app commands such as ⌘S are not rejected. No list of them
    /// could be complete or right for every user, so we warn about the
    /// likely ones instead (`mayOverlapAppCommands`).
    func validateHotKey(
        _ proposed: StoredShortcut,
        keyboard: KeyboardSettings,
        isTakenBySystem: (StoredShortcut) -> Bool
    ) -> QuickTerminalHotKeyValidation {
        // Option-only and Shift-only global hotkeys are reported to stop
        // firing on macOS 15. We could not reproduce that, but requiring
        // ⌘ or ⌃ costs little and keeps the hotkey clear of text input.
        guard !proposed.modifiers.isDisjoint(with: [.command, .control]) else {
            return .missingPrimaryModifier
        }
        if ReservedShortcuts.triggers.contains(proposed.ghosttyTrigger) {
            return .reserved
        }
        if isTakenBySystem(proposed) {
            return .takenBySystem
        }
        for action in LimpidShortcutAction.allCases where keyboard.shortcut(for: action) == proposed {
            return .conflictsWithMenu(action)
        }
        return .ok
    }
}

extension QuickTerminalSettings {
    /// True when `shortcut` has the shape apps commonly give their own
    /// commands: ⌘ with one key and no other modifier (⌘S, ⌘P), or ⌃ with
    /// one letter (⌃K, ⌃A in text fields and shells). A global hotkey
    /// takes the combination away from those apps, so the pane warns
    /// without blocking. ⌃ with a non-letter key (⌃`) is left out: text
    /// editing and shells rarely bind those.
    static func mayOverlapAppCommands(_ shortcut: StoredShortcut) -> Bool {
        switch shortcut.modifiers {
        case [.command]:
            true
        case [.control]:
            shortcut.key.count == 1 && shortcut.key.first?.isLetter == true
        default:
            false
        }
    }
}

/// Outcome of `QuickTerminalSettings.validateHotKey`.
enum QuickTerminalHotKeyValidation: Equatable {
    case ok
    /// The combination has neither ⌘ nor ⌃.
    case missingPrimaryModifier
    /// Limpid reserves the combination (⌘Q, ⌘1…⌘9, ⌘⌃1…⌘⌃9, ⇧↩).
    case reserved
    /// A system-wide shortcut enabled in System Settings uses the
    /// combination. See `SystemHotKeys`.
    case takenBySystem
    /// A menu shortcut already uses the combination.
    case conflictsWithMenu(LimpidShortcutAction)
}
