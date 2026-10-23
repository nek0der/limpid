// CheckCommandsDraft.swift
// Limpid — a project's test commands as the list the person edits in Project Settings.

import Foundation

/// The list form of `Project.checkCommands`: one row per pattern, added with
/// ＋ and removed with −, as macOS edits a list. The patterns are a set, not
/// steps, so the order of the rows means nothing.
///
/// A row that cannot be a pattern is kept on screen with a mark and left out
/// of what is saved, so the person sees why it does not count instead of it
/// vanishing: an empty row, a second copy of a pattern, and a `*` anywhere
/// but the end (the hook only reads a trailing `*`, `checks.rs`).
struct CheckCommandsDraft: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        var text: String
    }

    /// Why a row is not saved.
    enum Problem: Equatable {
        case empty
        case duplicate
        case misplacedWildcard
    }

    private(set) var rows: [Row]
    /// The patterns a project follows until it sets its own.
    let defaults: [String]

    /// The rows for a project's commands: its own, or the defaults it
    /// follows. An empty list is no rows: the project shows no tests.
    init(commands: [String]?, defaults: [String]) {
        self.defaults = defaults
        rows = (commands ?? defaults).map { Row(id: UUID(), text: $0) }
    }

    /// Appends an empty row and returns it, so the view can put the cursor in it.
    @discardableResult
    mutating func add() -> Row.ID {
        let row = Row(id: UUID(), text: "")
        rows.append(row)
        return row.id
    }

    mutating func remove(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
    }

    mutating func setText(_ text: String, of id: Row.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
    }

    mutating func restoreDefaults() {
        rows = defaults.map { Row(id: UUID(), text: $0) }
    }

    /// The pattern a row's text stands for: words split on whitespace, as
    /// the hook splits them, so `cargo  test` is the same pattern as
    /// `cargo test`.
    static func pattern(of text: String, normalizing: (String) -> String = { $0 }) -> String {
        normalizing(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Why `id` is not saved, or nil when it is. The row being typed in is
    /// not marked empty: a row just added is empty until the person types.
    /// Of two copies, the later one is marked, so the first keeps counting.
    func problem(
        of id: Row.ID,
        editing: Row.ID? = nil,
        normalizing: (String) -> String = { $0 }
    ) -> Problem? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let pattern = Self.pattern(of: rows[index].text, normalizing: normalizing)
        if pattern.isEmpty {
            return id == editing ? nil : .empty
        }
        if let star = pattern.firstIndex(of: "*"), star != pattern.index(before: pattern.endIndex) {
            return .misplacedWildcard
        }
        let isRepeated = rows[..<index].contains {
            Self.pattern(of: $0.text, normalizing: normalizing) == pattern
        }
        return isRepeated ? .duplicate : nil
    }

    /// What is saved: the rows without a problem, or nil when they are the
    /// defaults, so a project that never changed them follows the defaults
    /// when a later build changes them. Order does not count toward "the
    /// defaults", since the patterns are a set.
    func commands(normalizing: (String) -> String = { $0 }) -> [String]? {
        let saved = rows
            .filter { problem(of: $0.id, normalizing: normalizing) == nil }
            .map { Self.pattern(of: $0.text, normalizing: normalizing) }
        let isDefaults = saved.count == defaults.count && Set(saved) == Set(defaults)
        return isDefaults ? nil : saved
    }

    /// What one edit saves.
    enum Save: Equatable {
        /// What would be saved is as it was: a typed row not finished, an
        /// empty row added. Nothing is written.
        case nothing
        case commands([String]?)
    }

    /// What the edit from `old` to `new` saves. Only an edit saves: the
    /// sheet loading a project's list never calls this, so opening the
    /// sheet never rewrites what is stored (a list equal to the defaults in
    /// another order would otherwise turn into nil).
    static func save(from old: Self, to new: Self, normalizing: (String) -> String = { $0 }) -> Save {
        let commands = new.commands(normalizing: normalizing)
        return commands == old.commands(normalizing: normalizing) ? .nothing : .commands(commands)
    }

    /// Whether the list differs from the defaults, which is when
    /// "Restore Default" is offered. A marked row the defaults lack counts:
    /// restoring is also how the person clears it.
    func differsFromDefaults(normalizing: (String) -> String = { $0 }) -> Bool {
        commands(normalizing: normalizing) != nil || rows.count != defaults.count
    }
}
