// ReviewSyntax.swift
// Limpid — coloring code in the diff, one line at a time.

import Foundation

/// A line-at-a-time lexer, rather than a parser.
///
/// A diff is not a file: it is a set of fragments, half of them from a version
/// that no longer exists on disk, drawn a screenful at a time by a reused
/// table row. A real grammar would need the whole file and the state of every
/// line above the one being drawn, which is neither available here nor worth
/// carrying — so this reads each line on its own and settles for the four
/// things that make code legible at a glance.
///
/// The known cost is a block that spans lines: the body of a `/* … */` or a
/// docstring is lexed as code, because the line drawing it cannot see where it
/// began. Line comments, strings and numbers, which is most of what a reader
/// scans for, are exact.
enum ReviewSyntax {
    enum Kind: Equatable {
        case keyword, string, number, comment
    }

    struct Token: Equatable {
        let range: Range<String.Index>
        let kind: Kind
    }

    /// What one family of languages looks like. Held as data rather than as
    /// cases with behavior: the differences between them are these four
    /// fields, and a switch per character would be slower for no gain.
    struct Language {
        let lineComments: [String]
        let blockComment: (open: String, close: String)?
        let quotes: [Character]
        let keywords: Set<String>
        /// Characters that begin a word the language treats as reserved —
        /// Swift's attributes and directives, a shell's variables. A word
        /// starting with one is colored whether or not it is in `keywords`,
        /// because the set of them is open-ended.
        let sigils: Set<Character>
    }

    /// The language a path is written in, or `nil` for one this does not know
    /// — where the line is drawn plain rather than guessed at.
    static func language(for path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": swift
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "go", "rs", "zig": cFamily
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": webScript
        case "py", "rb", "pyi": scripting
        case "sh", "bash", "zsh", "fish", "yml", "yaml", "toml": shell
        case "json": json
        default: nil
        }
    }

    // MARK: - Languages

    private static let swift = Language(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\""],
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
            "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else",
            "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get",
            "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "lazy", "let",
            "mutating", "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override",
            "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "set",
            "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
            "typealias", "unowned", "var", "weak", "where", "while", "willSet"
        ],
        sigils: ["@", "#"]
    )

    /// One set for the curly-brace languages, including Go and Rust. A union
    /// rather than a table per language: what it costs is a word that is
    /// reserved elsewhere being colored where it is an ordinary identifier,
    /// and what it buys is not carrying a dozen nearly identical lists.
    private static let cFamily = Language(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'"],
        keywords: [
            "abstract", "async", "auto", "await", "bool", "break", "case", "catch", "char", "class",
            "const", "constexpr", "continue", "crate", "default", "defer", "delete", "do", "double",
            "else", "enum", "extends", "extern", "false", "final", "float", "fn", "for", "func", "go",
            "goto", "if", "impl", "implements", "import", "in", "inline", "instanceof", "int",
            "interface", "let", "long", "loop", "map", "match", "mod", "move", "mut", "namespace", "new",
            "nil", "null", "override", "package", "private", "protected", "pub", "public", "range",
            "return", "self", "short", "signed", "sizeof", "static", "struct", "super", "switch", "this",
            "throw", "throws", "trait", "true", "try", "type", "typedef", "typeof", "union", "unsafe",
            "unsigned", "use", "using", "val", "var", "virtual", "void", "volatile", "when", "where",
            "while", "yield"
        ],
        sigils: []
    )

    private static let webScript = Language(
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\"", "'", "`"],
        keywords: [
            "as", "async", "await", "break", "case", "catch", "class", "const", "constructor",
            "continue", "declare", "default", "delete", "do", "else", "enum", "export", "extends",
            "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
            "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public",
            "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw",
            "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        sigils: []
    )

    /// Python and Ruby together: both comment with `#`, and their reserved
    /// words barely overlap in a way a reader would notice.
    private static let scripting = Language(
        lineComments: ["#"],
        blockComment: nil,
        quotes: ["\"", "'"],
        keywords: [
            "and", "as", "assert", "async", "await", "begin", "break", "class", "continue", "def",
            "del", "do", "elif", "else", "elsif", "end", "ensure", "except", "False", "finally", "for",
            "from", "global", "if", "import", "in", "is", "lambda", "module", "next", "nil", "None",
            "nonlocal", "not", "or", "pass", "raise", "require", "rescue", "return", "self", "then",
            "True", "try", "unless", "until", "while", "with", "yield"
        ],
        sigils: []
    )

    private static let shell = Language(
        lineComments: ["#"],
        blockComment: nil,
        quotes: ["\"", "'"],
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for", "function",
            "if", "in", "local", "readonly", "return", "set", "shift", "source", "then", "unset",
            "until", "while"
        ],
        sigils: ["$"]
    )

    /// Structure only: JSON has no keywords worth the name, and coloring its
    /// three literals is what tells a value from a key at a glance.
    private static let json = Language(
        lineComments: [],
        blockComment: nil,
        quotes: ["\""],
        keywords: ["true", "false", "null"],
        sigils: []
    )

    // MARK: - Lexing

    /// Every colored run in one line, in the order they appear.
    static func tokens(in line: String, language: Language) -> [Token] {
        guard !line.isEmpty else { return [] }
        var result: [Token] = []
        var index = line.startIndex
        while index < line.endIndex {
            if let comment = comment(in: line, at: index, language: language) {
                result.append(comment)
                index = comment.range.upperBound
                continue
            }
            if language.quotes.contains(line[index]) {
                let token = string(in: line, from: index)
                result.append(token)
                index = token.range.upperBound
                continue
            }
            // ASCII only: `isNumber` is also true for `½`, `②` and the digits
            // of other scripts, none of which a literal in these languages is
            // written with, and all of which would be marked as one.
            if line[index].isNumber, line[index].isASCII, !isWord(line, before: index) {
                let token = number(in: line, from: index)
                result.append(token)
                index = token.range.upperBound
                continue
            }
            if isWordStart(line[index], language: language) {
                let end = wordEnd(in: line, from: index)
                let word = String(line[index..<end])
                if language.sigils.contains(line[index]) || language.keywords.contains(word) {
                    result.append(Token(range: index..<end, kind: .keyword))
                }
                index = end
                continue
            }
            index = line.index(after: index)
        }
        return result
    }

    /// A comment runs to the end of the line either way: a block that closes
    /// on the same line stops there, and one that does not has nothing after
    /// it on this line that could be anything else.
    private static func comment(in line: String, at index: String.Index, language: Language) -> Token? {
        for marker in language.lineComments where line[index...].hasPrefix(marker) {
            return Token(range: index..<line.endIndex, kind: .comment)
        }
        guard let block = language.blockComment, line[index...].hasPrefix(block.open) else { return nil }
        let body = line.index(index, offsetBy: block.open.count)
        guard let close = line.range(of: block.close, range: body..<line.endIndex) else {
            return Token(range: index..<line.endIndex, kind: .comment)
        }
        return Token(range: index..<close.upperBound, kind: .comment)
    }

    /// Unterminated strings end with the line. A diff cuts lines wherever the
    /// change did, so a run that never closes is ordinary here.
    private static func string(in line: String, from index: String.Index) -> Token {
        let quote = line[index]
        var cursor = line.index(after: index)
        while cursor < line.endIndex {
            if line[cursor] == "\\" {
                cursor = line.index(cursor, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if line[cursor] == quote {
                return Token(range: index..<line.index(after: cursor), kind: .string)
            }
            cursor = line.index(after: cursor)
        }
        return Token(range: index..<line.endIndex, kind: .string)
    }

    /// Always past the first character. `isNumber` is true for characters no
    /// literal is written with — `½`, `②`, Eastern Arabic digits — and none of
    /// them continue the run below, so a token that started on one would be
    /// empty and the scan would never move past it.
    private static func number(in line: String, from index: String.Index) -> Token {
        var cursor = line.index(after: index)
        while cursor < line.endIndex, line[cursor].isHexDigit || "._xXbBoOeE".contains(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return Token(range: index..<cursor, kind: .number)
    }

    /// Always past the first character, which may be a sigil rather than a
    /// word character — without that this would return where it started and
    /// the scan would never move.
    private static func wordEnd(in line: String, from index: String.Index) -> String.Index {
        var cursor = line.index(after: index)
        while cursor < line.endIndex, isWord(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    /// Whether the character before `index` is part of a word, which is what
    /// makes a keyword a whole word rather than the start of a longer name:
    /// `information` must not light up because it begins with `in`.
    private static func isWord(_ line: String, before index: String.Index) -> Bool {
        guard index > line.startIndex else { return false }
        return isWord(line[line.index(before: index)])
    }

    private static func isWordStart(_ character: Character, language: Language) -> Bool {
        character.isLetter || character == "_" || language.sigils.contains(character)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
