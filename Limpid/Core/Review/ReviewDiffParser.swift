// ReviewDiffParser.swift
// Limpid — validated old/new line positions for unified diffs.

import Foundation

enum ReviewDiffParser {
    /// The most rows any one file may contribute.
    ///
    /// Shared with the untracked path, which builds its rows without going
    /// through `parse`: a file that is only newlines is cheap to write and
    /// expensive to lay out, and the two routes disagreeing on the ceiling is
    /// how one of them ended up without one.
    static let maxRows = 100_000

    /// Split a blob into the lines a reader will see.
    ///
    /// Two things happen here rather than at each of the three call sites,
    /// which is where they used to disagree. Git writes the file's own line
    /// endings through, so a CRLF file leaves a carriage return at the end of
    /// every line; it belongs to the file's encoding rather than to the line
    /// being reviewed, and it is refused on the way to a terminal — a comment
    /// on a Windows-authored file could be written but never sent. And what
    /// must not reach a terminal at all is replaced, so what is drawn and what
    /// is quoted are the same text.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n").map {
            ReviewText.neutralized($0.hasSuffix("\r") ? String($0.dropLast()) : $0)
        }
    }

    /// File identity must come from Git's NUL-delimited metadata, not these display headers.
    static func parse(_ patch: String) throws -> [ReviewLine] {
        let header = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var rows: [ReviewLine] = []
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0
        var isInHunk = false
        // Counted from the headers rather than from the rows, so every line of
        // one hunk answers with the same number and a reader's run can be held
        // inside it.
        var hunkIndex: Int?
        let lines = Self.lines(of: patch).dropLast(patch.hasSuffix("\n") ? 1 : 0)
        for line in lines {
            guard rows.count < maxRows else { throw ReviewError.tooLarge }
            if line.hasPrefix("@@ ") {
                guard oldRemaining == 0, newRemaining == 0 else {
                    throw ReviewError.invalidDiff
                }
                let string = line as NSString
                guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else {
                    throw ReviewError.invalidDiff
                }
                func number(_ index: Int, default fallback: Int) throws -> Int {
                    let range = match.range(at: index)
                    if range.location == NSNotFound {
                        return fallback
                    }
                    guard let value = Int(string.substring(with: range)) else {
                        throw ReviewError.invalidDiff
                    }
                    return value
                }
                oldLine = try number(1, default: 0)
                oldRemaining = try number(2, default: 1)
                newLine = try number(3, default: 0)
                newRemaining = try number(4, default: 1)
                isInHunk = true
                hunkIndex = hunkIndex.map { $0 + 1 } ?? 0
                rows.append(ReviewLine(id: rows.count, kind: .hunk, text: line, oldLine: nil, newLine: nil, hunkIndex: hunkIndex))
                continue
            } else if line.hasPrefix("\\ No newline at end of file") {
                guard isInHunk else { throw ReviewError.invalidDiff }
                rows.append(ReviewLine(id: rows.count, kind: .marker, text: line, oldLine: nil, newLine: nil, hunkIndex: hunkIndex))
                continue
            } else if isInHunk, oldRemaining > 0 || newRemaining > 0 {
                // The marker is one scalar, not one `Character`. A line whose
                // content starts with a combining mark joins it to the marker
                // into a single grapheme, so reading the first `Character`
                // matched neither `+` nor `-` and refused the whole file — and
                // dropping the first `Character` would have eaten the mark
                // along with the marker.
                let marker = line.unicodeScalars.first
                let consumesOld = marker == " " || marker == "-"
                let consumesNew = marker == " " || marker == "+"
                guard consumesOld || consumesNew,
                      !consumesOld || oldRemaining > 0,
                      !consumesNew || newRemaining > 0,
                      oldLine < Int.max, newLine < Int.max
                else { throw ReviewError.invalidDiff }
                rows.append(ReviewLine(
                    id: rows.count,
                    kind: marker == "+" ? .added : (marker == "-" ? .removed : .context),
                    text: String(String.UnicodeScalarView(line.unicodeScalars.dropFirst())),
                    oldLine: consumesOld ? oldLine : nil, newLine: consumesNew ? newLine : nil, hunkIndex: hunkIndex
                ))
                if consumesOld {
                    oldLine += 1
                    oldRemaining -= 1
                }
                if consumesNew {
                    newLine += 1
                    newRemaining -= 1
                }
                continue
            } else {
                if line.hasPrefix("@@@") {
                    throw ReviewError.invalidDiff
                }
                isInHunk = false
            }
            rows.append(ReviewLine(id: rows.count, kind: .fileHeader, text: line, oldLine: nil, newLine: nil))
        }
        guard oldRemaining == 0, newRemaining == 0 else { throw ReviewError.invalidDiff }
        return rows
    }
}
