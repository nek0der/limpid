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
        // `mouse_any_flag` is left out on purpose: tmux sets it whenever any
        // mouse mode is on, so it is not xterm's any-event mode (1003) and
        // would add nothing the three specific flags do not already say.
        "#{mouse_button_flag}", "#{mouse_standard_flag}", "#{mouse_all_flag}", "#{mouse_sgr_flag}",
        "#{scroll_region_upper}", "#{scroll_region_lower}", "#{pane_in_mode}"
    ].joined(separator: " ")

    /// Parse the reply line for `stateFormat`: fifteen integers.
    static func parseState(_ line: String) -> TmuxScreenState? {
        let fields = line.split(separator: " ").compactMap { Int($0) }
        guard fields.count == 15 else { return nil }
        return TmuxScreenState(
            cursorX: fields[0],
            cursorY: fields[1],
            isAlternateScreen: fields[2] != 0,
            isCursorVisible: fields[3] != 0,
            isInsertMode: fields[4] != 0,
            isCursorKeysApplication: fields[5] != 0,
            isKeypadApplication: fields[6] != 0,
            isAutoWrap: fields[7] != 0,
            isMouseButton: fields[8] != 0,
            isMouseStandard: fields[9] != 0,
            isMouseAll: fields[10] != 0,
            isMouseSGR: fields[11] != 0,
            scrollRegionTop: fields[12],
            scrollRegionBottom: fields[13],
            isInCopyMode: fields[14] != 0
        )
    }

    /// The bytes that reproduce `rows` (from `capture-pane -p -e -N`, one
    /// entry per screen row) and `state` in a surface, over whatever screen
    /// and modes it showed before. A pane is repainted after every resize,
    /// and the output dropped while it waited for the capture can include
    /// mode changes, so every mode is set to tmux's value, never assumed.
    ///
    /// Order matters. The screen is chosen first so the rows land on it.
    /// Attributes, insert mode, origin mode, and the scroll region are
    /// reset before painting: a stale attribute would tint the rows, insert
    /// mode would shift them, and a region or origin would confine them.
    /// The screen is cleared from the home position down (ED 0) rather
    /// than with ED 2, which libghostty turns into a scroll into history
    /// when the last line is a prompt, so every repaint would copy the
    /// screen into the scrollback. Modes come after the paint, the scroll
    /// region is set before the cursor because DECSTBM homes the cursor,
    /// and the cursor is placed last.
    static func sequence(rows: [String], rowCount: Int, state: TmuxScreenState) -> Data {
        var out = ""
        out += state.isAlternateScreen ? "\u{1b}[?1049h" : "\u{1b}[?1049l"
        out += "\u{1b}[m\u{1b}[4l\u{1b}[?6l\u{1b}[r"
        out += "\u{1b}[H\u{1b}[J"
        out += rows.joined(separator: "\r\n")

        out += state.isAutoWrap ? "\u{1b}[?7h" : "\u{1b}[?7l"
        out += state.isInsertMode ? "\u{1b}[4h" : "\u{1b}[4l"
        out += state.isCursorKeysApplication ? "\u{1b}[?1h" : "\u{1b}[?1l"
        out += state.isKeypadApplication ? "\u{1b}=" : "\u{1b}>"
        // libghostty keeps one tracking mode, and resetting any of the three
        // clears it, so all are reset before the ones tmux has on are set.
        out += "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l"
        if state.isMouseStandard {
            out += "\u{1b}[?1000h"
        }
        if state.isMouseButton {
            out += "\u{1b}[?1002h"
        }
        if state.isMouseAll {
            out += "\u{1b}[?1003h"
        }
        out += state.isMouseSGR ? "\u{1b}[?1006h" : "\u{1b}[?1006l"
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
