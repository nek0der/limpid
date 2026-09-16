// TmuxScreenRestoreTests.swift
// Limpid — pins the display-message state format and the order of the screen-restore byte sequence.

import Foundation
import Testing
@testable import Limpid

@Suite("tmux screen restore")
struct TmuxScreenRestoreTests {
    @Test("the state line is sixteen integers in the format's field order")
    func parseState_readsEveryField() throws {
        let state = try #require(TmuxScreenRestore.parseState("3 7 1 1 0 1 0 1 0 0 0 0 0 0 29 0"))
        #expect(state.cursorX == 3)
        #expect(state.cursorY == 7)
        #expect(state.isAlternateScreen)
        #expect(state.isCursorVisible)
        #expect(!state.isInsertMode)
        #expect(state.isCursorKeysApplication)
        #expect(!state.isKeypadApplication)
        #expect(state.isAutoWrap)
        #expect(!state.isMouseAny && !state.isMouseButton && !state.isMouseStandard && !state.isMouseAll && !state.isMouseSGR)
        #expect(state.scrollRegionTop == 0)
        #expect(state.scrollRegionBottom == 29)
        #expect(!state.isInCopyMode)
        #expect(TmuxScreenRestore.stateFormat.split(separator: " ").count == 16)
    }

    @Test("a state line with the wrong field count is rejected")
    func parseState_rejectsWrongArity() {
        #expect(TmuxScreenRestore.parseState("3 7 1") == nil)
        #expect(TmuxScreenRestore.parseState("") == nil)
        #expect(TmuxScreenRestore.parseState("a b c d e f g h i j k l m n o p") == nil)
    }

    @Test("a plain screen resets attributes, paints the rows, sets modes, and places the cursor last")
    func sequence_plainScreen() throws {
        let bytes = TmuxScreenRestore.sequence(rows: ["first", "second"], rowCount: 2, state: TmuxScreenState())
        let text = try #require(String(bytes: bytes, encoding: .utf8))

        #expect(text.hasPrefix("\u{1b}[m\u{1b}[H\u{1b}[2J"))
        #expect(text.contains("first\r\nsecond"))
        #expect(!text.contains("\u{1b}[?1049h"))
        #expect(!text.contains("r\u{1b}["), "no scroll region for a full-height default")
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
}
