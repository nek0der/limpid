// ReviewGit+OutsideTurns.swift
// Weir — the Git comparisons that find what changed outside every turn, read without writing.

import Foundation

/// What `WorktreeChanges` asks Git: the paths between two snapshot trees,
/// the worktree's paths changed since one, and what is uncommitted now.
/// Each reads only. The count runs every ten seconds while the changes
/// panel shows, and must not fill the object store with every edited and
/// untracked file.
extension ReviewGit {
    /// The paths that differ between two trees. Throws `gitFailed` when one
    /// of them is gone.
    static func pathsChanged(from earlier: String, to later: String, at root: URL) async throws -> Set<String> {
        // Without rename detection, so a renamed file's old path counts too.
        try await Set(splitPaths(command(["diff", "--no-renames", "--name-only", "-z", earlier, later, "--"], root: root)))
    }

    /// What changed in the worktree since a tree (`pathsChanged(since:)`).
    struct ChangedSince: Equatable, Sendable {
        var paths: Set<String>
        /// The blob ID each untracked file the tree held hashed to, with
        /// the file's size, times, inode, and mode as `ContentFingerprint`
        /// keeps them: what the next count hands back as `known`.
        var untrackedHashes: [String: ContentFingerprint] = [:]
    }

    /// The paths of the worktree that differ from `tree` now, untracked
    /// ones included; none when the tree is gone, which says nothing is
    /// known. The tracked paths are compared against the tree, and each
    /// untracked path the tree holds is compared without being written.
    ///
    /// An untracked file whose stat matches `known` keeps the blob ID it
    /// hashed to then. The count runs every ten seconds and on every turn
    /// change, and hashing every untracked file the snapshot held read all
    /// of them each time: five hundred files of a megabyte were half a
    /// gigabyte a count. The ID depends on the contents alone, not on the
    /// tree, so one kept across trees still holds.
    static func pathsChanged(
        since tree: String,
        at root: URL,
        known: [String: ContentFingerprint] = [:]
    ) async throws -> ChangedSince {
        // Only a tree the retention sweep deleted is "nothing known"; any
        // other failure of Git's is thrown, and the count before stands.
        do {
            _ = try await command(["cat-file", "-e", tree + "^{tree}"], root: root)
        } catch ReviewError.gitFailed {
            return ChangedSince(paths: [])
        }
        var paths = try await Set(splitPaths(command(["diff", "--no-renames", "--name-only", "-z", tree, "--"], root: root)))
        let untracked = try await splitPaths(command(["ls-files", "--others", "--exclude-standard", "-z"], root: root))
        guard !untracked.isEmpty else { return ChangedSince(paths: paths) }
        // A nested repository is listed as its directory ("sub/"); the tree
        // holds it at the path itself.
        let names = untracked.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        // The diff reads the worktree through the index, so it calls every
        // untracked path the tree holds deleted; the snapshot took untracked
        // files in, and only their contents say whether they changed.
        paths.subtract(names)
        let recorded = try await entries(of: names, in: tree, root: root)
        var files: [String] = []
        for (listed, name) in zip(untracked, names) {
            guard let held = recorded[name] else {
                // The tree did not hold it: new since.
                paths.insert(name)
                continue
            }
            if listed.hasSuffix("/") {
                // Another repository's work is its own: only whether it is
                // here counts.
                if held.mode != "160000" {
                    paths.insert(name)
                }
            } else if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(name).path) {
                if try await !isLink(held, to: target, root: root) {
                    paths.insert(name)
                }
            } else {
                files.append(name)
            }
        }
        let hashed = try await hashedChanges(of: files, recorded: recorded, known: known, root: root)
        return ChangedSince(paths: paths.union(hashed.changed), untrackedHashes: hashed.hashes)
    }

    /// Which of the untracked `files` the tree held differ from it now, by
    /// contents or by whether they are executable, and the blob ID each
    /// hashed to. One whose stat matches `known` is not hashed again.
    private static func hashedChanges(
        of files: [String],
        recorded: [String: TreeEntry],
        known: [String: ContentFingerprint],
        root: URL
    ) async throws -> (changed: Set<String>, hashes: [String: ContentFingerprint]) {
        var changed: Set<String> = []
        var hashes: [String: ContentFingerprint] = [:]
        var stats: [String: String] = [:]
        var unhashed: [String] = []
        // Whether each file is executable now: the tree records its mode,
        // and git's diff shows a file made executable.
        var executables: Set<String> = []
        func isChanged(_ path: String, id: Substring) -> Bool {
            recorded[path]?.id != id || (recorded[path]?.mode == "100755") != executables.contains(path)
        }
        for file in files {
            let status = regularFileStatus(at: root.appendingPathComponent(file).path)
            if status?.isExecutable == true {
                executables.insert(file)
            }
            if let status, let held = known[file], held.stat == status.stat {
                hashes[file] = held
            } else {
                unhashed.append(file)
                stats[file] = status?.stat
            }
        }
        for chunk in chunks(unhashed) {
            // Through the clean filters: the ID is compared with the one the
            // tree recorded, which `git add` stored that way.
            let ids = try await runHashObject(chunk, root: root, filters: .clean)
            for path in chunk {
                guard let id = ids[path] else { continue }
                if let stat = stats[path] {
                    hashes[path] = ContentFingerprint(contents: id, stat: stat)
                } else if isChanged(path, id: Substring(id)) {
                    // Not a regular file a stat could hold back: only said.
                    changed.insert(path)
                }
            }
        }
        for (path, held) in hashes where isChanged(path, id: Substring(held.contents)) {
            changed.insert(path)
        }
        return (changed, hashes)
    }

    /// What a path holds, as a string that differs whenever its contents
    /// do, with the file's size, times, inode, and executable bit, which
    /// say when it need not be hashed again.
    struct ContentFingerprint: Equatable, Sendable {
        let contents: String
        /// `nil` for what is not a regular file.
        let stat: String?
    }

    /// What each of `paths` holds in the worktree now: a file's blob ID
    /// (hashed, never written, and without the clean filters, which may
    /// write their own store), marked when the file is executable, since
    /// git's diff shows a file made so (only then, so marks stored before
    /// the mode was kept still match the others); a link's target; or that
    /// it is gone. A repository with `core.fileMode` off shows no mode
    /// change, and its chmod alone reads as unviewed again here, the safe
    /// side, which reading its settings is not worth. A file
    /// whose size, modification and change times, and inode match `known`
    /// keeps its known contents, since this runs every ten seconds while
    /// the changes panel shows. The change time is the one no tool can set
    /// back, so a rewrite that keeps the modification time is still seen.
    /// What was viewed of the changes outside turns is these
    /// (`ViewedLineStore.outsideTurns`).
    static func contentFingerprints(
        of paths: Set<String>,
        at root: URL,
        known: [String: ContentFingerprint] = [:]
    ) async throws -> [String: ContentFingerprint] {
        var fingerprints: [String: ContentFingerprint] = [:]
        var stats: [String: String] = [:]
        var executables: Set<String> = []
        for path in paths.sorted() {
            let location = root.appendingPathComponent(path).path
            // Not followed: a link is its target, as Git records it.
            var info = Darwin.stat()
            guard lstat(location, &info) == 0 else {
                fingerprints[path] = ContentFingerprint(contents: "gone", stat: nil)
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: location)) ?? ""
                fingerprints[path] = ContentFingerprint(contents: "link:" + target, stat: nil)
            case S_IFREG:
                let stat = statKey(info)
                if let held = known[path], held.stat == stat {
                    fingerprints[path] = held
                } else {
                    stats[path] = stat
                    if info.st_mode & S_IXUSR != 0 {
                        executables.insert(path)
                    }
                }
            default:
                // Neither a file nor a link: a nested repository, whose work
                // is its own, or something Git does not track.
                fingerprints[path] = ContentFingerprint(contents: "other", stat: nil)
            }
        }
        for chunk in chunks(stats.keys.sorted()) {
            let ids = try await runHashObject(chunk, root: root, filters: .none)
            for path in chunk {
                guard let id = ids[path] else { continue }
                let mode = executables.contains(path) ? ":executable" : ""
                fingerprints[path] = ContentFingerprint(contents: "blob:" + id + mode, stat: stats[path])
            }
        }
        return fingerprints
    }

    /// The paths with uncommitted changes now: staged, unstaged, and
    /// untracked.
    static func uncommittedPaths(at root: URL) async throws -> Set<String> {
        try await Set(files(at: root, scope: .uncommitted).map(\.path))
    }

    private struct TreeEntry {
        let mode: Substring
        let id: Substring
    }

    /// What `tree` holds at each of `paths`, by path.
    private static func entries(of paths: [String], in tree: String, root: URL) async throws -> [String: TreeEntry] {
        var entries: [String: TreeEntry] = [:]
        for chunk in chunks(paths) {
            let listing = try await command(["ls-tree", "-z", tree, "--"] + chunk, root: root)
            for entry in listing.split(separator: 0) {
                // "<mode> <type> <id>\t<path>"
                guard let line = String(data: entry, encoding: .utf8), let tab = line.firstIndex(of: "\t") else { continue }
                let fields = line[..<tab].split(separator: " ")
                if fields.count == 3 {
                    entries[String(line[line.index(after: tab)...])] = TreeEntry(mode: fields[0], id: fields[2])
                }
            }
        }
        return entries
    }

    /// Whether the tree held a link to `target`. A link's blob is its
    /// target, which `hash-object` would follow instead.
    private static func isLink(_ held: TreeEntry, to target: String, root: URL) async throws -> Bool {
        guard held.mode == "120000" else { return false }
        return try await command(["cat-file", "blob", String(held.id)], root: root) == Data(target.utf8)
    }

    /// The stat of the regular file at `path` (`statKey`), and whether it
    /// is executable, as git reads it; `nil` for anything else.
    private static func regularFileStatus(at path: String) -> (stat: String, isExecutable: Bool)? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return (statKey(info), info.st_mode & S_IXUSR != 0)
    }

    /// A file's size, modification and change times, inode, and whether it
    /// is executable, which say when it need not be hashed again. The mode
    /// too: a volume that keeps times to the second may see a chmod in the
    /// same second as nothing.
    private static func statKey(_ info: Darwin.stat) -> String {
        [
            "\(info.st_size)",
            "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)",
            "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)",
            "\(info.st_ino)",
            "\(info.st_mode & S_IXUSR)"
        ].joined(separator: ":")
    }

    /// Paths in groups small enough for one command line.
    private static func chunks(_ paths: [String]) -> [[String]] {
        stride(from: 0, to: paths.count, by: 200).map { Array(paths[$0..<min($0 + 200, paths.count)]) }
    }
}
