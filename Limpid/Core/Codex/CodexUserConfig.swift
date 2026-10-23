// CodexUserConfig.swift
// Limpid — splices our hook-trust block into the user's own
// `~/.codex/config.toml`.
//
// This is the only file Limpid edits that belongs to someone else, so the
// splice is deliberately narrow: it rewrites the tables it generated
// itself, line by line, and forms no opinion about any other line. A bug
// in a parse and rewrite of their content would reach the original, not a
// copy, which is why nothing in this type reads their TOML.
//
// Ours is what we generated, not what sits between our markers. Codex
// edits the same file with `toml_edit`: when it records a folder trust
// it appends the new `[projects."…"]` table after the last table in the
// file, which is one of ours, so the table lands before `# END limpid`.
// Treating the whole span as ours and replacing it on every launch would
// delete every trust decision the person had made since the previous one.
// So a table is ours only when its name is one of the `[hooks.state."…"]`
// tables in `block`, we
// rewrite only the keys that `block` states inside it, and anything else
// — a foreign table inside the span, a key Codex added to one of ours, a
// comment — stays where it is. The markers remain as the place where a
// table we have not written yet goes, and as a signpost for anyone
// reading the file. What is read of their TOML is where its values span
// lines (`Line.startsInsideValue`): a value that quotes one of our
// headers, a key or a marker holds text, not a table. And headers and
// keys are read for the names they mean (`CodexConfigSyntax`), not
// compared as text: our header with a comment after it is still ours, and
// a table we did not recognize would be appended a second time.

import Foundation

enum CodexUserConfig {
    static let beginMarker = "# BEGIN limpid — managed hook trust, regenerated on launch"
    static let endMarker = "# END limpid"

    /// Return `existing` with every table of `block` present and holding
    /// the values `block` states. `block` is a sequence of TOML tables,
    /// each a header line followed by `key = value` lines. A table already
    /// in the file — wherever it is — is rewritten in place; one that is
    /// missing goes between our markers, which are appended when the file
    /// has none. Returns the input unchanged when the result would be
    /// identical, so the caller can skip writing and leave a
    /// version-controlled config alone.
    ///
    /// The result is not checked here; `problem(in:)` is what a caller
    /// saving it asks first.
    ///
    /// Lines are compared without their line ending, and each keeps the one
    /// it had: a file saved with CRLF (an editor on Windows, a dotfiles
    /// checkout with `autocrlf`) would otherwise match none of our headers
    /// or markers, and a second set of our tables appended after the first
    /// is a TOML file Codex refuses to load. A line we add takes the ending
    /// most of the file's lines have.
    static func applying(block: String, to existing: String) -> String {
        let ours = Table.parse(Line.split(block).map(\.text))
        var lines = Line.split(existing)
        let newline = Line.prevailingEnding(of: lines)
        let added = { (text: String) in Line(text: text, ending: newline) }
        let joined = { (lines: [Line]) in Line.join(lines, newline: newline) }

        var missing: [Table] = []
        for table in ours {
            removeAppendedCopies(of: table, from: &lines)
            // Read again for each table: the one before may have grown.
            let inString = Line.startsInsideValue(lines.map(\.text))
            let headers = lines.indices.filter { !inString[$0] && isHeader(lines[$0].text, of: table) }
            guard !headers.isEmpty else {
                missing.append(table)
                continue
            }
            // Back to front, so an earlier table's growth does not move the
            // indices of a later one.
            for start in headers.reversed() {
                let end = tableEnd(in: lines, after: start, inString: inString)
                lines.replaceSubrange(start..<end, with: table.merged(into: Array(lines[start..<end]), adding: added))
            }
        }
        guard !missing.isEmpty else { return joined(lines) }
        let rendered = missing.flatMap(\.lines).map(added)
        let inString = Line.startsInsideValue(lines.map(\.text))

        guard let start = lines.indices.first(where: { !inString[$0] && lines[$0].text == beginMarker }) else {
            // Keep exactly one blank line between their content and ours,
            // and none at all when the file was empty.
            while lines.last?.text.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            if !lines.isEmpty {
                lines.append(added(""))
            }
            return joined(lines + [added(beginMarker)] + rendered + [added(endMarker)])
        }

        // New tables go just before the closing marker. A hand-edited file
        // can have lost that marker; then they follow the opening one, and
        // whatever the person wrote after it is left exactly as it was.
        let insertion = lines.indices[start...].first { !inString[$0] && lines[$0].text == endMarker } ?? (start + 1)
        lines.insert(contentsOf: rendered, at: insertion)
        return joined(lines)
    }

    /// Why Codex would refuse `text`, or `nil`: a header that does not
    /// parse, a table defined twice, or a key set twice in one table.
    /// Checked before a result of `applying` replaces the person's file,
    /// so a fault in our splice costs them our hooks, never their config.
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

    // MARK: - Tables

    /// One table of our block: the header line, the name it means, and the
    /// `key = value` lines under it. `name` is `nil` for a header line that
    /// does not parse as `[name]`: our block never has one, and such a table
    /// matches nothing, so it is appended and `problem(in:)` refuses the
    /// result.
    struct Table: Equatable {
        let header: String
        let name: CodexConfigSyntax.Name?
        let entries: [String]

        var lines: [String] {
            [header] + entries
        }

        /// Split `lines` into tables at each header line. Lines before the
        /// first header have no table to belong to and are dropped: our
        /// block never has any, and a key with no header would otherwise
        /// land in whatever table precedes the markers in their file.
        static func parse(_ lines: [String]) -> [Table] {
            var tables: [Table] = []
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let header = CodexConfigSyntax.header(of: line)
                if header != .none {
                    tables.append(Table(header: line, name: header.tableName, entries: []))
                } else if let last = tables.indices.last {
                    let table = tables[last]
                    tables[last] = Table(header: table.header, name: table.name, entries: table.entries + [line])
                }
            }
            return tables
        }

        /// `body` as it stands in the file, with each key this table states
        /// set to our value: the line is replaced where the key is present
        /// and added after the last key otherwise (`adding` makes the line,
        /// with the file's line ending). Every other line of the body — a
        /// key Codex added, a comment, a blank line — is kept, and a replaced
        /// line keeps its ending.
        /// `trusted_hash` is stated by us and so is always ours to set:
        /// Codex runs a hook only while the recorded hash equals the one it
        /// computes from the command, so a hash left over from a previous
        /// command would silence the hook rather than preserve a decision.
        /// When the command has not changed the value we write is the one
        /// already there, and the file stays as it was.
        func merged(into body: [Line], adding: (String) -> Line) -> [Line] {
            var out = body
            for entry in entries {
                // Keys are compared by name, so `"enabled" = false` is the
                // key we state as `enabled = true`, not a second one.
                guard let key = CodexConfigSyntax.key(of: entry) else { continue }
                // A line of a multi-line string is part of a value, not a key.
                let inString = Line.startsInsideValue(out.map(\.text))
                let keyOf = { (index: Int) in inString[index] ? nil : CodexConfigSyntax.key(of: out[index].text) }
                // The line after a key's value, past the lines of a value
                // that is a multi-line string.
                let valueEnd = { (index: Int) in
                    out.indices.dropFirst(index + 1).first { !inString[$0] } ?? out.endIndex
                }
                if let index = out.indices.dropFirst().first(where: { keyOf($0) == key }) {
                    out[index].text = entry
                    out.removeSubrange((index + 1)..<valueEnd(index))
                } else {
                    let afterLastKey = out.indices.dropFirst()
                        .last(where: { keyOf($0) != nil })
                        .map(valueEnd) ?? 1
                    out.insert(adding(entry), at: afterLastKey)
                }
            }
            return out
        }
    }

    /// Whether `line` opens a table, well-formed or not: either way it ends
    /// the table before it.
    private static func isHeaderLine(_ line: String) -> Bool {
        CodexConfigSyntax.header(of: line) != .none
    }

    /// Whether `line` is the header of `table`: `[name]` with the same
    /// name, however it is quoted or spaced, and whatever comment follows.
    private static func isHeader(_ line: String, of table: Table) -> Bool {
        guard let name = table.name else { return false }
        return CodexConfigSyntax.header(of: line) == .table(name)
    }

    /// Remove the second copies of `table` that an earlier Limpid appended
    /// between our markers. Before tables were matched by name, our header
    /// with a comment after it went unrecognized and a fresh copy was added
    /// on the next launch. That file defines the table twice, so Codex does
    /// not start, and rewriting both copies would keep it that way. A copy
    /// between the markers is ours to remove; the one the person annotated
    /// or moved is kept, and when every copy is between the markers the
    /// first is. Copies outside the markers are not ours to judge, and
    /// `problem(in:)` keeps such a file from being written.
    ///
    /// Only the copy's header and the keys `table` states are ours, though.
    /// A key Codex or the person added to a copy, dotted or not, and a
    /// comment are theirs, and move into the table that is kept
    /// (`foreignLines`). A key the kept table already sets to the same text
    /// is the same setting and is not repeated. One it sets differently is
    /// moved anyway: which value they meant is not ours to decide, and the
    /// result then sets the key twice, which `problem(in:)` refuses, so the
    /// file stays as it was rather than losing either value.
    private static func removeAppendedCopies(of table: Table, from lines: inout [Line]) {
        let inString = Line.startsInsideValue(lines.map(\.text))
        let headers = lines.indices.filter { !inString[$0] && isHeader(lines[$0].text, of: table) }
        guard headers.count > 1,
              let begin = lines.indices.first(where: { !inString[$0] && lines[$0].text == beginMarker }),
              let end = lines.indices[begin...].first(where: { !inString[$0] && lines[$0].text == endMarker })
        else { return }
        let inside = headers.filter { (begin + 1)..<end ~= $0 }
        let copies = inside.count == headers.count ? Array(inside.dropFirst()) : inside
        // Every copy is removed only when some header is outside the
        // markers, and when all are inside the first stays: one is kept.
        guard let kept = headers.first(where: { !copies.contains($0) }) else { return }

        let ownKeys = Set(table.entries.compactMap(CodexConfigSyntax.key(of:)))
        let file = lines
        let body = { (start: Int) in (start + 1)..<tableEnd(in: file, after: start, inString: inString) }
        var values = keyValues(in: body(kept), of: file, inString: inString)
        var carried: [Line] = []
        for start in copies {
            carried += foreignLines(in: body(start), of: file, inString: inString, ownKeys: ownKeys, values: &values)
        }
        // Back to front, so a removal does not move the next one.
        var keptStart = kept
        for start in copies.reversed() {
            let range = start..<body(start).upperBound
            lines.removeSubrange(range)
            if start < kept {
                keptStart -= range.count
            }
        }
        guard !carried.isEmpty else { return }
        // After the kept table's last line that is not blank, so the blank
        // line that sets it apart from the next table stays after it.
        let keptEnd = tableEnd(in: lines, after: keptStart, inString: Line.startsInsideValue(lines.map(\.text)))
        let insertion = lines.indices[(keptStart + 1)..<keptEnd]
            .last { !lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0 + 1 } ?? (keptStart + 1)
        lines.insert(contentsOf: carried, at: insertion)
    }

    /// What each key in `range` of `lines` is set to, as `valueText` reads
    /// it.
    private static func keyValues(
        in range: Range<Int>,
        of lines: [Line],
        inString: [Bool]
    ) -> [CodexConfigSyntax.Name: String] {
        var values: [CodexConfigSyntax.Name: String] = [:]
        for index in range where !inString[index] {
            if let entry = valueText(at: index, in: range, of: lines, inString: inString) {
                values[entry.key] = values[entry.key] ?? entry.value
            }
        }
        return values
    }

    /// The key on line `index` and its value as written: the text after
    /// `=` and every line of a value that spans lines. `nil` for a line
    /// that is not a key.
    private static func valueText(
        at index: Int,
        in range: Range<Int>,
        of lines: [Line],
        inString: [Bool]
    ) -> (key: CodexConfigSyntax.Name, value: String)? {
        guard let line = CodexConfigSyntax.keyAndValue(of: lines[index].text) else { return nil }
        let continuation = range[(index + 1)...].prefix { inString[$0] }.map { lines[$0].text }
        return (line.key, ([line.value] + continuation).joined(separator: "\n"))
    }

    /// The lines of a copy's body (`range`) that are not ours: every key
    /// other than `ownKeys`, with the lines of its value, and every
    /// comment, without the blank lines at either end. A key whose value
    /// `values` already holds with the same text is left out; any other is
    /// kept and recorded in `values`.
    private static func foreignLines(
        in range: Range<Int>,
        of lines: [Line],
        inString: [Bool],
        ownKeys: Set<CodexConfigSyntax.Name>,
        values: inout [CodexConfigSyntax.Name: String]
    ) -> [Line] {
        var out: [Line] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let valueEnd = range[(index + 1)...].first { !inString[$0] } ?? range.upperBound
            defer { index = valueEnd }
            if let entry = valueText(at: index, in: range, of: lines, inString: inString) {
                // By scalar, as names are (`CodexConfigSyntax.Name`):
                // `"caf\u{E9}"` and `"cafe\u{301}"` are two values in TOML,
                // and Swift's `==` would drop the second as the first.
                let isSameValue = values[entry.key]?.unicodeScalars.elementsEqual(entry.value.unicodeScalars) == true
                if ownKeys.contains(entry.key) || isSameValue {
                    continue
                }
                values[entry.key] = values[entry.key] ?? entry.value
            }
            out += lines[index..<valueEnd]
        }
        let isBlank = { (line: Line) in line.text.trimmingCharacters(in: .whitespaces).isEmpty }
        while out.first.map(isBlank) == true {
            out.removeFirst()
        }
        while out.last.map(isBlank) == true {
            out.removeLast()
        }
        return out
    }

    /// The index after the last line of the table whose header sits at
    /// `start`: the next header or one of our markers, or the end of the
    /// file. Both markers end a table because Codex writes a table's keys
    /// directly under its header and nothing else of ours follows them.
    /// A line inside a multi-line string (`inString`) is the string's, and
    /// ends nothing.
    private static func tableEnd(in lines: [Line], after start: Int, inString: [Bool]) -> Int {
        lines.indices.dropFirst(start + 1).first { index in
            !inString[index]
                && (isHeaderLine(lines[index].text) || lines[index].text == beginMarker || lines[index].text == endMarker)
        } ?? lines.endIndex
    }
}
