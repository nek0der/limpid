// TerminalGridSize.swift
// Weir — a terminal's size in character cells.

import Foundation

/// How many columns and rows a pane's terminal has, as libghostty laid its
/// grid out for the pane's frame and font.
struct TerminalGridSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
}
