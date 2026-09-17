// TmuxKeyTranslator.swift
// Limpid — keys and text from a mirror surface as tmux `send-keys` input: key names, literal text, raw bytes.

import Foundation
import GhosttyKit

/// A key libghostty handed over for a mirror surface instead of encoding
/// it (`GHOSTTY_ACTION_MIRROR_KEY`), copied out of the callback.
struct TmuxKeyEvent: Equatable {
    let key: ghostty_input_key_e
    /// `ghostty_input_mods_e` bits, sided bits included.
    let mods: UInt32
    let text: String
    let unshiftedCodepoint: UInt32
    /// libghostty's Option-as-Alt decision for this event.
    let isAltAlt: Bool
    let isComposing: Bool
}

/// One piece of `send-keys` input. The three kinds are sent with different
/// flags, so they are kept apart until a command is built.
enum TmuxInput: Equatable {
    /// A tmux key name (`C-a`, `Up`, `S-F5`). tmux encodes it for the modes
    /// the pane really has: cursor keys, keypad, extended keys, copy mode.
    case key(String)
    /// Printable text, sent with `-l`, which tmux writes as is in every mode.
    case literal(String)
    /// Bytes sent with `-H`, for control characters that `-l` cannot carry
    /// on a one-line command.
    case bytes([UInt8])
}

/// Turns what the user typed into the input a normal tmux client would give
/// tmux. We name keys rather than encode them because only tmux knows the
/// pane's modes; a copy of them cannot be recovered after the fact (kitty
/// flags, modifyOtherKeys, output dropped while a pane was paused), and a
/// raw arrow sequence ends copy mode where the name `Up` moves within it.
///
/// Every rule below that removes a modifier was measured on tmux 3.7c: a
/// name tmux cannot write for a pane in VT10x mode is typed into the pane
/// as its own text (`C-BSpace`, `C-Escape` and anything built on them),
/// and a keypad name with `C-` or `S-` writes nothing at all. The
/// real-tmux tests pin these outcomes.
enum TmuxKeyTranslator {
    private static let shift: UInt32 = GHOSTTY_MODS_SHIFT.rawValue
    private static let ctrl: UInt32 = GHOSTTY_MODS_CTRL.rawValue
    private static let alt: UInt32 = GHOSTTY_MODS_ALT.rawValue
    private static let superKey: UInt32 = GHOSTTY_MODS_SUPER.rawValue

    static func inputs(for event: TmuxKeyEvent) -> [TmuxInput] {
        // A dead key in progress belongs to the input method; the composed
        // character arrives later as text.
        guard !event.isComposing else { return [] }
        // Command combinations that no binding claimed are not terminal
        // input on macOS; libghostty's legacy encoder drops them too.
        guard event.mods & superKey == 0 else { return [] }
        guard !modifierKeys.contains(event.key) else { return [] }

        let hasShift = event.mods & shift != 0
        let hasCtrl = event.mods & ctrl != 0
        let hasAlt = event.mods & alt != 0 && event.isAltAlt

        if let name = namedKeys[event.key] {
            return namedKey(name, key: event.key, hasShift: hasShift, hasCtrl: hasCtrl, hasAlt: hasAlt)
        }
        guard hasCtrl || hasAlt else {
            return text(event.text)
        }
        // Alt alone takes any single character (`M-é` writes ESC é), which
        // is what libghostty writes for a layout's own character too.
        if !hasCtrl, let scalar = singleScalar(event.text), scalar.value > 0x7F {
            return [.key("M-" + String(scalar))]
        }
        guard let base = baseCharacter(event, hasShift: hasShift, hasCtrl: hasCtrl) else {
            // Nothing tmux can name. tmux itself types such a character and
            // drops the modifier, so we do the same rather than lose the key.
            return text(event.text)
        }
        if hasCtrl, controlless.contains(base) {
            return hasAlt ? [.key("M-" + base)] : [.literal(base)]
        }
        return [.key(prefix(ctrl: hasCtrl, alt: hasAlt, shift: false) + base)]
    }

    /// Text from a `text:` binding or the surface's text entry point.
    /// Invalid UTF-8 goes out as bytes, which tmux writes unchanged too.
    static func inputs(forText bytes: [UInt8]) -> [TmuxInput] {
        guard let decoded = String(validating: bytes, as: UTF8.self) else {
            return bytes.isEmpty ? [] : [.bytes(bytes)]
        }
        return text(decoded)
    }

    // MARK: - Named keys

    private static func namedKey(
        _ name: String,
        key: ghostty_input_key_e,
        hasShift: Bool,
        hasCtrl: Bool,
        hasAlt: Bool
    ) -> [TmuxInput] {
        switch key {
        case GHOSTTY_KEY_TAB where hasShift:
            // Shift-Tab is its own key to tmux; `S-Tab` writes a plain tab.
            return [.key(prefix(ctrl: hasCtrl, alt: hasAlt, shift: false) + "BTab")]
        case GHOSTTY_KEY_BACKSPACE where hasCtrl:
            // `C-BSpace` fails in VT10x. libghostty sends ^H for it, which
            // is `C-h`; Shift adds nothing there.
            return [.key(prefix(ctrl: true, alt: hasAlt, shift: false) + "h")]
        case GHOSTTY_KEY_ESCAPE where hasCtrl:
            // `C-Escape` fails in VT10x and has no control-byte form.
            return [.key(prefix(ctrl: false, alt: hasAlt, shift: hasShift) + name)]
        default:
            break
        }
        if keypadKeys.contains(key) {
            // A keypad name with `C-` or `S-` writes nothing.
            return [.key(prefix(ctrl: false, alt: hasAlt, shift: false) + name)]
        }
        return [.key(prefix(ctrl: hasCtrl, alt: hasAlt, shift: hasShift) + name)]
    }

    /// tmux accepts the modifiers in this order and in any other.
    private static func prefix(ctrl: Bool, alt: Bool, shift: Bool) -> String {
        (ctrl ? "C-" : "") + (alt ? "M-" : "") + (shift ? "S-" : "")
    }

    // MARK: - Characters

    /// The character a Control or Alt chord names. With Alt alone, Shift is
    /// folded into it (`M-A`, not `M-S-a`, which tmux sends as a lowercase
    /// letter). With Control a letter is named in lowercase: VT10x has one
    /// control byte for both cases, so Shift is dropped (`C-S-a` is `C-a`).
    /// It has to be ASCII for Control to mean anything: a layout that types
    /// something else falls back to the key's unshifted character, and then
    /// to the US character of the physical key.
    private static func baseCharacter(_ event: TmuxKeyEvent, hasShift: Bool, hasCtrl: Bool) -> String? {
        if let scalar = singleScalar(event.text), isNameable(scalar) {
            return keyName(hasCtrl ? lowercased(scalar) : scalar)
        }
        let fallback = Unicode.Scalar(event.unshiftedCodepoint).flatMap { isNameable($0) ? $0 : nil }
            ?? physicalCharacters[event.key].flatMap(Unicode.Scalar.init)
        guard var scalar = fallback else { return nil }
        if hasShift, !hasCtrl, scalar.properties.isLowercase,
           let upper = scalar.properties.uppercaseMapping.unicodeScalars.first
        {
            scalar = upper
        }
        return keyName(scalar)
    }

    /// ASCII letters only; every other nameable character has no case.
    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard ("A"..."Z").contains(scalar) else { return scalar }
        return Unicode.Scalar(scalar.value + 0x20) ?? scalar
    }

    private static func isNameable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value < 0x7F
    }

    /// A space has to be named; every other printable ASCII character is
    /// its own name once quoted.
    private static func keyName(_ scalar: Unicode.Scalar) -> String {
        scalar == " " ? "Space" : String(scalar)
    }

    private static func singleScalar(_ text: String) -> Unicode.Scalar? {
        let scalars = text.unicodeScalars
        guard let first = scalars.first, scalars.count == 1 else { return nil }
        return first
    }

    /// Printable runs as literals, control characters as bytes, in order.
    private static func text(_ text: String) -> [TmuxInput] {
        var result: [TmuxInput] = []
        var run = ""
        var controls: [UInt8] = []
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                if !run.isEmpty {
                    result.append(.literal(run))
                    run = ""
                }
                controls.append(UInt8(scalar.value))
            } else {
                if !controls.isEmpty {
                    result.append(.bytes(controls))
                    controls = []
                }
                run.unicodeScalars.append(scalar)
            }
        }
        if !run.isEmpty {
            result.append(.literal(run))
        }
        if !controls.isEmpty {
            result.append(.bytes(controls))
        }
        return result
    }

    // MARK: - Tables

    /// Characters tmux has no Control form for in VT10x: no control byte
    /// and no unshifted stand-in (it writes `C-!` as `1`, but `C-#` as the
    /// text "C-#"). Control is dropped on them. Measured on tmux 3.7c over
    /// every printable ASCII character; the real-tmux tests keep it so.
    private static let controlless: Set<String> = ["#", "$", "%", "&", "*"]

    private static let modifierKeys: Set<ghostty_input_key_e> = [
        GHOSTTY_KEY_SHIFT_LEFT, GHOSTTY_KEY_SHIFT_RIGHT,
        GHOSTTY_KEY_CONTROL_LEFT, GHOSTTY_KEY_CONTROL_RIGHT,
        GHOSTTY_KEY_ALT_LEFT, GHOSTTY_KEY_ALT_RIGHT,
        GHOSTTY_KEY_META_LEFT, GHOSTTY_KEY_META_RIGHT,
        GHOSTTY_KEY_CAPS_LOCK, GHOSTTY_KEY_NUM_LOCK, GHOSTTY_KEY_FN
    ]

    /// Keys tmux knows by name. F13 and above, Help, and the context-menu
    /// key have no tmux name and fall through to text, which they do not
    /// carry, so they send nothing.
    private static let namedKeys: [ghostty_input_key_e: String] = {
        var names: [ghostty_input_key_e: String] = [
            GHOSTTY_KEY_ENTER: "Enter",
            GHOSTTY_KEY_TAB: "Tab",
            GHOSTTY_KEY_BACKSPACE: "BSpace",
            GHOSTTY_KEY_ESCAPE: "Escape",
            GHOSTTY_KEY_ARROW_UP: "Up",
            GHOSTTY_KEY_ARROW_DOWN: "Down",
            GHOSTTY_KEY_ARROW_LEFT: "Left",
            GHOSTTY_KEY_ARROW_RIGHT: "Right",
            GHOSTTY_KEY_HOME: "Home",
            GHOSTTY_KEY_END: "End",
            GHOSTTY_KEY_PAGE_UP: "PPage",
            GHOSTTY_KEY_PAGE_DOWN: "NPage",
            GHOSTTY_KEY_INSERT: "IC",
            GHOSTTY_KEY_DELETE: "DC",
            GHOSTTY_KEY_NUMPAD_UP: "Up",
            GHOSTTY_KEY_NUMPAD_DOWN: "Down",
            GHOSTTY_KEY_NUMPAD_LEFT: "Left",
            GHOSTTY_KEY_NUMPAD_RIGHT: "Right",
            GHOSTTY_KEY_NUMPAD_HOME: "Home",
            GHOSTTY_KEY_NUMPAD_END: "End",
            GHOSTTY_KEY_NUMPAD_PAGE_UP: "PPage",
            GHOSTTY_KEY_NUMPAD_PAGE_DOWN: "NPage",
            GHOSTTY_KEY_NUMPAD_INSERT: "IC",
            GHOSTTY_KEY_NUMPAD_DELETE: "DC",
            // tmux writes `KPEnter` as LF outside application keypad mode,
            // where an ordinary tab sends CR; Claude Code reads LF as a
            // newline, not a submit. `Enter` keeps the ordinary tab's byte.
            GHOSTTY_KEY_NUMPAD_ENTER: "Enter"
        ]
        let functionKeys: [ghostty_input_key_e] = [
            GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4,
            GHOSTTY_KEY_F5, GHOSTTY_KEY_F6, GHOSTTY_KEY_F7, GHOSTTY_KEY_F8,
            GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12
        ]
        for (index, key) in functionKeys.enumerated() {
            names[key] = "F\(index + 1)"
        }
        for (key, name) in keypadNames {
            names[key] = name
        }
        return names
    }()

    /// The keypad keys tmux names. tmux writes them for the pane's keypad
    /// mode, so the digits keep their application form (`ESC O u`).
    private static let keypadNames: [ghostty_input_key_e: String] = {
        let digits: [ghostty_input_key_e] = [
            GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2, GHOSTTY_KEY_NUMPAD_3,
            GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6, GHOSTTY_KEY_NUMPAD_7,
            GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9
        ]
        var names: [ghostty_input_key_e: String] = [
            GHOSTTY_KEY_NUMPAD_DECIMAL: "KP.",
            GHOSTTY_KEY_NUMPAD_DIVIDE: "KP/",
            GHOSTTY_KEY_NUMPAD_MULTIPLY: "KP*",
            GHOSTTY_KEY_NUMPAD_SUBTRACT: "KP-",
            GHOSTTY_KEY_NUMPAD_ADD: "KP+"
        ]
        for (index, key) in digits.enumerated() {
            names[key] = "KP\(index)"
        }
        return names
    }()

    private static let keypadKeys = Set(keypadNames.keys)

    /// The US character of each writing-system key, for chords on a layout
    /// whose own characters are not ASCII (design M2).
    private static let physicalCharacters: [ghostty_input_key_e: UInt32] = {
        var characters: [ghostty_input_key_e: UInt32] = [
            GHOSTTY_KEY_BACKQUOTE: 0x60, GHOSTTY_KEY_BACKSLASH: 0x5C,
            GHOSTTY_KEY_BRACKET_LEFT: 0x5B, GHOSTTY_KEY_BRACKET_RIGHT: 0x5D,
            GHOSTTY_KEY_COMMA: 0x2C, GHOSTTY_KEY_EQUAL: 0x3D, GHOSTTY_KEY_MINUS: 0x2D,
            GHOSTTY_KEY_PERIOD: 0x2E, GHOSTTY_KEY_QUOTE: 0x27, GHOSTTY_KEY_SEMICOLON: 0x3B,
            GHOSTTY_KEY_SLASH: 0x2F, GHOSTTY_KEY_SPACE: 0x20
        ]
        let letters: [ghostty_input_key_e] = [
            GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E, GHOSTTY_KEY_F,
            GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
            GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R,
            GHOSTTY_KEY_S, GHOSTTY_KEY_T, GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
            GHOSTTY_KEY_Y, GHOSTTY_KEY_Z
        ]
        for (index, key) in letters.enumerated() {
            characters[key] = 0x61 + UInt32(index)
        }
        let digits: [ghostty_input_key_e] = [
            GHOSTTY_KEY_DIGIT_0, GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3,
            GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7,
            GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9
        ]
        for (index, key) in digits.enumerated() {
            characters[key] = 0x30 + UInt32(index)
        }
        return characters
    }()
}

/// Consecutive input for one pane collected into as few `send-keys`
/// commands as the kinds allow, in order. One keystroke per command is the
/// lag WezTerm users report over control mode, so a main-actor turn's input
/// goes out together (design m4).
struct TmuxInputBatch {
    private enum Run {
        case keys([String])
        case literal(String)
        case bytes([UInt8])
    }

    private var runs: [(pane: String, run: Run)] = []

    var isEmpty: Bool {
        runs.isEmpty
    }

    mutating func append(_ input: TmuxInput, pane: String) {
        let run: Run = switch input {
        case let .key(name): .keys([name])
        case let .literal(text): .literal(text)
        case let .bytes(bytes): .bytes(bytes)
        }
        if let last = runs.last, last.pane == pane, let merged = Self.merge(last.run, run) {
            runs[runs.count - 1].run = merged
        } else {
            runs.append((pane, run))
        }
    }

    private static func merge(_ first: Run, _ second: Run) -> Run? {
        switch (first, second) {
        case let (.keys(previous), .keys(next)): .keys(previous + next)
        case let (.literal(previous), .literal(next)): .literal(previous + next)
        case let (.bytes(previous), .bytes(next)): .bytes(previous + next)
        default: nil
        }
    }

    /// The commands, leaving the batch empty. Every argument is quoted, so
    /// no key name or text reaches tmux's parser as syntax (`;`, `#{`,
    /// `~`), and `--` keeps a literal that starts with `-` from reading as
    /// a flag.
    mutating func drain() -> [String] {
        defer { runs = [] }
        return runs.map { pane, run in
            let command = "send-keys -t \(TmuxProtocol.quote(pane))"
            switch run {
            case let .keys(names):
                return "\(command) \(names.map(TmuxProtocol.quote).joined(separator: " "))"
            case let .literal(text):
                return "\(command) -l -- \(TmuxProtocol.quote(text))"
            case let .bytes(bytes):
                return "\(command) -H \(TmuxProtocol.hexKeyArguments(Data(bytes)))"
            }
        }
    }
}
