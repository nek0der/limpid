// NamedKey.swift
// Limpid — the keys we know by name, and the key codes that produce them

import Carbon.HIToolbox

/// A key that has a name rather than a character: Return, Escape, the
/// arrows, the function keys. Every place that reads a key code for one of
/// these keys goes through this type, so the hardware key codes are written
/// down once. Letters, digits, and punctuation are not here: which key types
/// them depends on the keyboard layout, so a shortcut stores the character
/// the layout types instead.
///
/// The raw values are Ghostty's key names, which is what `StoredShortcut`
/// stores and what we write into keybind lines.
enum NamedKey: String, CaseIterable, Sendable {
    case `return`, tab, space, backspace, escape
    /// Forward delete, the key labeled Delete on an extended keyboard.
    case delete
    case home, end
    case pageUp = "page_up"
    case pageDown = "page_down"
    case left, right, up, down
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    /// The key codes that type this key. Return has two, the main-block key
    /// and the keypad's Enter; the main-block key comes first because it is
    /// the one every keyboard has.
    var keyCodes: [UInt16] {
        let codes: [Int] = switch self {
        case .return: [kVK_Return, kVK_ANSI_KeypadEnter]
        case .tab: [kVK_Tab]
        case .space: [kVK_Space]
        case .backspace: [kVK_Delete]
        case .escape: [kVK_Escape]
        case .delete: [kVK_ForwardDelete]
        case .home: [kVK_Home]
        case .end: [kVK_End]
        case .pageUp: [kVK_PageUp]
        case .pageDown: [kVK_PageDown]
        case .left: [kVK_LeftArrow]
        case .right: [kVK_RightArrow]
        case .up: [kVK_UpArrow]
        case .down: [kVK_DownArrow]
        case .f1: [kVK_F1]
        case .f2: [kVK_F2]
        case .f3: [kVK_F3]
        case .f4: [kVK_F4]
        case .f5: [kVK_F5]
        case .f6: [kVK_F6]
        case .f7: [kVK_F7]
        case .f8: [kVK_F8]
        case .f9: [kVK_F9]
        case .f10: [kVK_F10]
        case .f11: [kVK_F11]
        case .f12: [kVK_F12]
        case .f13: [kVK_F13]
        case .f14: [kVK_F14]
        case .f15: [kVK_F15]
        case .f16: [kVK_F16]
        case .f17: [kVK_F17]
        case .f18: [kVK_F18]
        case .f19: [kVK_F19]
        case .f20: [kVK_F20]
        }
        return codes.map { UInt16($0) }
    }

    /// The key code we send when we type this key ourselves.
    var primaryKeyCode: UInt16 {
        // Every case lists at least one code; the fallback only keeps the
        // accessor total.
        keyCodes.first ?? 0
    }

    /// The number printed on a function key, 1 through 20, or nil for any
    /// other key. We read it from the raw value so the twenty cases are not
    /// listed a second time.
    var functionKeyNumber: Int? {
        guard rawValue.first == "f", let number = Int(rawValue.dropFirst()) else { return nil }
        return number
    }

    var isFunctionKey: Bool {
        functionKeyNumber != nil
    }

    init?(keyCode: UInt16) {
        guard let key = Self.byKeyCode[keyCode] else { return nil }
        self = key
    }

    /// The key a stored shortcut names. `enter` is Ghostty's other name for
    /// Return, and a hand-written config may use it.
    init?(storedName: String) {
        self.init(rawValue: storedName == "enter" ? "return" : storedName)
    }

    private static let byKeyCode: [UInt16: NamedKey] = Dictionary(
        uniqueKeysWithValues: allCases.flatMap { key in key.keyCodes.map { ($0, key) } }
    )
}
