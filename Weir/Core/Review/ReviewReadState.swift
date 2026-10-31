// ReviewReadState.swift
// Weir — what a file was when its diff was read, and whether it still is.

import Foundation

/// HEAD, the comparison's base, and index entries, read once for many files.
struct ReviewIndexState: Equatable, Sendable {
    let head: String?
    /// The merge base the branch comparison reads from; `nil` for the others.
    let base: String?
    /// "mode blob stage;" for each stage of each path asked about, by path;
    /// a path the index does not hold is absent.
    let entries: [String: String]
}

/// A path of the work tree as `lstat` sees it, without following a link.
struct ReviewPathStat: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case regular, symlink, directory, absent, other
    }

    let kind: Kind
    /// Mode (first), size, modification and status-change times, and inode;
    /// "absent" when there is no such path.
    let info: String
    let size: Int64

    static let absent = ReviewPathStat(kind: .absent, info: "absent", size: 0)
}

/// What a file was just before its diff was read, the way Git's own stat
/// information sees it: HEAD and the base, the file's index entry, its
/// size, times, inode and mode in the work tree, and its content's hash (a
/// link's target, for a symbolic link).
///
/// What it sees: a write, a `touch`, a mode change, a file replaced or
/// removed, a link pointed elsewhere, a stage or unstage, a commit or a
/// HEAD that moved by itself (`reset --soft`, `--amend`), and a base that
/// moved. What it does not: a change to the repository's configuration or
/// attributes that makes Git diff the same bytes differently. A file whose
/// state cannot be taken, and a submodule (`ReviewChangeCheck.isWatchable`),
/// is checked by its diff's fingerprint instead, as the open file is.
struct ReviewReadState: Equatable, Sendable {
    let head: String?
    let base: String?
    let index: String?
    let stat: String
    /// `nil` when the content was not hashed (too large, or outside the
    /// work tree through a link); a later change of its stat then counts as
    /// a change.
    let hash: String?
}

/// Whether the files the review tab has read have changed since.
/// Taken before each read, so a change racing a read raises the banner once
/// too often rather than never.
enum ReviewChangeCheck {
    enum Verdict: Equatable {
        case unchanged
        /// Staged, unstaged, committed under, or rebased: no need to look at
        /// the content.
        case changed
        /// Its stat moved: the content's hash decides.
        case needsContent
    }

    /// One file, from what was recorded and what is now.
    static func verdict(_ recorded: ReviewReadState, path: String, index: ReviewIndexState, stat: String) -> Verdict {
        guard recorded.head == index.head, recorded.base == index.base, recorded.index == index.entries[path] else {
            return .changed
        }
        guard recorded.stat != stat else { return .unchanged }
        // A new mode (or a file gone, or come) is a change of its own: Git
        // diffs the mode, and the content cannot say so.
        return mode(of: recorded.stat) == mode(of: stat) ? .needsContent : .changed
    }

    /// The mode part of `ReviewPathStat.info`, which leads it.
    private static func mode(of stat: String) -> Substring {
        stat.prefix { $0 != ":" }
    }

    /// A file whose stat moved: changed unless its content hashes as it did.
    static func isChanged(_ recorded: ReviewReadState, currentHash: String?) -> Bool {
        guard let before = recorded.hash, let currentHash else { return true }
        return before != currentHash
    }

    /// Whether a path's state says what its diff would: not a submodule
    /// (a gitlink in the index, a directory in the work tree), whose diff is
    /// the commit it points at and not anything its stat shows.
    static func isWatchable(index entry: String?, stat: ReviewPathStat) -> Bool {
        stat.kind != .directory && entry?.hasPrefix("160000") != true
    }

    /// Records the state of `paths`, by path: one index read, a stat each,
    /// and batched hashes. A path left out (the index could not be read, or
    /// it is a submodule) is checked by its diff's fingerprint instead.
    static func take(
        _ paths: Set<String>,
        git: any ReviewRepositoryReading,
        root: URL,
        scope: ReviewScope
    ) async -> [String: ReviewReadState] {
        guard !paths.isEmpty, let index = try? await git.indexState(root: root, scope: scope, paths: paths) else { return [:] }
        let ordered = Array(paths)
        let stats = git.fileStats(ordered, root: root)
        let watched = ordered.filter { isWatchable(index: index.entries[$0], stat: stats[$0] ?? .absent) }
        let hashes = await (try? git.contentHashes(watched, root: root)) ?? [:]
        var states: [String: ReviewReadState] = [:]
        for path in watched {
            states[path] = ReviewReadState(
                head: index.head,
                base: index.base,
                index: index.entries[path],
                stat: (stats[path] ?? .absent).info,
                hash: hashes[path]
            )
        }
        return states
    }

    /// Whether any of `recorded` is not what it was: one index read, a stat
    /// each, and one batched hash read for those whose stat moved. A path
    /// can come twice (its staged and its unstaged diff, read at different
    /// times). `nil` when the index cannot be read: the caller then asks
    /// the diffs' fingerprints.
    static func anyChanged(
        _ recorded: [(path: String, state: ReviewReadState)],
        git: any ReviewRepositoryReading,
        root: URL,
        scope: ReviewScope
    ) async -> Bool? {
        guard !recorded.isEmpty else { return false }
        let paths = Set(recorded.map(\.path))
        guard let index = try? await git.indexState(root: root, scope: scope, paths: paths) else { return nil }
        let stats = git.fileStats(Array(paths), root: root)
        var toHash: [(path: String, state: ReviewReadState)] = []
        for (path, state) in recorded {
            switch verdict(state, path: path, index: index, stat: (stats[path] ?? .absent).info) {
            case .unchanged: continue
            case .changed: return true
            case .needsContent: toHash.append((path, state))
            }
        }
        guard !toHash.isEmpty else { return false }
        // Not hashed is not unchanged: the stat moved and nothing says the
        // content did not.
        let hashes = await (try? git.contentHashes(Array(Set(toHash.map(\.path))), root: root)) ?? [:]
        return toHash.contains { isChanged($0.state, currentHash: hashes[$0.path]) }
    }
}
