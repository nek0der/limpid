// SetupCommandsDraft.swift
// Limpid — a project's setup commands as the text Project Settings edits, keeping what state.json adds to a line.

import Foundation

/// The text form of `Project.bootstrap`: one step per line, run in order, so
/// one text rather than a list of patterns as the test commands are. A step
/// written into state.json with a `timeout` or a `cwd` (`.detailed`) shows
/// as its command line only; this keeps those settings with the line while
/// it is edited, and names them under the editor, so an edit never drops
/// them unseen.
enum SetupCommandsDraft {
    /// What state.json adds to one line, for the note under the editor.
    struct Detail: Equatable {
        /// The line's number, from 1.
        let line: Int
        let timeoutSeconds: Int?
        let cwd: String?
    }

    /// The note under the editor for one line.
    static func description(of detail: Detail) -> LocalizedStringResource {
        switch (detail.timeoutSeconds, detail.cwd) {
        case let (timeoutSeconds?, cwd?):
            LocalizedStringResource(
                "Line \(detail.line): times out after \(timeoutSeconds) s, runs in \(cwd)",
                comment: "Project settings: a setup line's settings from state.json; its number, seconds, folder"
            )
        case let (timeoutSeconds?, nil):
            LocalizedStringResource(
                "Line \(detail.line): times out after \(timeoutSeconds) s",
                comment: "Project settings: a setup line's timeout from state.json; its number, seconds"
            )
        case let (nil, cwd?):
            LocalizedStringResource(
                "Line \(detail.line): runs in \(cwd)",
                comment: "Project settings: a setup line's folder from state.json; its number, folder"
            )
        case (nil, nil):
            LocalizedStringResource("Line \(detail.line)", comment: "Project settings: a setup line's number")
        }
    }

    /// How many of `before`'s steps with a timeout or a cwd lost them in
    /// `after`: a line removed, or changed while lines were added or
    /// removed. The sheet says so under the editor rather than dropping
    /// them unseen; it compares with the steps as the sheet opened.
    static func droppedDetailCount(before: [BootstrapItem], after: [BootstrapItem]) -> Int {
        var remaining = after.compactMap { item -> BootstrapDetail? in
            guard case let .detailed(detail) = item else { return nil }
            return detail
        }
        var dropped = 0
        for case let .detailed(detail) in before where detail.timeout != nil || detail.cwd != nil {
            if let index = remaining.firstIndex(where: { $0.timeout == detail.timeout && $0.cwd == detail.cwd }) {
                remaining.remove(at: index)
            } else {
                dropped += 1
            }
        }
        return dropped
    }

    static func text(for items: [BootstrapItem]) -> String {
        items.map(\.cmd).joined(separator: "\n")
    }

    /// The lines that carry settings of their own.
    static func details(of items: [BootstrapItem]) -> [Detail] {
        items.enumerated().compactMap { index, item in
            guard case let .detailed(detail) = item, detail.timeout != nil || detail.cwd != nil else { return nil }
            return Detail(line: index + 1, timeoutSeconds: detail.timeout, cwd: detail.cwd)
        }
    }

    /// The steps `text` names, each line passed through `normalizing`. A
    /// line equal to an earlier step's command is that step, whatever moved
    /// around it. A line that changed in place, while no line was added or
    /// removed, keeps its step's timeout and cwd with the new command. Any
    /// other new line is a plain command.
    static func items(
        from text: String,
        previous: [BootstrapItem],
        normalizing: (String) -> String = { $0 }
    ) -> [BootstrapItem] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { normalizing(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        var unused = Array(previous.indices)
        var matched: [BootstrapItem?] = lines.map { line in
            guard let position = unused.firstIndex(where: { previous[$0].cmd == line }) else { return nil }
            return previous[unused.remove(at: position)]
        }
        let isEditInPlace = lines.count == previous.count
        for index in matched.indices where matched[index] == nil {
            if isEditInPlace, unused.contains(index), case let .detailed(detail) = previous[index] {
                var kept = detail
                kept.cmd = lines[index]
                matched[index] = .detailed(kept)
            } else {
                matched[index] = .shorthand(lines[index])
            }
        }
        return matched.compactMap(\.self)
    }
}
