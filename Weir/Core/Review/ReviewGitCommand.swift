// ReviewGitCommand.swift
// Weir — cancellable, bounded byte output for machine-readable Git queries.

import Foundation

/// One Git query of the review, on the shared runner (`drainAndWait`) with
/// the review's own timeout, graces, and cap on what Git writes.
private enum ReviewGitCommand {
    /// How long one Git call may take before it is terminated. Long enough for
    /// a cold index on a large repository, short enough that a wedged filter
    /// process does not hold the surface.
    static let timeout: Duration = .seconds(10)
    /// The review's graces: SIGKILL soon after SIGTERM, and two seconds to
    /// finish reading once Git has exited. A grandchild that inherited the
    /// write end of the pipe would otherwise keep this call, and the
    /// continuation waiting on it, alive for the life of the app; past the
    /// grace, the answer is our own timeout. Exits are looked at often, as
    /// the review runs many queries one after another.
    static let timing = ProcessDrainTiming(
        terminationGrace: .milliseconds(200),
        drainGrace: .seconds(2),
        pollMilliseconds: 10
    )

    /// Runs `git` with `arguments` in `root`, its stdout capped at `limit`.
    /// Blocks: call it from a background queue.
    static func run(
        arguments: [String],
        root: URL,
        limit: Int,
        input: Data?,
        stop: ProcessStopRequest
    ) throws -> Data {
        let process = Process()
        let stdout = Pipe.forChildProcess()
        // Paths handed over on standard input rather than as arguments, which
        // run out (E2BIG) for a range of thousands of files. A Git that exits
        // before it has read them all must not take the app down with
        // SIGPIPE: the write then fails, and the exit status answers.
        let stdin = input.map { _ in Pipe.forChildProcess() }
        if let stdin {
            let writer = stdin.fileHandleForWriting.fileDescriptor
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        }
        guard !stop.isRequested else { throw CancellationError() }
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
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        // Git's diagnostics are not read: no answer here quotes them, and the
        // null device never fills the way an unread pipe would.
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let stdin, let input {
            DispatchQueue.global(qos: .userInitiated).async {
                // A Git that stopped reading early fails this write; its exit
                // status is the answer.
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let output = drainAndWait(
            process,
            stdout: stdout,
            stderr: nil,
            timeout: timeout,
            stop: stop,
            stdoutLimitBytes: limit,
            timing: timing
        )
        try? stdout.fileHandleForReading.close()
        return try answer(output, status: process.terminationStatus, isStopped: stop.isRequested)
    }

    /// What the run answers, ordered by what the caller can act on: the size
    /// limit first, as it ends the process too; then our own timeout and a
    /// failed read, which are ours to name; and only what the caller asked
    /// for becomes a cancellation. Our timeout is never reported as the
    /// reader's cancellation: that put `CancellationError`, a Swift type with
    /// no message of ours, in front of them, and nothing cleared it. A failed
    /// read fails even when Git exits zero, as a truncated payload would be
    /// worse than none.
    private static func answer(_ output: DrainedOutput, status: Int32, isStopped: Bool) throws -> Data {
        switch output.ending {
        case .outputLimit: throw ReviewError.tooLarge
        case .timedOut: throw ReviewError.timedOut
        case .stopped, .exited: break
        }
        if output.hasStdoutReadFailed {
            throw ReviewError.gitFailed
        }
        if !output.isStdoutComplete {
            throw ReviewError.timedOut
        }
        // Asked to stop even if Git finished first: the caller has moved on.
        guard output.ending != .stopped, !isStopped else { throw CancellationError() }
        guard status == 0 else { throw ReviewError.gitFailed }
        return output.stdout
    }

    static func execute(
        _ arguments: [String],
        root: URL,
        limit: Int,
        input: Data? = nil
    ) async throws -> Data {
        let stop = ProcessStopRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try run(arguments: arguments, root: root, limit: limit, input: input, stop: stop)
                    })
                }
            }
        } onCancel: {
            stop.request()
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

    /// The paths that differ between two trees, renames read as a delete
    /// and an add: what changed after a review range.
    static func pathsChanged(from: String, to: String, root: URL) async throws -> Set<String> {
        let data = try await command(["diff", "--name-only", "--no-renames", "-z", from, to], root: root)
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }

    /// What changed between two recorded trees, counted as the receipt
    /// counts a turn: the files, and the lines added and removed, with a
    /// binary file's lines as none. The changes panel's totals are this one
    /// comparison over the worktree's turns, never the turns' counts added
    /// up, which would count a change two turns ran over twice.
    static func counts(from: String, to: String, root: URL) async throws -> ChangeSummary {
        let data = try await command(["diff", "--numstat", "-z", "-M", from, to], root: root)
        let stats = try parseNumstat(data)
        guard !stats.isEmpty else { return .unchanged }
        return .changed(
            files: stats.count,
            added: stats.reduce(0) { $0 + max(0, $1.1.added) },
            removed: stats.reduce(0) { $0 + max(0, $1.1.removed) }
        )
    }

    static func root(at directory: URL) async throws -> URL {
        let data = try await command(["rev-parse", "--show-toplevel"], root: directory)
        guard var path = String(data: data, encoding: .utf8), path.hasSuffix("\n") else { throw ReviewError.gitFailed }
        path.removeLast()
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The `git diff` arguments that select one layer of a scope.
    ///
    /// Paired with `ReviewScope.layers`, which says which layers a scope has:
    /// that list is shared with the review, and this is the part only Git needs.
    /// `nil` for `untracked`, which is in no tree and is listed rather than
    /// diffed.
    ///
    /// Two-dot against the merge base for a branch, not `base...HEAD`: the
    /// three-dot form stops at `HEAD` and would leave out the work the agent
    /// has not committed yet, which is most of what there is to review right
    /// after it says it is done.
    private static func selector(for layer: ReviewLayer, in scope: ReviewScope, root: URL) async throws -> [String]? {
        switch layer {
        // The legacy layer no scope lists (`ReviewLayer.turn`).
        case .turn: return nil
        case .turns:
            // Two recorded trees, so neither the index nor the worktree takes
            // part: the range shows the same diff however the files move on.
            guard case let .turns(range) = scope else { return nil }
            return [range.beginTree, range.endTree]
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

    /// Whether the scope's list, or the open file's patch, differs from what
    /// is on screen.
    static func hasChanges(
        at root: URL,
        scope: ReviewScope,
        comparedTo displayedFiles: [ReviewFile],
        currentDiff: ReviewDiff?
    ) async throws -> Bool {
        // A fixed range compares two recorded trees; nothing it shows moves.
        if case .turns = scope {
            return false
        }
        let latestFiles = try await files(at: root, scope: scope)
        guard latestFiles == displayedFiles else { return true }
        guard let currentDiff else { return false }
        return try await fingerprint(currentDiff.file, root: root, scope: scope) != currentDiff.fingerprint
    }

    static func files(at root: URL, scope: ReviewScope = .uncommitted) async throws -> [ReviewFile] {
        if case let .turns(range) = scope {
            try await requireTrees(of: range, root: root)
        }
        var result: [ReviewFile] = []
        for layer in scope.layers {
            guard let selector = try await selector(for: layer, in: scope, root: root) else { continue }
            let args = ["diff"] + selector + diffOptions + ["--name-status", "-z", "-M"]
            result += try await parseNames(command(args, root: root), layer: layer)
        }
        // Untracked files are in no tree and no index, so they are listed
        // rather than diffed.
        if scope.layers.contains(.untracked) {
            let untracked = try await splitPaths(command(["ls-files", "--others", "--exclude-standard", "-z"], root: root))
            result += untracked.map { ReviewFile(path: $0, layer: .untracked, status: .untracked) }
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
        for layer in scope.layers {
            guard let selector = try await selector(for: layer, in: scope, root: root) else { continue }
            let data = try await command(["diff"] + selector + ["--numstat", "-z", "-M"], root: root)
            for (path, stat) in try parseNumstat(data) {
                result[layer.rawValue + ":" + path] = stat
            }
        }
        return result
    }

    /// Both of a range's trees, or `rangeSnapshotsMissing`: a record that
    /// lost one end is incomplete, and saying so beats a Git failure the
    /// reader would retry forever. Also refuses a range of another work tree,
    /// whose objects this repository may share without it being this one's.
    private static func requireTrees(of range: ReviewTurnRange, root: URL) async throws {
        guard URL(fileURLWithPath: range.root).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
            throw ReviewError.rangeInAnotherWorktree
        }
        for tree in [range.beginTree, range.endTree] {
            do {
                _ = try await command(["cat-file", "-e", tree + "^{tree}"], root: root)
            } catch ReviewError.gitFailed {
                // `cat-file -e` fails when the object is not there. A Git
                // that could not run at all lands here too; the comments it
                // holds back come back on the next try, so we do not tell
                // the two apart.
                throw ReviewError.rangeSnapshotsMissing
            }
        }
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

    /// Git's NUL-separated paths (`-z`). Internal only for `ReviewGit`'s own
    /// extensions; no other layer reads Git output through it.
    static func splitPaths(_ data: Data) throws -> [String] {
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
                notice: LocalizedStringResource("Resolve merge conflicts before reviewing this file.")
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
        scope: ReviewScope
    ) async throws -> PatchSnapshot {
        // A range reads snapshots, not `HEAD`: a commit landing under it
        // changes nothing it shows.
        let head = file.layer == .turns
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
        let args = ["diff"] + selector + diffOptions + ["-M", "--unified=3", "--"] + paths
        let data = try await command(args, root: root)
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
                    notice: LocalizedStringResource("This file can’t be reviewed as text.")
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
            return ReviewDiff(
                file: file,
                fingerprint: fingerprint,
                lines: lines,
                notice: patchNotice(hasVanished: hasVanished, lines: lines),
                hasVanished: hasVanished
            )
        }
    }

    /// What the pane says in place of a patch's rows, or `nil` when it has
    /// rows to comment on. Early returns rather than an `if` expression: the
    /// string catalog's extraction reads only the first branch of one.
    private static func patchNotice(hasVanished: Bool, lines: [ReviewLine]) -> LocalizedStringResource? {
        if hasVanished {
            return LocalizedStringResource("This file is no longer changed. Refresh the list.")
        }
        if lines.contains(where: \.isCommentable) {
            return nil
        }
        return LocalizedStringResource("No reviewable text changes in this file.")
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
    /// The new side is the working copy except where the diff reads something
    /// else: a staged diff reads the index, and a range the tree it ended at,
    /// so their unfolded context must come from there rather than from a
    /// worktree that may have moved since.
    static func source(
        _ file: ReviewFile,
        root: URL,
        scope: ReviewScope = .uncommitted
    ) async -> [String] {
        let data: Data?
        if file.layer == .turns {
            // The tree the range ended at; `./` for the same reason as below.
            guard case let .turns(range) = scope else { return [] }
            data = try? await command(["show", range.endTree + ":./" + file.path], root: root)
        } else if file.layer == .staged {
            // `:./path` rather than `:path`: Git reads a leading digit and
            // colon as a stage number, so a repository file named `0:notes.txt`
            // asked the index for stage 0 of `notes.txt`. The command runs with
            // the worktree root as its directory, so `./` names the same file.
            data = try? await command(["show", ":./" + file.path], root: root)
        } else if file.layer == .turn {
            // No scope lists the legacy layer, so there is no snapshot to read.
            return []
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
              RepositoryPath.isStrictDescendant(url.resolvingSymlinksInPath().path, of: root.resolvingSymlinksInPath().path)
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
            notice: lines.isEmpty ? LocalizedStringResource("No reviewable text changes in this file.") : nil
        )
    }

    /// One Git command in `root`, its output capped at `limit`.
    /// Internal only for `ReviewGit`'s own extensions; every other layer asks
    /// `ReviewGit` a question rather than running Git.
    static func command(
        _ args: [String],
        root: URL,
        limit: Int = maxDiffBytes,
        input: Data? = nil
    ) async throws -> Data {
        try await ReviewGitCommand.execute(args, root: root, limit: limit, input: input)
    }
}
