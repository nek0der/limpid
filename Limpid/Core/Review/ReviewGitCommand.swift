// ReviewGitCommand.swift
// Limpid — cancellable, bounded byte output for machine-readable Git queries.

import Foundation

/// Publishes only the newest completed refresh for one canonical read index.
/// `add -A` finishes out of order when a poll overlaps an explicit operation;
/// allowing the older completion to win would make later validation go back
/// to an earlier working-tree snapshot.
final class ReviewTurnIndexPublisher: @unchecked Sendable {
    static let shared = ReviewTurnIndexPublisher()

    private let lock = NSLock()
    private var latestTokens: [String: UUID] = [:]

    func begin(for indexPath: String) -> UUID {
        lock.withLock {
            let token = UUID()
            latestTokens[indexPath] = token
            return token
        }
    }

    func publish(stagingPath: String, to indexPath: String, token: UUID) throws {
        try lock.withLock {
            guard latestTokens[indexPath] == token else { throw CancellationError() }
            guard rename(stagingPath, indexPath) == 0 else { throw ReviewError.gitFailed }
            latestTokens.removeValue(forKey: indexPath)
        }
    }
}

/// We serialize process lifecycle and shared results with a lock. Each pipe has one reader.
private final class ReviewGitCommand: @unchecked Sendable {
    /// How long one Git call may take before it is terminated. Long enough for
    /// a cold index on a large repository, short enough that a wedged filter
    /// process does not hold the surface.
    static let timeout: TimeInterval = 10
    /// Grace between `SIGTERM` and `SIGKILL`.
    static let killAfter: TimeInterval = 0.2
    private static let watchdogQueue = DispatchQueue(label: "dev.limpid.review.git.watchdog")
    static let readChunk = 8192

    private let lock = NSLock()
    private let process = Process()
    private var isCancelled = false
    private var hasExceededLimit = false
    /// Set by the watchdog and by the drain fallback. Kept apart from
    /// `isCancelled`, which belongs to the caller: reporting our own timeout as
    /// the reader's cancellation put `CancellationError` — a Swift type with no
    /// message of ours — in front of them, and nothing cleared it.
    private var hasTimedOut = false
    /// Set when a pipe read threw. The process may still exit zero, and
    /// answering with a truncated payload would be worse than failing.
    private var hasReadFailed = false
    private var output = Data()

    func cancel() {
        lock.withLock { isCancelled = true }
        terminate()
    }

    /// Stop the process without saying who asked. `cancel` and the watchdog
    /// both end here; which of them it was decides the error, and that is
    /// recorded separately.
    private func terminate() {
        lock.withLock {
            if process.isRunning {
                process.terminate()
            }
        }
        Self.watchdogQueue.asyncAfter(deadline: .now() + Self.killAfter) { [self] in
            lock.withLock {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func run(arguments: [String], root: URL, limit: Int, environment additions: [String: String] = [:]) throws -> Data {
        let stdout = Pipe()
        let stderr = Pipe()
        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            // `env` so a Homebrew git on `PATH` wins, the same way `GitProcess`
            // resolves it — a repository written by a newer git can be
            // unreadable to the one in `/usr/bin`.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + [
                "--literal-pathspecs",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.quotePath=true",
                "-c",
                "diff.suppressBlankEmpty=false"
            ] + arguments
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            // Repository identity comes from root, never an inherited shell override.
            for key in Array(environment.keys) where key.hasPrefix("GIT_") {
                environment.removeValue(forKey: key)
            }
            for (key, value) in additions {
                environment[key] = value
            }
            environment["LC_ALL"] = "C"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
        }
        let timeout = DispatchWorkItem { [self] in
            lock.withLock { hasTimedOut = true }
            terminate()
        }
        Self.watchdogQueue.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
        defer { timeout.cancel() }
        let group = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            group.enter()
            DispatchQueue.global().async { [self] in
                defer { group.leave() }
                let data = read(pipe.fileHandleForReading, limit: limit, isPayload: !isError)
                if !isError {
                    lock.withLock { output = data }
                }
            }
        }
        process.waitUntilExit()
        // Bounded. The watchdog only reaches the process we started, and a
        // grandchild that inherited the write end of the pipe keeps the reader
        // blocked past it — which would leave this call, and the continuation
        // waiting on it, alive for the life of the app. Closing the read end
        // is what unblocks the reader.
        if group.wait(timeout: .now() + 2) == .timedOut {
            lock.withLock { hasTimedOut = true }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 1)
        }
        return try lock.withLock {
            // Ordered by what the caller can act on. The size limit terminates
            // the process too, so it has to answer first; our own timeout and a
            // failed read are ours to name; only what the caller asked for
            // becomes a cancellation.
            if hasExceededLimit {
                throw ReviewError.tooLarge
            }
            if hasTimedOut {
                throw ReviewError.timedOut
            }
            if hasReadFailed {
                throw ReviewError.gitFailed
            }
            guard !isCancelled else { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw ReviewError.gitFailed }
            return output
        }
    }

    private func read(_ handle: FileHandle, limit: Int, isPayload: Bool) -> Data {
        var data = Data()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: Self.readChunk), !chunk.isEmpty else { break }
                // We drain diagnostics without retaining them or charging the payload budget.
                guard isPayload else { continue }
                if chunk.count > limit - data.count {
                    lock.withLock { hasExceededLimit = true }
                    terminate()
                    break
                }
                data.append(chunk)
            } catch {
                guard isPayload else { break }
                lock.withLock { hasReadFailed = true }
                terminate()
                break
            }
        }
        return data
    }

    static func execute(
        _ arguments: [String],
        root: URL,
        limit: Int,
        environment: [String: String] = [:]
    ) async throws -> Data {
        let command = ReviewGitCommand()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try command.run(arguments: arguments, root: root, limit: limit, environment: environment)
                    })
                }
            }
        } onCancel: {
            command.cancel()
        }
    }
}

enum ReviewGit {
    static let maxDiffBytes = 2 * 1024 * 1024
    static let maxFiles = 1000
    private static let diffOptions = [
        "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=none", "--submodule=short",
        "--src-prefix=a/", "--dst-prefix=b/",
        "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= "
    ]

    static func root(at directory: URL) async throws -> URL {
        let data = try await command(["rev-parse", "--show-toplevel"], root: directory)
        guard var path = String(data: data, encoding: .utf8), path.hasSuffix("\n") else { throw ReviewError.gitFailed }
        path.removeLast()
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The `git diff` arguments that select one layer of a scope.
    ///
    /// Paired with `ReviewScope.layers`, which says which layers a scope has:
    /// that list is shared with the store, and this is the part only Git needs.
    /// `nil` for `untracked`, which is in no tree and is listed rather than
    /// diffed.
    ///
    /// Two-dot against the merge base for a branch, not `base...HEAD`: the
    /// three-dot form stops at `HEAD` and would leave out the work the agent
    /// has not committed yet, which is most of what there is to review right
    /// after it says it is done.
    private static func selector(for layer: ReviewLayer, in scope: ReviewScope, root: URL) async throws -> [String]? {
        switch layer {
        case .turn:
            guard case let .turn(baseTree, _) = scope else { return nil }
            return ["--cached", baseTree]
        case .staged: return ["--cached"]
        case .unstaged: return []
        case .branch:
            if let base = scope.base {
                return try await [mergeBase(base, root: root)]
            } else {
                return nil
            }
        case .untracked: return nil
        }
    }

    static func files(at root: URL, scope: ReviewScope = .uncommitted) async throws -> [ReviewFile] {
        let environment = try await turnEnvironment(for: scope, root: root, refresh: true)
        return try await files(at: root, scope: scope, environment: environment)
    }

    /// Compares a fresh private turn index to the snapshot currently displayed
    /// without publishing it. A poll must observe newer work, not make that
    /// newer work the source that later file loads use.
    static func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo displayedFiles: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        if scope.isTurn {
            let locations = try await turnIndexLocations(for: scope, root: root)
            let stagingIndex = try await captureTurnIndex(at: locations, root: root)
            defer { try? FileManager.default.removeItem(at: stagingIndex) }
            let environment = ["GIT_INDEX_FILE": stagingIndex.path]
            let latestFiles = try await files(at: root, scope: scope, environment: environment)
            guard latestFiles == displayedFiles else { return true }
            guard let currentDiff else { return false }
            // Conflict rows deliberately have no patch fingerprint. Their
            // presence and status were compared in the list above, so asking
            // for a patch would turn that empty sentinel into a false change.
            guard currentDiff.file.status != .unmerged else { return false }
            let latest = try await patchFingerprint(
                currentDiff.file,
                root: root,
                scope: scope,
                environment: environment
            )
            return latest.fingerprint != currentDiff.fingerprint
        }

        let latestFiles = try await files(at: root, scope: scope)
        guard latestFiles == displayedFiles else { return true }
        guard let currentDiff else { return false }
        return try await fingerprint(currentDiff.file, root: root, scope: scope) != currentDiff.fingerprint
    }

    private static func files(
        at root: URL,
        scope: ReviewScope,
        environment: [String: String]
    ) async throws -> [ReviewFile] {
        var result: [ReviewFile] = []
        for layer in scope.layers {
            guard let selector = try await selector(for: layer, in: scope, root: root) else { continue }
            let args = ["diff"] + selector + diffOptions + ["--name-status", "-z", "-M"]
            result += try await parseNames(command(args, root: root, environment: environment), layer: layer)
        }
        // Ordinary scopes need a separate untracked listing. A turn's private
        // index already contains those additions in its single layer.
        if scope.layers.contains(.untracked) {
            let untracked = try await splitPaths(command(["ls-files", "--others", "--exclude-standard", "-z"], root: root))
            result += untracked.map { ReviewFile(path: $0, layer: .untracked, status: .untracked) }
        }
        // `git add -A` in a private turn index turns the real index's
        // stage-1/2/3 conflict entries into one stage-0 file containing
        // conflict markers. Preserve the real index's conflict state so turn
        // review takes the same safe path as the ordinary review scopes.
        if scope.isTurn {
            let unmergedPaths = try await realIndexUnmergedPaths(at: root)
            if !unmergedPaths.isEmpty {
                result.removeAll { unmergedPaths.contains($0.path) }
                result += unmergedPaths.map {
                    ReviewFile(path: $0, layer: .turn, status: .unmerged)
                }
            }
        }
        guard result.count <= maxFiles else { throw ReviewError.tooLarge }
        // Unmerged paths may occur as both U and M, and in both layers. Keyed
        // by id alone, the same conflicted path was listed twice — once staged,
        // once unstaged — both saying to resolve it first. One entry per path.
        var unique: [String: ReviewFile] = [:]
        var conflicted: Set<String> = []
        for file in result where file.status == .unmerged {
            conflicted.insert(file.path)
        }
        for file in result {
            if conflicted.contains(file.path) {
                if file.status == .unmerged, unique[file.path] == nil {
                    unique[file.path] = file
                }
                continue
            }
            unique[file.id] = file
        }
        return unique.values.sorted { $0.id < $1.id }
    }

    /// One `--numstat` call per tracked layer. Untracked files have no Git
    /// record to count against, so they carry no stat at all; showing a
    /// guessed number there would be worse than none.
    static func stats(at root: URL, scope: ReviewScope = .uncommitted) async throws -> [String: ReviewFileStat] {
        var result: [String: ReviewFileStat] = [:]
        let environment = try await turnEnvironment(for: scope, root: root)
        for layer in scope.layers {
            guard let selector = try await selector(for: layer, in: scope, root: root) else { continue }
            let data = try await command(
                ["diff"] + selector + ["--numstat", "-z", "-M"],
                root: root,
                environment: environment
            )
            for (path, stat) in try parseNumstat(data) {
                result[layer.rawValue + ":" + path] = stat
            }
        }
        return result
    }

    /// The commit this branch left `base` at.
    ///
    /// Resolved per call rather than held: a fetch or a rebase moves it, and
    /// diffing against a point the branch is no longer on would show the base
    /// branch's own commits as changes to review.
    static func mergeBase(_ base: String, root: URL) async throws -> String {
        let data = try await command(["merge-base", "--", base, "HEAD"], root: root)
        guard var text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { throw ReviewError.gitFailed }
        text.removeLast()
        return text
    }

    /// The branch to compare against when nothing else names one.
    ///
    /// `origin/HEAD` is what the remote calls its own default and is right
    /// even where the branch is named something else; the local names are the
    /// fallback for a repository that has no remote. `nil` when neither
    /// resolves, which is what keeps the mode from being offered at all.
    static func defaultBase(at root: URL) async throws -> String? {
        if let data = try? await command(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], root: root),
           var text = String(data: data, encoding: .utf8), text.hasSuffix("\n")
        {
            text.removeLast()
            return text.isEmpty ? nil : text
        }
        for name in ["main", "master"] {
            let probe = try? await command(["rev-parse", "--verify", "--quiet", name + "^{commit}"], root: root)
            if probe != nil {
                return name
            }
        }
        return nil
    }

    /// `--numstat -z` writes `added\tremoved\tpath\0`, except for renames,
    /// where the path field is empty and the old and new paths follow as their
    /// own NUL-delimited fields.
    static func parseNumstat(_ data: Data) throws -> [(String, ReviewFileStat)] {
        let fields = try splitPaths(data)
        var result: [(String, ReviewFileStat)] = []
        var index = 0
        while index < fields.count {
            // The first two tabs only. `-z` turns off `core.quotePath`, so a
            // path with a tab in it arrives raw; splitting on every tab made
            // it a fourth field and took the whole repository's counts down
            // with it, silently, because the caller swallows the error.
            let parts = fields[index]
                .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 3 else { throw ReviewError.invalidDiff }
            // A binary file reports `-` for both counts; -1 marks that apart
            // from a real zero so the row can say so instead of showing +0 −0.
            let added = parts[0] == "-" ? -1 : Int(parts[0])
            let removed = parts[1] == "-" ? -1 : Int(parts[1])
            guard let added, let removed else { throw ReviewError.invalidDiff }
            index += 1
            let path: String
            if parts[2].isEmpty {
                guard index + 1 < fields.count else { throw ReviewError.invalidDiff }
                path = fields[index + 1]
                index += 2
            } else {
                path = parts[2]
            }
            result.append((path, ReviewFileStat(added: added, removed: removed)))
        }
        return result
    }

    static func parseNames(_ data: Data, layer: ReviewLayer) throws -> [ReviewFile] {
        let fields = try splitPaths(data)
        var result: [ReviewFile] = []
        var index = 0
        while index < fields.count {
            let status = ReviewFileStatus(gitField: fields[index])
            index += 1
            guard index < fields.count else { throw ReviewError.invalidDiff }
            let first = fields[index]
            index += 1
            if status == .renamed || status == .copied {
                guard index < fields.count else { throw ReviewError.invalidDiff }
                result.append(ReviewFile(path: fields[index], oldPath: first, layer: layer, status: status))
                index += 1
            } else {
                result.append(ReviewFile(path: first, layer: layer, status: status))
            }
        }
        return result
    }

    private static func splitPaths(_ data: Data) throws -> [String] {
        guard data.isEmpty || data.last == 0 else { throw ReviewError.invalidDiff }
        return try data.split(separator: 0).map {
            guard let path = String(data: $0, encoding: .utf8) else { throw ReviewError.unsupported }
            return path
        }
    }

    /// Whether the file's diff still hashes to what it did, without building
    /// the rows.
    ///
    /// The change poll asks this every few seconds. Answering it through
    /// `diff` parsed the whole patch, ran every line through `ReviewText`, and
    /// threw all of it away — on a file that can be a hundred thousand lines
    /// long. Byte-identical to the fingerprint `diff` returns, because both
    /// hash the same selected patch: the two disagreeing would leave the banner
    /// either permanently lit or permanently silent.
    static func fingerprint(
        _ file: ReviewFile,
        root: URL,
        scope: ReviewScope = .uncommitted
    ) async throws -> String {
        try Task.checkCancellation()
        guard file.status != .unmerged else { return "" }
        return try await patchFingerprint(file, root: root, scope: scope).fingerprint
    }

    /// Compatibility for focused branch scenarios that name the comparison
    /// branch directly. Production callers carry the complete scope instead.
    static func fingerprint(_ file: ReviewFile, root: URL, base: String?) async throws -> String {
        try await fingerprint(file, root: root, scope: base.map(ReviewScope.branch) ?? .uncommitted)
    }

    /// One file's diff, read the way its own layer says to read it.
    ///
    /// The layer decides, not a mode passed in: a comment written on the
    /// branch stays validatable after the reader switches back to the
    /// worktree, which is what keeps switching views from quietly aging out
    /// everything written in the other one. `base` is required for a
    /// `.branch` file and ignored for the rest.
    static func diff(
        _ file: ReviewFile,
        root: URL,
        scope: ReviewScope = .uncommitted
    ) async throws -> ReviewDiff {
        try Task.checkCancellation()
        if file.status == .unmerged {
            return ReviewDiff(
                file: file,
                fingerprint: "",
                lines: [],
                notice: String(localized: "Resolve merge conflicts before reviewing this file.")
            )
        }
        return try await patchFingerprint(file, root: root, scope: scope).diff()
    }

    /// Compatibility for focused branch scenarios that name the comparison
    /// branch directly. Production callers carry the complete scope instead.
    static func diff(_ file: ReviewFile, root: URL, base: String?) async throws -> ReviewDiff {
        try await diff(file, root: root, scope: base.map(ReviewScope.branch) ?? .uncommitted)
    }

    /// The bytes a file's diff hashes to, and how to turn them into rows.
    ///
    /// One place so the poll and the reader cannot disagree about what has
    /// changed: the poll takes the fingerprint and stops, the surface calls
    /// `diff()` and parses.
    private struct PatchSnapshot {
        let fingerprint: String
        let build: () throws -> ReviewDiff

        func diff() throws -> ReviewDiff {
            try build()
        }
    }

    private static func patchFingerprint(
        _ file: ReviewFile,
        root: URL,
        scope: ReviewScope,
        environment suppliedEnvironment: [String: String]? = nil
    ) async throws -> PatchSnapshot {
        let head = file.layer == .turn
            ? nil
            : try await command(["rev-parse", "--revs-only", "HEAD"], root: root)
        if file.layer == .untracked {
            let snapshot = try await Task.detached(priority: .userInitiated) { try untrackedDiff(file, root: root) }.value
            guard try await head == command(["rev-parse", "--revs-only", "HEAD"], root: root) else {
                throw ReviewError.checkInterrupted
            }
            // Without `HEAD`: an untracked file's content does not depend on
            // it, and folding it in meant an unrelated commit aged out every
            // comment in the review. `HEAD` is still read either side of the
            // diff, which is what catches a commit landing underneath this one.
            let fingerprint = ReviewDiff.hash(Data(snapshot.fingerprint.utf8))
            return PatchSnapshot(fingerprint: fingerprint) {
                ReviewDiff(
                    file: file,
                    fingerprint: fingerprint,
                    lines: snapshot.lines,
                    notice: snapshot.notice
                )
            }
        }
        let paths = file.oldPath.map { [$0, file.path] } ?? [file.path]
        guard let selector = try await selector(for: file.layer, in: scope, root: root) else {
            throw ReviewError.gitFailed
        }
        let environment = try await readEnvironment(
            for: scope,
            root: root,
            supplied: suppliedEnvironment
        )
        let args = ["diff"] + selector + diffOptions + ["-M", "--unified=3", "--"] + paths
        let data = try await command(args, root: root, environment: environment)
        guard !data.contains(0), let patch = String(data: data, encoding: .utf8) else { throw ReviewError.unsupported }
        if let head {
            guard try await head == command(["rev-parse", "--revs-only", "HEAD"], root: root) else {
                throw ReviewError.checkInterrupted
            }
        }
        let selectedPatch = try filePatch(patch, file: file)
        let selectedData = Data(selectedPatch.utf8)
        // The patch bytes alone, on every layer. A staged patch is `HEAD`
        // against the index and its `index <old>..<new>` header names both
        // blobs, so anything that changes what the reader is looking at changes
        // these bytes — while committing an unrelated path leaves them exactly
        // as they were. Folding `HEAD` in instead aged out every staged comment
        // on any commit at all, which is the same fault the unstaged and
        // untracked paths were written to avoid. A commit landing mid-read is
        // caught by the `rev-parse` either side of the diff, not by the
        // fingerprint.
        let fingerprint = ReviewDiff.hash(selectedData)
        return PatchSnapshot(fingerprint: fingerprint) {
            let lines = try ReviewDiffParser.parse(selectedPatch)
            let hasSpecialMode = lines.contains {
                $0.kind == .fileHeader && ($0.text.hasSuffix(" 160000") || $0.text.hasSuffix(" 120000"))
            }
            if hasSpecialMode {
                return ReviewDiff(
                    file: file,
                    fingerprint: fingerprint,
                    lines: [],
                    notice: String(localized: "This file cannot be reviewed as text.")
                )
            }
            // Git answering with nothing, and Git answering with a patch that
            // has nothing to comment on, are different things — and saying the
            // second when it is the first blames the file for the list being
            // old. A file whose change was committed, stashed or reverted
            // since the list was read still sits in the rail carrying the
            // counts from that read; opening it asks Git again and gets an
            // empty patch back. "No reviewable text changes" reads as a
            // property of the file — binary, a mode change — which is the
            // wrong sentence for a change that is simply gone.
            //
            // Asked of the patch rather than of the parsed rows: an empty
            // patch does not parse to an empty list, so the row count cannot
            // tell these apart.
            let hasVanished = selectedPatch.isEmpty
            let notice: String? = if hasVanished {
                String(localized: "This file is no longer changed. Refresh the list.")
            } else if lines.contains(where: \.isCommentable) {
                nil
            } else {
                String(localized: "No reviewable text changes in this file.")
            }
            return ReviewDiff(
                file: file,
                fingerprint: fingerprint,
                lines: lines,
                notice: notice,
                hasVanished: hasVanished
            )
        }
    }

    /// A rename pathspec can also include a newly created file at the old path.
    /// We select the exact file header so those rows cannot acquire the rename's comments.
    static func filePatch(_ patch: String, file: ReviewFile) throws -> String {
        if patch.isEmpty {
            return ""
        }
        let expected = "diff --git " + quotePath("a/" + (file.oldPath ?? file.path)) + " " + quotePath("b/" + file.path)
        var selected: [String] = []
        var isSelected = false
        var found = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                isSelected = line == expected
                if isSelected {
                    found = true
                }
            }
            if isSelected {
                selected.append(line)
            }
        }
        guard found else { throw ReviewError.invalidDiff }
        return selected.joined(separator: "\n")
    }

    private static func quotePath(_ path: String) -> String {
        var escaped = ""
        var needsQuotes = false
        for byte in path.utf8 {
            let replacement: String? = switch byte {
            case 7: "\\a"
            case 8: "\\b"
            case 9: "\\t"
            case 10: "\\n"
            case 11: "\\v"
            case 12: "\\f"
            case 13: "\\r"
            case 34: "\\\""
            case 92: "\\\\"
            case 0..<32, 127...255: String(format: "\\%03o", Int(byte))
            default: nil
            }
            if let replacement {
                escaped += replacement
                needsQuotes = true
            } else {
                escaped.append(Character(UnicodeScalar(byte)))
            }
        }
        return needsQuotes ? "\"" + escaped + "\"" : path
    }

    /// The new side of a file, whole, for unfolding the context a unified diff
    /// leaves out.
    ///
    /// The new side is the working copy except for index-backed layers. Both
    /// staged and turn diffs read an index, so their unfolded context must use
    /// that same index rather than a worktree that may have moved since the
    /// snapshot was selected.
    static func source(
        _ file: ReviewFile,
        root: URL,
        scope: ReviewScope = .uncommitted
    ) async -> [String] {
        let data: Data?
        if file.layer == .staged || file.layer == .turn {
            // `:./path` rather than `:path`: Git reads a leading digit and
            // colon as a stage number, so a repository file named `0:notes.txt`
            // asked the index for stage 0 of `notes.txt`. The command runs with
            // the worktree root as its directory, so `./` names the same file.
            guard let environment = await sourceEnvironment(for: file, scope: scope, root: root) else {
                return []
            }
            data = try? await command(["show", ":./" + file.path], root: root, environment: environment)
        } else {
            // Read rather than mapped: an agent working in the same worktree
            // rewrites these files while this surface is open, and a mapping
            // whose file is truncated under it raises SIGBUS instead of an
            // error this can answer by making no offer of context. Bounded and
            // contained the same way `untrackedDiff` bounds and contains its
            // read: without it, a path whose parent is a symlink showed a file
            // from outside the worktree under the reviewed file's own line
            // numbers, and a small diff on a large file read the whole thing.
            data = try? worktreeFile(at: root.appendingPathComponent(file.path), root: root)
        }
        guard let data, data.count <= maxDiffBytes, !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        var parts = ReviewDiffParser.lines(of: text)
        if parts.last == "" {
            parts.removeLast()
        }
        // The same ceiling the parsed path keeps, answered the way the rest of
        // this function answers: unfolding a file that is mostly newlines asks
        // the table for a row per line, and the byte limit lets a great many of
        // them through. Offering no extra context is the safe half of that.
        guard parts.count <= ReviewDiffParser.maxRows else { return [] }
        return parts
    }

    /// A file read from the worktree, bounded and contained.
    ///
    /// The containment is the point: a path Git reports is relative to the
    /// worktree, but a directory along it can be a symlink, and following one
    /// reads a file the reader never asked about under the reviewed file's
    /// name. The size check is taken before the read and again after it,
    /// because the file can grow between the two — an agent is working in this
    /// worktree while the surface is open.
    private static func worktreeFile(at url: URL, root: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        else { throw ReviewError.unsupported }
        guard (values.fileSize ?? Int.max) <= maxDiffBytes else { throw ReviewError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxDiffBytes + 1) ?? Data()
        guard data.count <= maxDiffBytes else { throw ReviewError.tooLarge }
        return data
    }

    private static func untrackedDiff(_ file: ReviewFile, root: URL) throws -> ReviewDiff {
        let url = root.appendingPathComponent(file.path)
        let data = try worktreeFile(at: url, root: root)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ReviewError.unsupported }
        var parts = ReviewDiffParser.lines(of: text)
        if parts.last == "" {
            parts.removeLast()
        }
        // The same ceiling the parsed path keeps. A file that is mostly
        // newlines passes the byte limit and still asks the table for a row per
        // line.
        guard parts.count <= ReviewDiffParser.maxRows else { throw ReviewError.tooLarge }
        let lines = parts.enumerated()
            .map { ReviewLine(id: $0.offset, kind: .added, text: $0.element, oldLine: nil, newLine: $0.offset + 1) }
        return ReviewDiff(
            file: file,
            fingerprint: ReviewDiff.hash(data),
            lines: lines,
            notice: lines.isEmpty ? String(localized: "No reviewable text changes in this file.") : nil
        )
    }

    /// The displayed private index is refreshed only by an explicit `files`
    /// read. Polling builds an unpublished index so it can detect changes
    /// without changing the snapshot used by later file loads.
    private static func turnEnvironment(
        for scope: ReviewScope,
        root: URL,
        refresh: Bool = false
    ) async throws -> [String: String] {
        guard scope.isTurn else { return [:] }
        let locations = try await turnIndexLocations(for: scope, root: root)
        if refresh {
            let publication = ReviewTurnIndexPublisher.shared.begin(for: locations.readIndex.path)
            let stagingIndex = try await captureTurnIndex(at: locations, root: root)
            defer { try? FileManager.default.removeItem(at: stagingIndex) }
            // Git readers keep the inode they opened, so they see either the
            // complete old snapshot or the complete new one. Publishing only
            // after `add -A` finishes prevents readers from sharing a
            // partially rewritten index.
            try ReviewTurnIndexPublisher.shared.publish(
                stagingPath: stagingIndex.path,
                to: locations.readIndex.path,
                token: publication
            )
        }
        return ["GIT_INDEX_FILE": locations.readIndex.path]
    }

    private struct TurnIndexLocations {
        let limpidURL: URL
        let realIndex: URL
        let readIndex: URL
    }

    private static func turnIndexLocations(for scope: ReviewScope, root: URL) async throws -> TurnIndexLocations {
        guard case let .turn(baseTree, paneID) = scope else { throw ReviewError.gitFailed }
        do {
            _ = try await command(["cat-file", "-e", baseTree + "^{tree}"], root: root)
        } catch {
            throw ReviewError.turnBaseMissing
        }
        let data = try await command(["rev-parse", "--git-dir"], root: root)
        guard var gitDirectory = String(data: data, encoding: .utf8), gitDirectory.hasSuffix("\n") else {
            throw ReviewError.gitFailed
        }
        gitDirectory.removeLast()
        let gitURL = URL(fileURLWithPath: gitDirectory, relativeTo: root).standardizedFileURL
        let limpidURL = gitURL.appendingPathComponent("limpid", isDirectory: true)
        let paneKey = paneID.uuidString.lowercased()
        let readIndex = limpidURL.appendingPathComponent("turn-\(paneKey).read.index")
        return TurnIndexLocations(
            limpidURL: limpidURL,
            realIndex: gitURL.appendingPathComponent("index"),
            readIndex: readIndex
        )
    }

    private static func captureTurnIndex(at locations: TurnIndexLocations, root: URL) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: locations.limpidURL, withIntermediateDirectories: true)
        let stagingIndex = locations.limpidURL.appendingPathComponent(
            "turn-read-\(UUID().uuidString.lowercased()).index"
        )
        try? fileManager.copyItem(at: locations.realIndex, to: stagingIndex)
        do {
            _ = try await command(
                ["add", "-A"],
                root: root,
                environment: ["GIT_INDEX_FILE": stagingIndex.path]
            )
            return stagingIndex
        } catch {
            try? fileManager.removeItem(at: stagingIndex)
            try? fileManager.removeItem(atPath: stagingIndex.path + ".lock")
            throw error
        }
    }

    private static func realIndexUnmergedPaths(at root: URL) async throws -> Set<String> {
        let data = try await command(["diff", "--name-only", "--diff-filter=U", "-z"], root: root)
        let paths = try splitPaths(data)
        return Set(paths)
    }

    private static func readEnvironment(
        for scope: ReviewScope,
        root: URL,
        supplied: [String: String]?
    ) async throws -> [String: String] {
        if let supplied {
            return supplied
        }
        return try await turnEnvironment(for: scope, root: root)
    }

    private static func sourceEnvironment(
        for file: ReviewFile,
        scope: ReviewScope,
        root: URL
    ) async -> [String: String]? {
        guard file.layer == .turn else { return [:] }
        // Falling back to the real index would splice unrelated content into
        // a turn diff. No optional context is safer than the wrong snapshot.
        return try? await turnEnvironment(for: scope, root: root)
    }

    private static func command(
        _ args: [String],
        root: URL,
        environment: [String: String] = [:]
    ) async throws -> Data {
        try await ReviewGitCommand.execute(args, root: root, limit: maxDiffBytes, environment: environment)
    }
}
