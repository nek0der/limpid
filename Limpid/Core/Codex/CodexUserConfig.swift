// CodexUserConfig.swift
// Limpid — takes the hook-trust tables earlier builds wrote out of the
// user's own `~/.codex/config.toml`.
//
// Codex now reads trust from the `-c` flags that carry our hooks
// (`CodexHookInjection`), so nothing of ours belongs in that file. Earlier
// builds kept a `[hooks.state."…"]` table there for each hook, between a
// `# BEGIN limpid` and a `# END limpid` marker, and rewrote them on every
// launch. This is what removes them.
//
// It is the only file Limpid edits that belongs to someone else, so the
// edit is deliberately narrow: it removes the lines under our own keys and
// forms no opinion about any other line. A bug in a parse and rewrite of
// their content would reach the original, not a copy, which is why nothing
// in this type reads their TOML.
//
// Ours is what we wrote, not what sits between our markers. Codex edits
// the same file with `toml_edit`: when it records a folder trust it
// appends the new `[projects."…"]` table after the last table in the file,
// which was one of ours, so the table landed before `# END limpid`. So a
// table is ours only when its name is one of our trust keys, in it only
// `enabled` and `trusted_hash` are ours, and anything else — a foreign
// table inside the span, a key Codex added to one of ours, a comment —
// stays where it is. What is read of their TOML is where its values span
// lines (`Line.startsInsideValue`): a value that quotes one of our
// headers, a key or a marker holds text, not a table. And headers and
// keys are read for the names they mean (`CodexConfigSyntax`), not
// compared as text: our header with a comment after it is still ours.

import Foundation

enum CodexUserConfig {
    static let beginMarker = "# BEGIN limpid — managed hook trust, regenerated on launch"
    static let endMarker = "# END limpid"

    /// Every table an earlier build wrote: one per hook it passed, and a
    /// second for `PreToolUse`'s worktree group. Written out rather than
    /// derived from the hooks we pass today, because what earlier builds
    /// left in the file does not change when our hooks do.
    static let legacyTrustKeys = [
        "session_start:0", "session_end:0", "user_prompt_submit:0", "pre_tool_use:0", "pre_tool_use:1",
        "post_tool_use:0", "pre_compact:0", "post_compact:0", "permission_request:0", "interrupt:0", "stop:0"
    ].map { "/<session-flags>/config.toml:\($0):0" }

    /// The two keys an earlier build set in each of its tables. Codex's own
    /// hook review writes the same two, and under a key of ours those are
    /// ours to remove as well: the flags' trust takes their place.
    private static let ownKeys: Set<CodexConfigSyntax.Name> = [["enabled"], ["trusted_hash"]]

    /// Return `existing` without what an earlier Limpid wrote into it: in
    /// each `[hooks.state."<key>"]` table named by `keys`, the `enabled`
    /// and `trusted_hash` lines, then the header itself once nothing but
    /// blank lines and our markers is left under it, and the two markers. Returns the input
    /// unchanged when there is nothing of ours, so the caller can skip
    /// writing and leave a version-controlled config alone.
    ///
    /// The result is not checked here; `problem(in:)` is what a caller
    /// saving it asks first.
    ///
    /// Lines are compared without their line ending, and each keeps the one
    /// it had: a file saved with CRLF (an editor on Windows, a dotfiles
    /// checkout with `autocrlf`) would otherwise match none of our headers
    /// or markers.
    static func removing(keys: [String], from existing: String) -> String {
        let lines = Line.split(existing)
        let removed = ownLines(of: keys, in: lines)
        guard !removed.isEmpty else { return existing }
        return Line.join(closingUp(lines, without: removed), newline: Line.prevailingEnding(of: lines))
    }

    /// The indices of the lines `removing` takes out of `lines`.
    private static func ownLines(of keys: [String], in lines: [Line]) -> Set<Int> {
        let names = Set(keys.compactMap { CodexConfigSyntax.header(of: "[hooks.state.\"\($0)\"]").tableName })
        let inString = Line.startsInsideValue(lines.map(\.text))
        var removed = Set<Int>()
        for index in lines.indices where !inString[index] {
            if isMarker(lines[index]) {
                removed.insert(index)
                continue
            }
            guard let name = CodexConfigSyntax.header(of: lines[index].text).tableName, names.contains(name) else { continue }
            let body = (index + 1)..<tableEnd(in: lines, after: index, inString: inString)
            for line in body where !inString[line] {
                guard let key = CodexConfigSyntax.key(of: lines[line].text), ownKeys.contains(key) else { continue }
                // A value of ours is one line; the lines of one that spans
                // more go with it all the same, or they would be left as
                // keys of their own.
                removed.insert(line)
                removed.formUnion(body[(line + 1)...].prefix { inString[$0] })
            }
            // A marker inside the body is removed above, before or after
            // this table is reached.
            if body.allSatisfy({ removed.contains($0) || isBlank(lines[$0]) || isMarker(lines[$0]) }) {
                removed.insert(index)
            }
        }
        return removed
    }

    /// `lines` without those at `removed`. Blank lines on each side of what
    /// is removed would run together, so those after it go while the line
    /// before is blank, as do those at the very start; when what is removed
    /// ends the file, so do the blank lines before it.
    private static func closingUp(_ lines: [Line], without removed: Set<Int>) -> [Line] {
        var out: [Line] = []
        var index = 0
        while index < lines.count {
            guard removed.contains(index) else {
                out.append(lines[index])
                index += 1
                continue
            }
            while index < lines.count, removed.contains(index) {
                index += 1
            }
            if lines[index...].allSatisfy(isBlank) {
                // Nothing of theirs after ours: no blank lines are left
                // where our block ended the file, and a file that ended in
                // a line feed still does.
                while out.last.map(isBlank) == true {
                    out.removeLast()
                }
                if !out.isEmpty, let last = lines.last, last.text.isEmpty, last.ending == nil {
                    out.append(last)
                }
                break
            }
            while out.last.map(isBlank) ?? true, isBlank(lines[index]) {
                index += 1
            }
        }
        return out
    }

    /// Why Codex would refuse `text`, or `nil`: a header that does not
    /// parse, a table defined twice, or a key set twice in one table.
    /// Checked before a result of `removing` replaces the person's file,
    /// so a fault in our edit never costs them their config.
    static func problem(in text: String) -> CodexConfigSyntax.Problem? {
        let texts = Line.split(text).map(\.text)
        return CodexConfigSyntax.problem(in: texts, startsInsideValue: Line.startsInsideValue(texts))
    }

    // MARK: - Lines

    /// Where a line's scan is: outside any multi-line string, or inside a
    /// basic (`"""`) or a literal (`'''`) one (`Line.startsInsideValue`).
    private enum StringContext {
        case none, basic, literal
    }

    /// One line of the file: its text, and the line ending after it
    /// (`"\n"` or `"\r\n"`). The last line of a file that does not end in a
    /// line feed has none, and its text is kept exactly as it was.
    struct Line: Equatable {
        var text: String
        var ending: String?

        /// `string` at each line feed. Split on UTF-16 units rather than on
        /// characters: Swift reads `\r\n` as a single character, so a split
        /// on characters would find no line feed in a CRLF file at all.
        static func split(_ string: String) -> [Line] {
            let pieces = string.components(separatedBy: "\n")
            return pieces.enumerated().map { offset, piece in
                guard offset < pieces.count - 1 else { return Line(text: piece, ending: nil) }
                guard piece.utf16.last == 0x0D, let text = String(piece.utf16.dropLast()) else {
                    return Line(text: piece, ending: "\n")
                }
                return Line(text: text, ending: "\r\n")
            }
        }

        /// The lines with their endings. A line that had none but is no
        /// longer the last takes `newline`, so the file does not gain a
        /// lone line feed among CRLF lines.
        static func join(_ lines: [Line], newline: String) -> String {
            lines.indices.map { index in
                lines[index].text + (lines[index].ending ?? (index == lines.count - 1 ? "" : newline))
            }.joined()
        }

        /// Whether each of `texts` begins inside a value that spans lines:
        /// a TOML multi-line string (`"""` or `'''`), or an array or inline
        /// table not yet closed. Such a line is the value's however much it
        /// looks like a header, a key or one of our markers: an example of
        /// our table quoted in a value is not our table, and `[1, 2],` in an
        /// array is not a header. A scanner of strings, brackets and
        /// comments only, not a TOML parser: a `"""` or a bracket in a
        /// comment or in a one-line string opens nothing, a backslash
        /// escapes in the basic forms, and a closing delimiter may carry up
        /// to two more quotes, which belong to the string. A header's
        /// brackets close on its own line, so they leave no depth behind.
        static func startsInsideValue(_ texts: [String]) -> [Bool] {
            var scanner = ValueScanner()
            return texts.map { text in
                defer { scanner.scan(text) }
                return scanner.isInsideValue
            }
        }

        /// `"\r\n"` when most of the lines that have an ending have that
        /// one, `"\n"` otherwise, an empty file included.
        static func prevailingEnding(of lines: [Line]) -> String {
            let endings = lines.compactMap(\.ending)
            return endings.filter { $0 == "\r\n" }.count * 2 > endings.count ? "\r\n" : "\n"
        }
    }

    /// The state `Line.startsInsideValue` carries from one line to the
    /// next: the multi-line string it is in, and how many arrays and inline
    /// tables are open.
    private struct ValueScanner {
        private var context = StringContext.none
        private var depth = 0

        var isInsideValue: Bool {
            context != .none || depth > 0
        }

        /// How a bracket outside a string changes the depth.
        private static let depthChange: [Unicode.Scalar: Int] = ["[": 1, "{": 1, "]": -1, "}": -1]

        /// Move past one line.
        mutating func scan(_ text: String) {
            let characters = Array(text.unicodeScalars)
            func opens(_ delimiter: Unicode.Scalar, at index: Int) -> Bool {
                index + 2 < characters.count
                    && characters[index] == delimiter && characters[index + 1] == delimiter
                    && characters[index + 2] == delimiter
            }
            /// The index past a closing delimiter at `index`, with its
            /// up to two extra quotes.
            func closed(_ delimiter: Unicode.Scalar, at index: Int) -> Int {
                var end = index + 3
                while end < characters.count, end < index + 5, characters[end] == delimiter {
                    end += 1
                }
                return end
            }
            var index = 0
            scan: while index < characters.count {
                let character = characters[index]
                switch context {
                case .basic:
                    if character == "\\" {
                        index += 2
                    } else if opens("\"", at: index) {
                        index = closed("\"", at: index)
                        context = .none
                    } else {
                        index += 1
                    }
                case .literal:
                    if opens("'", at: index) {
                        index = closed("'", at: index)
                        context = .none
                    } else {
                        index += 1
                    }
                case .none:
                    if character == "#" {
                        break scan
                    } else if opens("\"", at: index) {
                        context = .basic
                        index += 3
                    } else if opens("'", at: index) {
                        context = .literal
                        index += 3
                    } else if let change = Self.depthChange[character] {
                        // An unmatched closer is a malformed file, and must
                        // not hide the lines after it. An unclosed opener
                        // does hide them, but only on a line that is itself
                        // a malformed header or value, and a malformed
                        // header is what `problem(in:)` refuses first.
                        depth = max(depth + change, 0)
                        index += 1
                    } else if character == "\"" || character == "'" {
                        // A one-line string, to its closing quote or the
                        // end of the line.
                        index += 1
                        while index < characters.count, characters[index] != character {
                            index += character == "\"" && characters[index] == "\\" ? 2 : 1
                        }
                        index += 1
                    } else {
                        index += 1
                    }
                }
            }
        }
    }

    // MARK: - Line kinds

    private static func isBlank(_ line: Line) -> Bool {
        line.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isMarker(_ line: Line) -> Bool {
        line.text == beginMarker || line.text == endMarker
    }

    /// Whether `line` opens a table, well-formed or not: either way it ends
    /// the table before it.
    private static func isHeaderLine(_ line: String) -> Bool {
        CodexConfigSyntax.header(of: line) != .none
    }

    // MARK: - Tables

    /// The index after the last line of the table whose header sits at
    /// `start`: the next header, or the end of the file. Not a marker, which
    /// is a comment to TOML: earlier builds appended the block at the end of
    /// the file, so a key the person typed after `# END limpid` is a key of
    /// our last table, and it keeps that table's header rather than joining
    /// whichever table stands before the block. A line inside a multi-line
    /// string (`inString`) is the string's, and ends nothing.
    private static func tableEnd(in lines: [Line], after start: Int, inString: [Bool]) -> Int {
        lines.indices.dropFirst(start + 1).first { index in
            !inString[index] && isHeaderLine(lines[index].text)
        } ?? lines.endIndex
    }
}
