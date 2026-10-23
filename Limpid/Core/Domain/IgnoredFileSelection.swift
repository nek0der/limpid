// IgnoredFileSelection.swift
// Limpid — which of the files Git ignores a new worktree gets a copy of, from the project's patterns.

import Foundation

/// Picks the files Git ignores that a new worktree gets a copy of,
/// from the patterns in Project Settings and what Git lists as ignored in
/// the project's folder (`git ls-files --others --ignored --exclude-standard
/// --directory`). A worktree is checked out from Git, so what Git ignores,
/// `.env` first, is what it lacks.
///
/// A pattern reads as a `.gitignore` line does, as far as a person writes
/// one for this:
/// - `*` stands for any characters but `/`, `?` for one of them, and `**`
///   for any characters, `/` among them;
/// - a pattern with no `/` but at its end names a file or folder at any
///   depth (`.env` is also `apps/web/.env`);
/// - a leading `/`, or a `/` inside, makes it a path from the project's
///   folder (`/.env` is the top one only);
/// - a trailing `/` names a folder only.
/// Git lists a folder it ignores whole once, with the slash, and a pattern
/// matching that folder copies all of it (`node_modules/`).
///
/// Only paths inside the project's folder are ever picked. A pattern or a
/// listed path that starts at the home folder (`~`), steps out with `..`,
/// or names `.git` is never used: the copy goes into the new worktree and
/// nowhere else, and never over Git's own files.
enum IgnoredFileSelection {
    /// Why a pattern is never used, said beside its row in Project Settings.
    enum Problem: Equatable, Sendable {
        case homeFolder
        case leavesFolder
        case namesGitFolder
    }

    /// A pattern as it is matched.
    struct Pattern: Equatable, Sendable {
        /// The pattern with its leading `./` or `/` and trailing `/` taken off.
        let body: String
        /// Matched against the whole path from the project's folder, not
        /// only its last part.
        let isAnchored: Bool
        let isFolderOnly: Bool

        init(_ text: String) {
            var body = text.trimmingCharacters(in: .whitespaces)
            while body.hasPrefix("./") {
                body.removeFirst(2)
            }
            var isFolderOnly = false
            while body.count > 1, body.hasSuffix("/") {
                body.removeLast()
                isFolderOnly = true
            }
            var isAnchored = false
            while body.hasPrefix("/") {
                body.removeFirst()
                isAnchored = true
            }
            self.body = body
            self.isAnchored = isAnchored || body.contains("/")
            self.isFolderOnly = isFolderOnly
        }

        /// Whether the pattern names `path`, which is a folder when
        /// `isFolder`.
        func matches(_ path: String, isFolder: Bool) -> Bool {
            guard !isFolderOnly || isFolder else { return false }
            if isAnchored {
                return IgnoredFileSelection.glob(Array(body), Array(path))
            }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            return IgnoredFileSelection.glob(Array(body), Array(name))
        }

        var hasWildcard: Bool {
            body.contains { $0 == "*" || $0 == "?" }
        }
    }

    /// The pattern a path Git listed is saved as when the person picks it
    /// from the ignored files: anchored, so it names that one path and no
    /// other of the same name deeper down.
    static func pattern(forListed path: String) -> String {
        "/" + path
    }

    /// Why `pattern` is never used; `nil` for one that is (an empty one
    /// is the list's own problem, not this one's).
    static func problem(of pattern: String) -> Problem? {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("~") {
            return .homeFolder
        }
        let parts = Pattern(text).body.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") {
            return .leavesFolder
        }
        if parts.contains(".git") {
            return .namesGitFolder
        }
        return nil
    }

    /// The paths to copy, relative to the project's folder, sorted: each
    /// ignored path a pattern matches, a folder standing for all of it,
    /// and, inside a folder Git ignores whole, the paths patterns name in
    /// full (`config/master.key` when Git lists only `config/`). A
    /// wildcard inside such a folder is not looked for: Git does not list
    /// the folder's files, and walking a `node_modules` to match one would
    /// take long. A path inside another picked folder goes with it.
    static func select(patterns: [String], ignored: [String]) -> [String] {
        let usable = patterns
            .filter { problem(of: $0) == nil }
            .map(Pattern.init)
            .filter { !$0.body.isEmpty }
        guard !usable.isEmpty else { return [] }
        var picked = Set<String>()
        for entry in ignored {
            // Git lists a folder it ignores whole with a trailing slash.
            let isFolder = entry.hasSuffix("/")
            let path = Pattern(entry).body
            guard !path.isEmpty, problem(of: path) == nil else { continue }
            if usable.contains(where: { $0.matches(path, isFolder: isFolder) }) {
                picked.insert(path)
                continue
            }
            guard isFolder else { continue }
            for pattern in usable where pattern.isAnchored && !pattern.hasWildcard && pattern.body.hasPrefix(path + "/") {
                picked.insert(pattern.body)
            }
        }
        return picked.filter { path in
            !picked.contains { other in other != path && path.hasPrefix(other + "/") }
        }
        .sorted()
    }

    /// `*` and `?` within one part of a path, `**` across parts. Memoized
    /// on the two positions, so a pattern of many stars stays polynomial
    /// in the path's length rather than trying every split.
    fileprivate static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var memo: [Int: Bool] = [:]
        func match(_ p: Int, _ t: Int) -> Bool {
            let key = p * (text.count + 1) + t
            if let known = memo[key] {
                return known
            }
            let result: Bool
            if p == pattern.count {
                result = t == text.count
            } else if pattern[p] == "*" {
                let isDouble = p + 1 < pattern.count && pattern[p + 1] == "*"
                let next = isDouble ? p + 2 : p + 1
                // `**/` also stands for no folder at all: `a/**/b` is `a/b`.
                if isDouble, next < pattern.count, pattern[next] == "/", match(next + 1, t) {
                    memo[key] = true
                    return true
                }
                var end = t
                var found = match(next, end)
                while !found, end < text.count, isDouble || text[end] != "/" {
                    end += 1
                    found = match(next, end)
                }
                result = found
            } else if t < text.count, pattern[p] == "?" ? text[t] != "/" : pattern[p] == text[t] {
                result = match(p + 1, t + 1)
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }
}
