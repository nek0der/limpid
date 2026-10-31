// IgnoredFilesDraft.swift
// Weir — a project's files to copy into new worktrees as the list the person edits in Project Settings.

import Foundation

/// The list form of `Project.ignoredFilesToCopy`: one row per path or
/// pattern, added with ＋, from the files Git ignores, or removed with −,
/// as `CheckCommandsDraft` edits the test commands. The patterns are a set,
/// so the order of the rows means nothing.
///
/// A row that cannot be used is kept on screen with a mark and left out of
/// what is saved, so the person sees why it does nothing instead of it
/// vanishing: an empty row, a second copy of a pattern, and one that would
/// reach outside the project's folder or into `.git`
/// (`IgnoredFileSelection.problem`).
struct IgnoredFilesDraft: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        var text: String
    }

    /// Why a row is not saved.
    enum Problem: Equatable {
        case empty
        case duplicate
        case unsafe(IgnoredFileSelection.Problem)
    }

    private(set) var rows: [Row]

    init(patterns: [String]?) {
        rows = (patterns ?? []).map { Row(id: UUID(), text: $0) }
    }

    /// Appends a row and returns it, so the view can put the cursor in it.
    @discardableResult
    mutating func add(_ text: String = "") -> Row.ID {
        let row = Row(id: UUID(), text: text)
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

    /// Whether a row names `path` as Git lists it: the anchored pattern
    /// the ignored files' menu adds for it.
    func contains(_ path: String) -> Bool {
        let wanted = IgnoredFileSelection.Pattern(IgnoredFileSelection.pattern(forListed: path))
        return rows.contains { IgnoredFileSelection.Pattern($0.text) == wanted }
    }

    /// "Choose from Ignored Files…": adds a row naming `path` and no other
    /// of its name, or removes the rows that name it, as its check says.
    mutating func toggle(_ path: String) {
        guard contains(path) else {
            add(IgnoredFileSelection.pattern(forListed: path))
            return
        }
        let wanted = IgnoredFileSelection.Pattern(IgnoredFileSelection.pattern(forListed: path))
        rows.removeAll { IgnoredFileSelection.Pattern($0.text) == wanted }
    }

    /// Why `id` is not saved, or nil when it is. The row being typed in is
    /// not marked empty: a row just added is empty until the person types.
    /// Of two copies, the later one is marked, so the first keeps counting.
    func problem(of id: Row.ID, editing: Row.ID? = nil) -> Problem? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let text = rows[index].text
        let pattern = IgnoredFileSelection.Pattern(text)
        if pattern.body.isEmpty {
            return id == editing ? nil : .empty
        }
        if let unsafe = IgnoredFileSelection.problem(of: text) {
            return .unsafe(unsafe)
        }
        let isRepeated = rows[..<index].contains { IgnoredFileSelection.Pattern($0.text) == pattern }
        return isRepeated ? .duplicate : nil
    }

    /// What is saved: the rows without a problem, trimmed, or nil when
    /// there are none, as a project that never named any has.
    var patterns: [String]? {
        let saved = rows
            .filter { problem(of: $0.id) == nil }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
        return saved.isEmpty ? nil : saved
    }

    /// What one edit saves.
    enum Save: Equatable {
        /// What would be saved is as it was: a typed row not finished, an
        /// empty row added. Nothing is written.
        case nothing
        case patterns([String]?)
    }

    /// What the edit from `old` to `new` saves. Only an edit saves: the
    /// sheet loading a project's list never calls this, so opening the
    /// sheet never rewrites what is stored.
    static func save(from old: Self, to new: Self) -> Save {
        new.patterns == old.patterns ? .nothing : .patterns(new.patterns)
    }
}
