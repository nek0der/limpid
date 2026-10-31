// CodexConfigSyntax.swift
// Weir — reads the names in a `config.toml` line the way TOML does, and
// checks a config we are about to save for what Codex would refuse.
//
// `CodexUserConfig` finds the tables earlier builds wrote by name. A name
// compared as text misses the same table written another way: a header
// that carries a trailing comment (`[hooks.state."…"]  # note`), a segment
// in the other quote (`'a'` for `"a"`), or spaces around a dot. A table we
// fail to find is one we leave behind. So headers and keys are read here
// into the names they mean, and nothing else of the file is.

import Foundation

enum CodexConfigSyntax {
    /// A key or table name: its segments as TOML means them, quotes and
    /// escapes resolved.
    ///
    /// Two names are the same when each segment has the same Unicode
    /// scalars. Swift's `String` equality is canonical equivalence, under
    /// which `"caf\u{E9}"` and `"cafe\u{301}"` are one string; TOML, and the
    /// `toml_edit` Codex reads the file with, keeps them as two keys. A name
    /// compared as a `String` would call two such tables one and refuse a
    /// valid config as a duplicate, so no segment is compared or hashed as a
    /// `String` here.
    struct Name: Hashable, ExpressibleByArrayLiteral, CustomStringConvertible {
        let segments: [String]

        init(_ segments: [String]) {
            self.segments = segments
        }

        init(arrayLiteral segments: String...) {
            self.segments = segments
        }

        var count: Int {
            segments.count
        }

        var description: String {
            segments.description
        }

        /// The first `length` segments.
        func prefix(_ length: Int) -> Name {
            Name(Array(segments.prefix(length)))
        }

        /// Whether `other` is this name or a name above it.
        func starts(with other: Name) -> Bool {
            other.count <= count && prefix(other.count) == other
        }

        static func + (lhs: Name, rhs: Name) -> Name {
            Name(lhs.segments + rhs.segments)
        }

        static func == (lhs: Name, rhs: Name) -> Bool {
            lhs.count == rhs.count
                && zip(lhs.segments, rhs.segments).allSatisfy { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(count)
            for segment in segments {
                hasher.combine(segment.unicodeScalars.count)
                for scalar in segment.unicodeScalars {
                    hasher.combine(scalar)
                }
            }
        }
    }

    /// What a line that opens with `[` is.
    enum HeaderLine: Equatable {
        /// Not a header: the line does not open with `[`.
        case none
        /// `[name]`.
        case table(Name)
        /// `[[name]]`.
        case arrayTable(Name)
        /// Opens with `[` but is no header TOML accepts.
        case malformed

        /// The name of a `[name]` header; `nil` for anything else.
        var tableName: Name? {
            guard case let .table(name) = self else { return nil }
            return name
        }
    }

    /// What the line is as a header. Whitespace may surround the brackets
    /// and each segment, and a comment may follow the closing bracket; an
    /// array table's brackets have to be adjacent.
    static func header(of line: String) -> HeaderLine {
        var scanner = Scanner(line)
        scanner.skipWhitespace()
        guard scanner.take("[") else { return .none }
        let isArray = scanner.take("[")
        guard let name = scanner.name(),
              scanner.take("]"),
              !isArray || scanner.take("]"),
              scanner.isAtEndOrComment()
        else { return .malformed }
        return isArray ? .arrayTable(name) : .table(name)
    }

    /// The key of a `key = value` line, dotted segments included; `nil`
    /// for a comment, a blank line, a header, or a line that is not a key.
    /// An `=` or `#` inside a quoted segment is the segment's.
    static func key(of line: String) -> Name? {
        var scanner = Scanner(line)
        scanner.skipWhitespace()
        guard !scanner.isAtEndOrComment(), !scanner.peek("["),
              let name = scanner.name(),
              scanner.take("=")
        else { return nil }
        return name
    }

    // MARK: - Validation

    /// Why a config would not load, with the zero-based line it was found on.
    enum Problem: Equatable, CustomStringConvertible {
        /// A line that opens with `[` is no header TOML accepts.
        case malformedHeader(line: Int)
        /// A header for a name already defined: by a header, by a key that
        /// holds a value, or as the table a dotted key implies.
        case duplicateTable(line: Int)
        /// A key for a name already defined.
        case duplicateKey(line: Int)

        var description: String {
            switch self {
            case let .malformedHeader(line): "malformed table header on line \(line + 1)"
            case let .duplicateTable(line): "duplicate table on line \(line + 1)"
            case let .duplicateKey(line): "duplicate key on line \(line + 1)"
            }
        }
    }

    /// The first reason Codex would refuse `lines` as a config, or `nil`.
    /// This is a check of the shape we edit — headers and the keys under
    /// them — not a TOML validator: values are not read. `startsInsideValue`
    /// says which lines belong to a value that spans lines, which define
    /// nothing however much they look like a header or a key.
    static func problem(in lines: [String], startsInsideValue: [Bool]) -> Problem? {
        var definitions = Definitions()
        for (index, line) in lines.enumerated() where !startsInsideValue[index] {
            switch header(of: line) {
            case .malformed:
                return .malformedHeader(line: index)
            case let .table(name):
                guard definitions.defineTable(name) else { return .duplicateTable(line: index) }
            case let .arrayTable(name):
                guard definitions.appendArrayElement(name) else { return .duplicateTable(line: index) }
            case .none:
                if let key = key(of: line), !definitions.setKey(key) {
                    return .duplicateKey(line: index)
                }
            }
        }
        return nil
    }

    /// What the lines read so far have defined, by full name from the root.
    /// TOML lets a name be defined once: by a `[name]` header, by a key that
    /// holds a value (an inline table included), or as the table a dotted
    /// key implies. Only an `[[name]]` element starts over, for the names
    /// under it.
    private struct Definitions {
        private var tables: Set<Name> = []
        private var arrayTables: Set<Name> = []
        /// Names that hold a value: a key's full name.
        private var values: Set<Name> = []
        /// Tables a dotted key implied: `a.b.c = 1` under `[t]` implies
        /// `t.a` and `t.a.b`, which no header may define afterwards.
        private var dottedTables: Set<Name> = []
        /// The table the keys being read belong to.
        private var current: Name = []

        /// Whether `[name]` may define its table here.
        mutating func defineTable(_ name: Name) -> Bool {
            guard isFreeForHeader(name), !arrayTables.contains(name), tables.insert(name).inserted else {
                return false
            }
            current = name
            return true
        }

        /// Whether `[[name]]` may add an element here. A new element owns
        /// nothing yet, so whatever an earlier element defined under the
        /// name is forgotten: `[[a]]` `[a.b]` `[[a]]` `[a.b]` is valid.
        mutating func appendArrayElement(_ name: Name) -> Bool {
            guard isFreeForHeader(name), !tables.contains(name) else { return false }
            arrayTables.insert(name)
            let isUnder = { (other: Name) in other.count > name.count && other.starts(with: name) }
            tables = tables.filter { !isUnder($0) }
            arrayTables = arrayTables.filter { !isUnder($0) }
            values = values.filter { !isUnder($0) }
            dottedTables = dottedTables.filter { !isUnder($0) }
            current = name
            return true
        }

        /// Whether a key may set `key` in the current table.
        mutating func setKey(_ key: Name) -> Bool {
            let full = current + key
            guard !values.contains(full), !dottedTables.contains(full),
                  !tables.contains(full), !arrayTables.contains(full),
                  !hasValuePrefix(full)
            else { return false }
            values.insert(full)
            for length in (current.count + 1)..<full.count {
                dottedTables.insert(full.prefix(length))
            }
            return true
        }

        /// A header may not name, or reach through, a name that holds a
        /// value, nor define a table a dotted key implied.
        private func isFreeForHeader(_ name: Name) -> Bool {
            !values.contains(name) && !hasValuePrefix(name) && !dottedTables.contains(name)
        }

        private func hasValuePrefix(_ name: Name) -> Bool {
            (1..<max(name.count, 1)).contains { values.contains(name.prefix($0)) }
        }
    }

    // MARK: - Scanner

    /// A cursor over one line's Unicode scalars.
    private struct Scanner {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ line: String) {
            scalars = Array(line.unicodeScalars)
        }

        func peek(_ scalar: Unicode.Scalar) -> Bool {
            index < scalars.count && scalars[index] == scalar
        }

        /// Step past `scalar` when it is next.
        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard peek(scalar) else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while peek(" ") || peek("\t") {
                index += 1
            }
        }

        /// Whether nothing but whitespace and a comment remains.
        mutating func isAtEndOrComment() -> Bool {
            skipWhitespace()
            return index == scalars.count || peek("#")
        }

        /// A dotted name, with the whitespace around it: one or more
        /// segments, each bare, basic-quoted or literal-quoted. `nil` when
        /// no name TOML accepts starts here.
        mutating func name() -> Name? {
            var segments: [String] = []
            repeat {
                skipWhitespace()
                guard let segment = segment() else { return nil }
                segments.append(segment)
                skipWhitespace()
            } while take(".")
            return Name(segments)
        }

        private mutating func segment() -> String? {
            if take("\"") {
                return basicString()
            }
            if take("'") {
                return literalString()
            }
            let start = index
            while index < scalars.count, Self.isBare(scalars[index]) {
                index += 1
            }
            guard index > start else { return nil }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        /// The rest of a basic string whose opening quote has been taken,
        /// escapes resolved; `nil` when it is unterminated or holds an
        /// escape TOML does not define.
        private mutating func basicString() -> String? {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(out)
                case "\\":
                    guard let escaped = escape() else { return nil }
                    out.append(escaped)
                default:
                    out.append(scalar)
                }
            }
            return nil
        }

        /// The character an escape stands for, its backslash taken.
        private mutating func escape() -> Unicode.Scalar? {
            guard index < scalars.count else { return nil }
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "x": return hex(digits: 2)
            case "u": return hex(digits: 4)
            case "U": return hex(digits: 8)
            default: return nil
            }
        }

        private mutating func hex(digits: Int) -> Unicode.Scalar? {
            guard index + digits <= scalars.count,
                  scalars[index..<(index + digits)].allSatisfy(\.properties.isASCIIHexDigit),
                  let value = UInt32(String(String.UnicodeScalarView(scalars[index..<(index + digits)])), radix: 16)
            else { return nil }
            index += digits
            return Unicode.Scalar(value)
        }

        /// The rest of a literal string, which has no escapes.
        private mutating func literalString() -> String? {
            let start = index
            while index < scalars.count, scalars[index] != "'" {
                index += 1
            }
            guard index < scalars.count else { return nil }
            defer { index += 1 }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        /// TOML 1.0's bare-key characters. A header with any other bare
        /// character reads as malformed, which costs that file our hooks
        /// rather than risking a config we cannot read correctly.
        private static func isBare(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
            default: false
            }
        }
    }
}
