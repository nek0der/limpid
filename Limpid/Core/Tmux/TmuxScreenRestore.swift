// TmuxScreenRestore.swift
// Limpid — rebuilds a pane's visible screen and terminal modes in a fresh surface after attaching.

import Foundation

/// The pane state tmux reports through one `display-message`, in the field
/// order of `TmuxScreenRestore.stateFormat`. Everything a freshly created
/// surface would otherwise get wrong: a TUI that turned on application
/// cursor keys, a scroll region, mouse reporting, or the alternate screen
/// keeps running inside tmux, so the surface has to start in that state.
struct TmuxScreenState: Equatable {
    var cursorX = 0
    var cursorY = 0
    var isAlternateScreen = false
    var isCursorVisible = true
    var isInsertMode = false
    var isCursorKeysApplication = false
    var isKeypadApplication = false
    var isAutoWrap = true
    var isMouseAny = false
    var isMouseButton = false
    var isMouseStandard = false
    var isMouseAll = false
    var isMouseSGR = false
    var scrollRegionTop = 0
    var scrollRegionBottom = 0
    var isInCopyMode = false
}

enum TmuxScreenRestore {
    /// The `-F` argument that produces a line `parseState` reads. Kept as
    /// one constant so the two cannot drift apart.
    static let stateFormat = [
        "#{cursor_x}", "#{cursor_y}", "#{alternate_on}", "#{cursor_flag}", "#{insert_flag}",
        "#{keypad_cursor_flag}", "#{keypad_flag}", "#{wrap_flag}",
        "#{mouse_any_flag}", "#{mouse_button_flag}", "#{mouse_standard_flag}", "#{mouse_all_flag}", "#{mouse_sgr_flag}",
        "#{scroll_region_upper}", "#{scroll_region_lower}", "#{pane_in_mode}"
    ].joined(separator: " ")

    /// Parse the reply line for `stateFormat`: sixteen integers.
    static func parseState(_ line: String) -> TmuxScreenState? {
        let fields = line.split(separator: " ").compactMap { Int($0) }
        guard fields.count == 16 else { return nil }
        return TmuxScreenState(
            cursorX: fields[0],
            cursorY: fields[1],
            isAlternateScreen: fields[2] != 0,
            isCursorVisible: fields[3] != 0,
            isInsertMode: fields[4] != 0,
            isCursorKeysApplication: fields[5] != 0,
            isKeypadApplication: fields[6] != 0,
            isAutoWrap: fields[7] != 0,
            isMouseAny: fields[8] != 0,
            isMouseButton: fields[9] != 0,
            isMouseStandard: fields[10] != 0,
            isMouseAll: fields[11] != 0,
            isMouseSGR: fields[12] != 0,
            scrollRegionTop: fields[13],
            scrollRegionBottom: fields[14],
            isInCopyMode: fields[15] != 0
        )
    }

    /// The bytes that reproduce `rows` (from `capture-pane -p -e`, one entry
    /// per screen row) and `state` in an empty surface.
    ///
    /// Order matters. The alternate screen is entered first so the rows land
    /// on it. Attributes are reset before painting because capture-pane
    /// emits SGR as tmux tracks it and a stale attribute would tint what
    /// follows. Modes come after the paint so insert mode cannot shift the
    /// rows, the scroll region is set before the cursor because DECSTBM
    /// homes the cursor, and the cursor is placed last.
    static func sequence(rows: [String], rowCount: Int, state: TmuxScreenState) -> Data {
        var out = ""
        if state.isAlternateScreen { out += "\u{1b}[?1049h" }
        out += "\u{1b}[m\u{1b}[H\u{1b}[2J"
        out += rows.joined(separator: "\r\n")

        out += state.isAutoWrap ? "\u{1b}[?7h" : "\u{1b}[?7l"
        out += state.isInsertMode ? "\u{1b}[4h" : "\u{1b}[4l"
        out += state.isCursorKeysApplication ? "\u{1b}[?1h" : "\u{1b}[?1l"
        out += state.isKeypadApplication ? "\u{1b}=" : "\u{1b}>"
        if state.isMouseStandard { out += "\u{1b}[?1000h" }
        if state.isMouseButton { out += "\u{1b}[?1002h" }
        if state.isMouseAll || state.isMouseAny { out += "\u{1b}[?1003h" }
        if state.isMouseSGR { out += "\u{1b}[?1006h" }
        out += state.isCursorVisible ? "\u{1b}[?25h" : "\u{1b}[?25l"

        // tmux reports the region even when it spans the whole pane; only a
        // narrower one is worth setting, and DECSTBM with the full height
        // would be a no-op that still homes the cursor. A bottom at or above
        // the top is not a region at all (the zero value of the struct).
        if state.scrollRegionBottom > state.scrollRegionTop,
           state.scrollRegionTop > 0 || state.scrollRegionBottom < rowCount - 1
        {
            out += "\u{1b}[\(state.scrollRegionTop + 1);\(state.scrollRegionBottom + 1)r"
        }
        out += "\u{1b}[\(state.cursorY + 1);\(state.cursorX + 1)H"
        return Data(out.utf8)
    }
}
