// TmuxKeyTranslatorTests.swift
// Limpid — checks which tmux input a mirror pane's keys and text become, and how a turn's input is batched into commands.

import Foundation
import GhosttyKit
import Testing
@testable import Limpid

/// A key event as libghostty hands it over. `mods` are
/// `ghostty_input_mods_e` bits.
func mirrorKeyEvent(
    _ key: ghostty_input_key_e,
    _ mods: [ghostty_input_mods_e] = [],
    text: String = "",
    unshifted: Character? = nil,
    isAltAlt: Bool = true,
    isComposing: Bool = false
) -> TmuxKeyEvent {
    TmuxKeyEvent(
        key: key,
        mods: mods.reduce(0) { $0 | $1.rawValue },
        text: text,
        unshiftedCodepoint: unshifted?.unicodeScalars.first?.value ?? 0,
        isAltAlt: isAltAlt,
        isComposing: isComposing
    )
}

private let shift = GHOSTTY_MODS_SHIFT
private let ctrl = GHOSTTY_MODS_CTRL
private let alt = GHOSTTY_MODS_ALT
private let command = GHOSTTY_MODS_SUPER

@Suite("tmux key translator")
struct TmuxKeyTranslatorTests {
    private func translate(_ event: TmuxKeyEvent) -> [TmuxInput] {
        TmuxKeyTranslator.inputs(for: event)
    }

    // MARK: - Dropped

    /// Command chords nothing claimed are not typing; an ordinary pane drops
    /// them too (design C1).
    @Test("Command chords send nothing", arguments: [
        mirrorKeyEvent(GHOSTTY_KEY_ENTER, [command]),
        mirrorKeyEvent(GHOSTTY_KEY_A, [command, shift], text: "A", unshifted: "a"),
        mirrorKeyEvent(GHOSTTY_KEY_HOME, [command]),
        mirrorKeyEvent(GHOSTTY_KEY_K, [command, ctrl], text: "k", unshifted: "k")
    ])
    func commandChord_isDropped(event: TmuxKeyEvent) {
        #expect(translate(event).isEmpty)
    }

    @Test("a modifier on its own sends nothing", arguments: [
        GHOSTTY_KEY_SHIFT_LEFT, GHOSTTY_KEY_SHIFT_RIGHT, GHOSTTY_KEY_CONTROL_LEFT, GHOSTTY_KEY_CONTROL_RIGHT,
        GHOSTTY_KEY_ALT_LEFT, GHOSTTY_KEY_ALT_RIGHT, GHOSTTY_KEY_META_LEFT, GHOSTTY_KEY_META_RIGHT,
        GHOSTTY_KEY_CAPS_LOCK, GHOSTTY_KEY_NUM_LOCK, GHOSTTY_KEY_FN
    ])
    func modifierKey_isDropped(key: ghostty_input_key_e) {
        #expect(translate(mirrorKeyEvent(key, [shift, ctrl])).isEmpty)
    }

    @Test("a dead key still composing sends nothing")
    func composing_isDropped() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_E, [alt], text: "´", isAltAlt: false, isComposing: true)).isEmpty)
    }

    @Test(
        "keys tmux has no name for send nothing",
        arguments: [GHOSTTY_KEY_F13, GHOSTTY_KEY_F24, GHOSTTY_KEY_HELP, GHOSTTY_KEY_CONTEXT_MENU]
    )
    func unnamedKey_isDropped(key: ghostty_input_key_e) {
        #expect(translate(mirrorKeyEvent(key)).isEmpty)
        #expect(translate(mirrorKeyEvent(key, [shift])).isEmpty)
    }

    // MARK: - Text

    @Test("plain typing is literal text, whatever the key")
    func plainText_isLiteral() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, text: "a", unshifted: "a")) == [.literal("a")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [shift], text: "A", unshifted: "a")) == [.literal("A")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_SPACE, text: " ", unshifted: " ")) == [.literal(" ")])
        // An input method's commit carries no key at all.
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_UNIDENTIFIED, text: "日本語")) == [.literal("日本語")])
    }

    @Test("Caps Lock and Num Lock change nothing tmux sees")
    func lockModifiers_areIgnored() {
        let caps = GHOSTTY_MODS_CAPS
        let num = GHOSTTY_MODS_NUM
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [caps], text: "A", unshifted: "a")) == [.literal("A")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [caps, ctrl], text: "a", unshifted: "a")) == [.key("C-a")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP, [num])) == [.key("Up")])
    }

    /// Option that types characters is not Alt: the character goes as is.
    @Test("Option as a text modifier types its character")
    func optionAsText_isLiteral() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [alt], text: "å", unshifted: "a", isAltAlt: false)) == [.literal("å")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ARROW_LEFT, [alt], isAltAlt: false)) == [.key("Left")])
    }

    @Test("text entry splits printable runs from control characters")
    func textEntry_splitsControls() {
        #expect(TmuxKeyTranslator.inputs(forText: Array("\n".utf8)) == [.bytes([0x0A])])
        #expect(TmuxKeyTranslator.inputs(forText: Array("ab\r\ncd\u{7F}".utf8)) == [
            .literal("ab"), .bytes([0x0D, 0x0A]), .literal("cd"), .bytes([0x7F])
        ])
        #expect(TmuxKeyTranslator.inputs(forText: [0x66, 0xFF]) == [.bytes([0x66, 0xFF])])
        #expect(TmuxKeyTranslator.inputs(forText: []).isEmpty)
    }

    // MARK: - Chords

    @Test("Control and Alt name the character")
    func chords_nameTheCharacter() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "c", unshifted: "c")) == [.key("C-c")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_X, [alt], text: "x", unshifted: "x")) == [.key("M-x")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_X, [ctrl, alt], text: "x", unshifted: "x")) == [.key("C-M-x")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_SEMICOLON, [ctrl], text: ";", unshifted: ";")) == [.key("C-;")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_SPACE, [ctrl], text: " ", unshifted: " ")) == [.key("C-Space")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_SPACE, [alt], text: " ", unshifted: " ")) == [.key("M-Space")])
    }

    /// `M-S-a` reaches the pane as a lowercase letter, so Shift is folded
    /// into the character instead (design M5 for `C-S-`).
    @Test("Shift is folded into a chord's character")
    func shift_isFoldedIntoTheCharacter() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [alt, shift], text: "A", unshifted: "a")) == [.key("M-A")])
        // Control has one byte for both cases, so Shift goes (design M5).
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [ctrl, shift], text: "A", unshifted: "a")) == [.key("C-a")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [ctrl, shift], unshifted: "a")) == [.key("C-a")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [ctrl, alt, shift], text: "A", unshifted: "a")) == [.key("C-M-a")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_A, [alt, GHOSTTY_MODS_CAPS], text: "A", unshifted: "a")) == [.key("M-A")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_SLASH, [alt, shift], text: "?", unshifted: "/")) == [.key("M-?")])
    }

    /// A layout that does not type ASCII still sends the chord its physical
    /// key means (design M2).
    @Test("a non-ASCII layout falls back to the unshifted, then the physical, character")
    func nonASCIILayout_fallsBack() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "с", unshifted: "c")) == [.key("C-c")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl], text: "с", unshifted: "с")) == [.key("C-c")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl, alt], text: "с", unshifted: "с")) == [.key("C-M-c")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [ctrl, shift], unshifted: "с")) == [.key("C-c")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [alt, shift], unshifted: "с")) == [.key("M-C")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_DIGIT_2, [ctrl], text: "é", unshifted: "é")) == [.key("C-2")])
        // Nothing to name: the character goes, Control does not.
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_INTL_YEN, [ctrl], text: "¥", unshifted: "¥")) == [.literal("¥")])
    }

    @Test("Alt alone keeps a layout's own character")
    func altAlone_keepsNonASCII() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_C, [alt], text: "с", unshifted: "с")) == [.key("M-с")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_DIGIT_2, [alt], text: "é", unshifted: "é")) == [.key("M-é")])
    }

    // MARK: - Named keys

    @Test("named keys carry every modifier tmux can write")
    func namedKeys_carryModifiers() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP)) == [.key("Up")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ARROW_UP, [ctrl, alt, shift])) == [.key("C-M-S-Up")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_F5, [shift])) == [.key("S-F5")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_F12, [ctrl])) == [.key("C-F12")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ENTER)) == [.key("Enter")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ENTER, [shift])) == [.key("S-Enter")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_TAB)) == [.key("Tab")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE)) == [.key("BSpace")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [alt])) == [.key("M-BSpace")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE)) == [.key("Escape")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_PAGE_UP)) == [.key("PPage")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_PAGE_DOWN)) == [.key("NPage")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_INSERT)) == [.key("IC")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_DELETE, [ctrl])) == [.key("C-DC")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_HOME)) == [.key("Home")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_END, [alt], isAltAlt: false)) == [.key("End")])
    }

    /// The names that fail in VT10x are replaced by rule (design M5).
    @Test("modifiers tmux cannot write are removed by rule")
    func unwritableModifiers_areRemoved() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl])) == [.key("C-h")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl, shift])) == [.key("C-h")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_BACKSPACE, [ctrl, alt])) == [.key("C-M-h")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl])) == [.key("Escape")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl, shift])) == [.key("S-Escape")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_ESCAPE, [ctrl, alt])) == [.key("M-Escape")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_TAB, [shift])) == [.key("BTab")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_TAB, [ctrl, shift])) == [.key("C-BTab")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_DIGIT_3, [ctrl, shift], text: "#", unshifted: "3")) == [.literal("#")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_DIGIT_8, [ctrl, alt, shift], text: "*", unshifted: "8")) == [.key("M-*")])
        // Control stays where tmux has a form for it: emacs reads C-_.
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_MINUS, [ctrl, shift], text: "_", unshifted: "-")) == [.key("C-_")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [ctrl], text: "5")) == [.key("KP5")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [shift], text: "5")) == [.key("KP5")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_5, [ctrl, alt], text: "5")) == [.key("M-KP5")])
    }

    /// tmux writes keypad keys for the pane's keypad mode, so they are named
    /// even though the key carries a digit.
    @Test("keypad keys are named, not typed")
    func keypad_isNamed() {
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_0, text: "0")) == [.key("KP0")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_9, text: "9")) == [.key("KP9")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_DECIMAL, text: ".")) == [.key("KP.")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_DIVIDE, text: "/")) == [.key("KP/")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_MULTIPLY, text: "*")) == [.key("KP*")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_SUBTRACT, text: "-")) == [.key("KP-")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_ADD, text: "+")) == [.key("KP+")])
        // Enter, not KPEnter: tmux writes KPEnter as LF where a tab sends CR.
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_ENTER)) == [.key("Enter")])
        #expect(translate(mirrorKeyEvent(GHOSTTY_KEY_NUMPAD_ENTER, [ctrl, shift])) == [.key("C-S-Enter")])
    }
}

@Suite("tmux input batch")
struct TmuxInputBatchTests {
    @Test("consecutive input of one kind for one pane is one command")
    func sameKind_isMerged() {
        var batch = TmuxInputBatch()
        for input in [TmuxInput.key("C-a"), .key("Up"), .literal("ab"), .literal("c"), .bytes([0x0A]), .bytes([0x0D])] {
            batch.append(input, pane: "%1")
        }
        #expect(batch.drain() == [
            "send-keys -t '%1' 'C-a' 'Up'",
            "send-keys -t '%1' -l -- 'abc'",
            "send-keys -t '%1' -H 0a 0d"
        ])
        #expect(batch.isEmpty)
        #expect(batch.drain().isEmpty)
    }

    @Test("order is kept across kinds and panes")
    func order_isKept() {
        var batch = TmuxInputBatch()
        batch.append(.key("a"), pane: "%1")
        batch.append(.literal("x"), pane: "%1")
        batch.append(.key("b"), pane: "%1")
        batch.append(.key("c"), pane: "%2")
        #expect(batch.drain() == [
            "send-keys -t '%1' 'a'",
            "send-keys -t '%1' -l -- 'x'",
            "send-keys -t '%1' 'b'",
            "send-keys -t '%2' 'c'"
        ])
    }

    /// Quoting is what keeps a typed `;` or `#{` from being tmux syntax, and
    /// `--` keeps a leading `-` from being a flag.
    @Test("every argument is quoted for tmux's parser")
    func arguments_areQuoted() {
        var batch = TmuxInputBatch()
        batch.append(.key("M-'"), pane: "%1")
        batch.append(.key("C-;"), pane: "%1")
        batch.append(.literal("-rf it's #{x}; ~"), pane: "%1")
        #expect(batch.drain() == [
            #"send-keys -t '%1' 'M-'\''' 'C-;'"#,
            #"send-keys -t '%1' -l -- '-rf it'\''s #{x}; ~'"#
        ])
    }
}
