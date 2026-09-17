// TmuxScreenRestoreTests.swift
// Limpid — pins the display-message state format and the order of the screen-restore byte sequence.

import Foundation
import Testing
@testable import Limpid

@Suite("tmux screen restore")
struct TmuxScreenRestoreTests {
    @Test("the state line is fifteen integers in the format's field order")
    func parseState_readsEveryField() throws {
        let state = try #require(TmuxScreenRestore.parseState("3 7 1 1 0 1 0 1 0 0 0 0 0 29 0"))
        #expect(state.cursorX == 3)
        #expect(state.cursorY == 7)
        #expect(state.isAlternateScreen)
        #expect(state.isCursorVisible)
        #expect(!state.isInsertMode)
        #expect(state.isCursorKeysApplication)
        #expect(!state.isKeypadApplication)
        #expect(state.isAutoWrap)
        #expect(!state.isMouseButton && !state.isMouseStandard && !state.isMouseAll && !state.isMouseSGR)
        #expect(state.scrollRegionTop == 0)
        #expect(state.scrollRegionBottom == 29)
        #expect(!state.isInCopyMode)
        // The order `parseState` reads the fields in, spelled out: a count
        // alone would pass with two fields swapped.
        #expect(TmuxScreenRestore.stateFormat == [
            "#{cursor_x}", "#{cursor_y}", "#{alternate_on}", "#{cursor_flag}", "#{insert_flag}",
            "#{keypad_cursor_flag}", "#{keypad_flag}", "#{wrap_flag}",
            "#{mouse_button_flag}", "#{mouse_standard_flag}", "#{mouse_all_flag}", "#{mouse_sgr_flag}",
            "#{scroll_region_upper}", "#{scroll_region_lower}", "#{pane_in_mode}"
        ].joined(separator: " "))
    }

    @Test("a state line with the wrong field count is rejected")
    func parseState_rejectsWrongArity() {
        #expect(TmuxScreenRestore.parseState("3 7 1") == nil)
        #expect(TmuxScreenRestore.parseState("") == nil)
        #expect(TmuxScreenRestore.parseState("a b c d e f g h i j k l m n o") == nil)
    }

    @Test("a plain screen resets attributes, paints the rows, sets modes, and places the cursor last")
    func sequence_plainScreen() throws {
        let bytes = TmuxScreenRestore.sequence(rows: ["first", "second"], rowCount: 2, state: TmuxScreenState())
        let text = try #require(String(bytes: bytes, encoding: .utf8))

        #expect(text.hasPrefix("\u{1b}[?1049l\u{1b}[m\u{1b}[4l\u{1b}[?6l\u{1b}[r\u{1b}[H\u{1b}[J"))
        #expect(text.contains("first\r\nsecond"))
        #expect(!text.contains("\u{1b}[?1049h"))
        #expect(text.firstMatch(of: /\e\[\d+;\d+r/) == nil, "no scroll region for a full-height default")
        #expect(text.hasSuffix("\u{1b}[1;1H"))
    }

    @Test("the alternate screen is entered first and a narrower scroll region is set before the cursor")
    func sequence_alternateScreenWithRegion() throws {
        var state = TmuxScreenState()
        state.isAlternateScreen = true
        state.scrollRegionTop = 0
        state.scrollRegionBottom = 10
        state.cursorX = 3
        state.cursorY = 7
        state.isCursorKeysApplication = true
        state.isMouseSGR = true
        state.isMouseButton = true

        let text = try #require(String(bytes: TmuxScreenRestore.sequence(rows: [], rowCount: 30, state: state), encoding: .utf8))

        #expect(text.hasPrefix("\u{1b}[?1049h"))
        #expect(text.contains("\u{1b}[?1h"))
        #expect(text.contains("\u{1b}[?1002h"))
        #expect(text.contains("\u{1b}[?1006h"))
        let region = try #require(text.range(of: "\u{1b}[1;11r"))
        let cursor = try #require(text.range(of: "\u{1b}[8;4H"))
        #expect(region.lowerBound < cursor.lowerBound)
        #expect(text.hasSuffix("\u{1b}[8;4H"))
    }

    @Test("a pane with only standard mouse tracking gets ?1000h and never the any-motion mode")
    func sequence_standardMouseOnly_doesNotEnableAnyMotion() throws {
        // The flags tmux 3.7c reports after `printf '\033[?1000h'`, in format
        // order: button, standard, all, SGR.
        let state = try #require(TmuxScreenRestore.parseState("0 0 0 1 0 0 0 1 0 1 0 0 0 23 0"))
        #expect(state.isMouseStandard)

        let text = try #require(String(bytes: TmuxScreenRestore.sequence(rows: [], rowCount: 24, state: state), encoding: .utf8))

        #expect(text.contains("\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1000h\u{1b}[?1006l"))
        #expect(!text.contains("\u{1b}[?1002h"))
        #expect(!text.contains("\u{1b}[?1003h"))
    }

    @Test("a repaint never clears with ED 2 and never sets a scroll region spanning the whole pane")
    func sequence_fullHeightRegion_isNotSet() throws {
        var state = TmuxScreenState()
        state.scrollRegionTop = 0
        state.scrollRegionBottom = 23
        state.cursorX = 5
        state.cursorY = 2

        let bytes = TmuxScreenRestore.sequence(rows: ["a"], rowCount: 24, state: state)
        let text = try #require(String(bytes: bytes, encoding: .utf8))

        #expect(!text.contains("\u{1b}[2J"))
        #expect(text.firstMatch(of: /\e\[\d+;\d+r/) == nil)
        #expect(text.hasSuffix("\u{1b}[3;6H"))

        // One row shorter than the pane is a real region and is set.
        state.scrollRegionBottom = 22
        let narrowerBytes = TmuxScreenRestore.sequence(rows: ["a"], rowCount: 24, state: state)
        let narrower = try #require(String(bytes: narrowerBytes, encoding: .utf8))
        #expect(narrower.contains("\u{1b}[1;23r\u{1b}[3;6H"))
    }

    @Test("every mouse mode is reset before the ones tmux has on are set, and a pane with none has all three off")
    func sequence_mouseModes_resetBeforeSet() throws {
        let reset = "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l"
        var state = TmuxScreenState()
        state.isMouseStandard = true
        state.isMouseButton = true
        state.isMouseAll = true
        let allBytes = TmuxScreenRestore.sequence(rows: [], rowCount: 24, state: state)
        let all = try #require(String(bytes: allBytes, encoding: .utf8))
        #expect(all.contains(reset + "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006l"))

        let noneBytes = TmuxScreenRestore.sequence(rows: [], rowCount: 24, state: TmuxScreenState())
        let none = try #require(String(bytes: noneBytes, encoding: .utf8))
        #expect(none.contains(reset + "\u{1b}[?1006l"))
        #expect(none.firstMatch(of: /\e\[\?100[023]h/) == nil)
    }

    @Test("the primary screen is selected explicitly, before the clear, since the surface may still show the alternate one")
    func sequence_primaryScreen_leavesAlternateFirst() throws {
        let bytes = TmuxScreenRestore.sequence(rows: ["x"], rowCount: 1, state: TmuxScreenState())
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        let leave = try #require(text.range(of: "\u{1b}[?1049l"))
        let clear = try #require(text.range(of: "\u{1b}[H\u{1b}[J"))
        #expect(leave.upperBound <= clear.lowerBound)
        #expect(text.components(separatedBy: "\u{1b}[?1049").count == 2, "the screen is chosen exactly once")
    }
}
