// ReviewGit+ReadState.swift
// Limpid — what the work tree and the index are, read in a few commands for any number of files.

import Foundation

extension ReviewGit {
    /// How many paths `hash-object` is handed at a time: a few hundred
    /// keep one run short enough that the runner's timeout is never near,
    /// and few enough runs for a range searched whole.
    static let hashBatch = 500
    /// Up to this many paths, the index is asked about them by name; more,
    /// and it is read whole (`indexEntries`).
    static let pathspecLimit = 64
    /// How many names one `ls-files` is handed when the index is too large
    /// to read whole.
    static let pathspecBatch = 256

    /// HEAD, the comparison's base, and the index entries of `paths`, read
    /// at the same time.
    static func indexState(root: URL, scope: ReviewScope, paths: Set<String>) async throws -> ReviewIndexState {
        async let head = headRevision(root: root)
        async let entries = indexEntries(paths, root: root)
        var base: String?
        if case let .branch(name) = scope {
            base = try await mergeBase(name, root: root)
        }
        return try await ReviewIndexState(head: head, base: base, entries: entries)
    }

    private static func headRevision(root: URL) async throws -> String {
        let output = try await command(["rev-parse", "--revs-only", "HEAD"], root: root)
        guard let text = String(bytes: output, encoding: .utf8) else { throw ReviewError.gitFailed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The index entries of `paths`. A few are asked for by name (the runner
    /// reads every pathspec literally); many, by reading the whole index,
    /// which costs less than matching thousands of names and never runs out
    /// of argument space; and an index too large to read whole, by name in
    /// batches. The limits are parameters for the tests that reach each way.
    static func indexEntries(
        _ paths: Set<String>,
        root: URL,
        byName: Int = pathspecLimit,
        wholeIndexLimitBytes: Int = factsStatusLimitBytes
    ) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        if paths.count <= byName {
            return try await parseIndex(command(["ls-files", "--stage", "-z", "--"] + paths.sorted(), root: root), wanted: paths)
        }
        do {
            return try await parseIndex(command(["ls-files", "--stage", "-z"], root: root, limit: wholeIndexLimitBytes), wanted: paths)
        } catch ReviewError.tooLarge {
            var entries: [String: String] = [:]
            let sorted = paths.sorted()
            var start = sorted.startIndex
            while start < sorted.endIndex {
                let batch = Array(sorted[start..<min(start + pathspecBatch, sorted.endIndex)])
                start += batch.count
                let found = try await parseIndex(command(["ls-files", "--stage", "-z", "--"] + batch, root: root), wanted: paths)
                entries.merge(found) { first, _ in first }
            }
            return entries
        }
    }

    /// `ls-files --stage -z` ("mode blob stage<TAB>path", a line per stage of
    /// a conflicted path), kept for the paths wanted. Read as bytes: a path
    /// that is not UTF-8 is someone else's, and is passed over rather than
    /// failing the whole read.
    static func parseIndex(_ data: Data, wanted: Set<String>) -> [String: String] {
        let wantedBytes = Set(wanted.map { Data($0.utf8) })
        var entries: [String: String] = [:]
        for record in data.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let pathBytes = Data(record[record.index(after: tab)...])
            guard wantedBytes.contains(pathBytes),
                  let path = String(bytes: pathBytes, encoding: .utf8),
                  let entry = String(bytes: record[..<tab], encoding: .utf8)
            else { continue }
            entries[path, default: ""] += entry + ";"
        }
        return entries
    }

    /// A path as `lstat` sees it, without following a link.
    static func pathStat(_ path: String, root: URL) -> ReviewPathStat {
        var info = Darwin.stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return .absent }
        let kind: ReviewPathStat.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .regular
        case S_IFLNK: .symlink
        case S_IFDIR: .directory
        default: .other
        }
        let modified = "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        let changed = "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        return ReviewPathStat(
            kind: kind,
            info: "\(info.st_mode):\(info.st_size):\(modified):\(changed):\(info.st_ino)",
            size: Int64(info.st_size)
        )
    }

    /// Each path's content as hashed bytes, by path, for telling whether it
    /// changed since: raw, with `--no-filters`. Raw is right here: it is
    /// compared with itself over time, not with the index, and it runs no
    /// filter process (LFS, a notebook stripper) on every poll; the price is
    /// one banner too many for a rewrite that only changes line endings,
    /// which a refresh clears.
    ///
    /// Only regular files inside the work tree and within the diff size
    /// limit are hashed, so one huge file cannot time a batch out and a link
    /// is never followed out of the repository; a symbolic link is its
    /// target's text, which a link pointed at an identical file still
    /// changes. Anything else has no hash.
    /// `maxBytes` is a parameter for the tests.
    static func contentHashes(_ paths: [String], root: URL, maxBytes: Int = maxDiffBytes) async throws -> [String: String] {
        var hashes: [String: String] = [:]
        let rootPath = root.resolvingSymlinksInPath().path
        var files: [String] = []
        for path in Set(paths) {
            let url = root.appendingPathComponent(path)
            let stat = pathStat(path, root: root)
            switch stat.kind {
            case .regular:
                guard stat.size <= Int64(maxBytes),
                      RepositoryPath.isStrictDescendant(url.resolvingSymlinksInPath().path, of: rootPath)
                else { continue }
                files.append(path)
            case .symlink:
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                    hashes[path] = "link:" + target
                }
            case .directory, .absent, .other:
                continue
            }
        }
        var start = files.startIndex
        while start < files.endIndex {
            let batch = Array(files[start..<min(start + hashBatch, files.endIndex)])
            start += batch.count
            if let found = try? await runHashObject(batch, root: root, filters: .none) {
                hashes.merge(found) { first, _ in first }
                continue
            }
            // One path of the batch failed it (removed since its `lstat`):
            // the others are asked one by one, and only that one goes
            // without a hash.
            for path in batch {
                if let found = try? await runHashObject([path], root: root, filters: .none) {
                    hashes.merge(found) { first, _ in first }
                }
            }
        }
        return hashes
    }

    /// Which blob ID `hash-object` gives a file: its bytes as they are, or as
    /// `git add` would store them, through the repository's clean filters.
    /// Each caller names it, because the two answer different questions: a
    /// comparison with a tree Git wrote needs the filtered ID, while a
    /// fingerprint that is only compared with itself must not run filters,
    /// which may write their own store.
    enum HashFilters {
        case none
        case clean
    }

    /// One `hash-object` run over `paths`, by path. Throws when Git does not
    /// answer with one hash a line for each of them, since a short answer
    /// cannot be paired with its paths.
    static func runHashObject(_ paths: [String], root: URL, filters: HashFilters) async throws -> [String: String] {
        var input = Data()
        for path in paths {
            input.append(stdinPath(path))
            input.append(0x0A)
        }
        let filterArguments = filters == .none ? ["--no-filters"] : []
        let output = try await command(["hash-object"] + filterArguments + ["--stdin-paths"], root: root, input: input)
        guard let text = String(bytes: output, encoding: .utf8) else { throw ReviewError.gitFailed }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == paths.count else { throw ReviewError.gitFailed }
        return Dictionary(zip(paths, lines), uniquingKeysWith: { first, _ in first })
    }

    /// A path as `--stdin-paths` reads it: as is, unless Git would read it
    /// otherwise. It takes a line that starts with a quote for a C-quoted
    /// one, ends the line at a newline, and drops a carriage return at its
    /// end; such a path is C-quoted (`\"`, `\\`, `\n`, `\r`, and octal for
    /// the other controls).
    static func stdinPath(_ path: String) -> Data {
        guard path.hasPrefix("\"") || path.contains("\n") || path.hasSuffix("\r") else { return Data(path.utf8) }
        var quoted = Data([0x22])
        for byte in path.utf8 {
            switch byte {
            case 0x22: quoted.append(contentsOf: Array("\\\"".utf8))
            case 0x5C: quoted.append(contentsOf: Array("\\\\".utf8))
            case 0x0A: quoted.append(contentsOf: Array("\\n".utf8))
            case 0x0D: quoted.append(contentsOf: Array("\\r".utf8))
            case 0..<0x20, 0x7F:
                // Three octal digits, as Git writes them.
                quoted.append(contentsOf: [0x5C, 0x30 + (byte >> 6), 0x30 + ((byte >> 3) & 7), 0x30 + (byte & 7)])
            default: quoted.append(byte)
            }
        }
        quoted.append(0x22)
        return quoted
    }
}
