// TmuxColorReport.swift
// Limpid — the default colors a mirror pane's programs see when they ask tmux, told to tmux per pane.

import Foundation

/// The terminal's default foreground and background, as libghostty resolved
/// them for the current light or dark appearance.
struct TerminalColors: Equatable {
    struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        /// The X11 form OSC 10 and 11 replies use, 16 bits per channel.
        var x11: String {
            String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", red, red, green, green, blue, blue)
        }
    }

    let foreground: RGB
    let background: RGB
}

/// A control client has no terminal of its own, so tmux answers a program's
/// OSC 10 / 11 query with black unless the client says otherwise.
/// `refresh-client -r` hands tmux the reply an outer terminal would have
/// sent, one pane at a time, which is what a program choosing a light or
/// dark palette reads.
enum TmuxColorReport {
    /// `refresh-client -r` arrived in tmux 3.5 (tmux's CHANGES, "3.4 to 3.5").
    static func isSupported(by version: TmuxVersion) -> Bool {
        version.meets(major: 3, minor: 5)
    }

    /// The two reports for `pane`. The escapes are spelled for tmux's
    /// double-quoted strings; the payload is hex digits only, so nothing
    /// else needs escaping.
    static func commands(pane: String, colors: TerminalColors) -> [String] {
        [(10, colors.foreground), (11, colors.background)].map { code, color in
            #"refresh-client -r "\#(pane):\033]\#(code);\#(color.x11)\033\\""#
        }
    }
}
