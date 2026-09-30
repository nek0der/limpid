// ReviewEditorLine.swift
// Limpid — which line of the file on disk a row of the diff stands for.

import Foundation

/// An editor opens the file as it is now, so a row is sent there by its line
/// in the new file. A removed line has none; it is sent to where it used to
/// be, which is where the next surviving line now starts.
enum ReviewEditorLine {
    /// One row of the diff, reduced to what the lookup needs.
    enum Slot: Equatable {
        /// A hunk header or anything else that separates runs of lines. The
        /// search does not cross one, because the next hunk is somewhere
        /// else in the file.
        case boundary
        /// A row of code and its line in the new file, if it has one.
        case line(Int?)
    }

    /// The new-file line for the row at `index`: its own, the next one in the
    /// same run, or one past the previous one when the run ends in removals.
    static func line(at index: Int, in slots: [Slot]) -> Int? {
        guard slots.indices.contains(index) else { return nil }
        var forward = index
        while slots.indices.contains(forward), case let .line(number) = slots[forward] {
            if let number {
                return number
            }
            forward += 1
        }
        var backward = index - 1
        while slots.indices.contains(backward), case let .line(number) = slots[backward] {
            if let number {
                return number + 1
            }
            backward -= 1
        }
        return nil
    }
}

extension ReviewRow {
    /// The row's place in the new file, for `ReviewEditorLine`. A split row
    /// answers for its new column, which holds the line that replaced a
    /// removal beside it.
    var editorLineSlot: ReviewEditorLine.Slot {
        switch kind {
        case let .code(line), let .composer(line):
            .line(line.newLine)
        case let .splitCode(pair):
            .line(pair.new?.newLine)
        // Folded lines sit between the rows either side of an expander, so
        // the lines past it are not the neighbors of the lines before it.
        case .hunk, .notice, .expander:
            .boundary
        case .comment:
            .line(nil)
        }
    }
}
