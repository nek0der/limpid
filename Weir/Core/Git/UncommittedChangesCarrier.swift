// UncommittedChangesCarrier.swift
// Weir — moves a worktree's uncommitted changes into a new worktree, and leaves them where they were on any failure.
//
// Why not `git stash`. A stash takes the changes out of the source first and
// puts them back if applying them fails. Between those two steps the
// changes are only in the stash, and putting them back is one more step
// that can fail: an agent writing a file in the source meanwhile makes the
// restore of an untracked file refuse, and the person's work is left in an
// entry of a stack every worktree shares, where another session may pop it.
//
// So we copy first and take away last, and the source is written once, at
// the very end, only if nothing in it changed:
//
// 1. Read. The index and the whole working tree, untracked files included,
//    are written as two trees through a copy of the index
//    (`GIT_INDEX_FILE`). The source's own index and files are not written.
// 2. Place. The two trees are merged onto the new worktree's start with
//    `git merge-tree --merge-base`, which writes no file either. A conflict
//    stops here, before the worktree is made.
// 3. Apply. The new worktree, fresh at its start, is moved to the merged
//    trees with `git read-tree -m -u`, which checks every path before it
//    writes any, then checked against them, and every file the changes
//    touch compared byte for byte with the source's (a line-ending setting
//    or a filter can make files Git calls equal differ on disk). A new
//    worktree whose checkout's hook changed a tracked file is not written
//    at all, and a failure puts back only the paths the changes wrote.
// 4. Take away. With the source's index locked as Git locks it, and HEAD
//    read again under the lock, the working tree is moved from the
//    snapshot back to HEAD with `git read-tree -m -u`: it refuses, writing
//    nothing, if any file differs from what was read in step 1, or an
//    untracked file stands where HEAD has one. Only then is the new index
//    put in place.
//
// What only the index can hold (skip-worktree, assume-unchanged,
// intent-to-add) and files Git ignores inside a folder that replaced a
// tracked file would be lost by step 4, so step 1 refuses those worktrees.
//
// Step 4 failing part way, on a disk that stops taking writes, is the one
// case left: the changes are in the new worktree, checked, and a copy is
// stored as a stash entry as well.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.carry")

enum UncommittedChangesCarrier {
    /// The worktree's uncommitted changes as read in step 1.
    struct Snapshot: Equatable, Sendable {
        let source: URL
        let head: String
        /// The branch HEAD names (`refs/heads/main`); `nil` when detached.
        let branch: String?
        /// The index, as a tree.
        let indexTree: String
        /// The whole working tree, untracked files included, ignored ones
        /// not, as a tree.
        let fullTree: String
        /// The untracked files among them.
        let untracked: [String]
        /// Every path the working tree changes from HEAD.
        let changedPaths: [String]
        /// The paths among them it deletes, which going back to HEAD writes.
        let deletedPaths: [String]
        /// How many files changed, as the sidebar counts them.
        let fileCount: Int
    }

    /// The snapshot merged onto the new worktree's start (step 2): what its
    /// index and its working tree become.
    struct Placement: Equatable, Sendable {
        let start: String
        let indexTree: String
        let fullTree: String
        /// The paths the start changes from the snapshot's HEAD, where the
        /// new worktree's files are the merge's rather than the source's.
        let startChanges: Set<String>
    }

    /// How a carry ended once the worktree was made.
    enum Outcome: Equatable, Sendable {
        /// In the new worktree, and taken out of the source.
        case moved(files: Int)
        /// The new worktree could not take them; the paths we carried are
        /// put back to its start (changes of its own, such as a hook's, are
        /// left as they are), and the source was not touched.
        case notApplied
        /// In the new worktree, and still in the source, which changed, or
        /// whose index Git held, while they were moved.
        case leftInSource
        /// In the new worktree; the source could not be cleared all the
        /// way. `stash` is the copy kept, `nil` when none could be stored.
        case partlyCleared(stash: String?)
    }

    // MARK: - Counting

    /// How many files the worktree at `root` has uncommitted, as the
    /// sidebar counts them; `nil` when Git did not answer. Asks for no
    /// lock, so it never stands in the way of the person's own Git.
    static func changedFileCount(in root: URL) async -> Int? {
        guard let result = try? await GitProcess.run(
            ["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            cwd: root
        ), result.succeeded else { return nil }
        return UncommittedCarryRules.changedFileCount(porcelain: result.stdout)
    }

    // MARK: - 1. Read

    /// The worktree at `root`'s uncommitted changes, or `nil` when it has
    /// none. Writes nothing in the worktree: the trees are made through a
    /// copy of its index.
    static func snapshot(of root: URL) async throws -> Snapshot? {
        let resolved = try await gitPaths(["index"] + UncommittedCarryRules.operationMarkers, in: root)
        let head = try? await output(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
        if let refusal = await UncommittedCarryRules.refusal(
            hasCommit: head != nil,
            isOperationInProgress: resolved.dropFirst().contains { FileManager.default.fileExists(atPath: $0.path) },
            usesSparseCheckout: isOn("core.sparseCheckout", in: root),
            usesSplitIndex: isOn("core.splitIndex", in: root)
        ) {
            throw refusal
        }
        guard let head, let index = resolved.first else {
            throw UncommittedCarryRefusal.git("HEAD or the index could not be read")
        }
        let branch = await headBranch(in: root)

        return try await withScratch { scratch in
            let copy = scratch.appendingPathComponent("index")
            try copyIndex(index, to: copy)
            let environment = ["GIT_INDEX_FILE": copy.path]
            let indexTree: String
            do {
                indexTree = try await output(["write-tree"], in: root, environment: environment)
            } catch let UncommittedCarryRefusal.git(said) where said.contains("unmerged") {
                throw UncommittedCarryRefusal.unmergedPaths
            }
            try await refuseIndexOnlyState(in: root, indexTree: indexTree)
            try await output(["add", "-A", "--", ":/"], in: root, environment: environment)
            let fullTree = try await output(["write-tree"], in: root, environment: environment)
            let headTree = try await output(["rev-parse", "\(head)^{tree}"], in: root)
            guard indexTree != headTree || fullTree != headTree else { return nil }
            for tree in [indexTree, fullTree] {
                let raw = try await output(["diff-tree", "-r", "-z", "--no-renames", head, tree], in: root, trims: false)
                if UncommittedCarryRules.touchesGitlinks(rawDiff: raw) {
                    throw UncommittedCarryRefusal.submodules
                }
            }
            let deleted = try await names(
                in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", "--diff-filter=D", head, fullTree],
                root
            )
            try await refuseIgnoredFilesInTheWay(in: root, deleted: deleted)
            let untracked = try await names(
                in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", "--diff-filter=A", indexTree, fullTree],
                root
            )
            let changedPaths = try await names(in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", head, fullTree], root)
            return await Snapshot(
                source: root,
                head: head,
                branch: branch,
                indexTree: indexTree,
                fullTree: fullTree,
                untracked: untracked,
                changedPaths: changedPaths,
                deletedPaths: deleted,
                fileCount: changedFileCount(in: root) ?? 0
            )
        }
    }

    /// The branch HEAD names, `nil` on a detached HEAD: a checkout made
    /// meanwhile changes it even where the commit stays.
    private static func headBranch(in root: URL) async -> String? {
        try? await output(["symbolic-ref", "--quiet", "HEAD"], in: root)
    }

    /// What only the index holds of a file, and no tree can (skip-worktree,
    /// assume-unchanged, intent-to-add): taking the changes away replaces
    /// the index, which would drop it, so such a worktree is refused.
    private static func refuseIndexOnlyState(in root: URL, indexTree: String) async throws {
        let entries = try await output(["ls-files", "-v", "-z"], in: root, trims: false).split(separator: "\0")
        let tree = try await output(["ls-tree", "-r", "-z", "--name-only", "--full-tree", indexTree], in: root, trims: false)
            .split(separator: "\0")
        if UncommittedCarryRules
            .hasIndexOnlyState(tags: entries.compactMap(\.first), indexEntries: entries.count, treeEntries: tree.count)
        {
            throw UncommittedCarryRefusal.indexOnlyState
        }
    }

    /// A tracked file whose path is a folder now, with files Git ignores in
    /// it: going back to the file would remove the folder, those files with
    /// it, and they are carried nowhere.
    private static func refuseIgnoredFilesInTheWay(in root: URL, deleted: [String]) async throws {
        if let path = try await ignoredFileInTheWay(in: root, deleted: deleted) {
            throw UncommittedCarryRefusal.ignoredFilesInTheWay(path)
        }
    }

    /// The first path the changes delete where something Git ignores is on
    /// disk now: a file of that name the person keeps out of Git (`.env`,
    /// untracked and ignored after it was committed), or a folder holding
    /// ignored files. Going back to HEAD writes the tracked file over it,
    /// and nothing carries it. A file Git does not ignore there is no
    /// deletion: it is in the snapshot.
    private static func ignoredFileInTheWay(in root: URL, deleted: [String]) async throws -> String? {
        for path in deleted {
            switch FileBytes(at: root.appendingPathComponent(path)).kind {
            case .missing:
                continue
            case .unreadable:
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isFolder),
                      isFolder.boolValue
                else { return path }
                let ignored = try await output(
                    ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", "\(path)/"],
                    in: root
                )
                if !ignored.isEmpty {
                    return path
                }
            case .link, .file:
                return path
            }
        }
        return nil
    }

    /// The paths `git <arguments>` lists with `-z`.
    private static func names(in arguments: [String], _ root: URL) async throws -> [String] {
        try await output(arguments, in: root, trims: false).split(separator: "\0").map(String.init)
    }

    // MARK: - 2. Place

    /// The snapshot merged onto `start`, read in the repository at
    /// `repoRoot`, which shares its objects with every worktree. Throws
    /// `.conflicts` with the paths when the changes do not apply there.
    static func place(_ snapshot: Snapshot, onto start: String, repoRoot: URL) async throws -> Placement {
        let startCommit = try await output(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(start)^{commit}"], in: repoRoot)
        guard startCommit != snapshot.head else {
            return Placement(start: startCommit, indexTree: snapshot.indexTree, fullTree: snapshot.fullTree, startChanges: [])
        }
        let fullTree = try await merge(snapshot.fullTree, from: snapshot.head, onto: startCommit, in: repoRoot)
        let indexTree = try await merge(snapshot.indexTree, from: snapshot.head, onto: startCommit, in: repoRoot)
        let startChanges = try await names(
            in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", snapshot.head, startCommit],
            repoRoot
        )
        return Placement(start: startCommit, indexTree: indexTree, fullTree: fullTree, startChanges: Set(startChanges))
    }

    /// `tree`, a change from `base`, merged onto `start`: the tree the
    /// merge makes. Git merges commits, so `tree` is given one on `base`
    /// first; it stays out of every ref, as the trees do.
    private static func merge(_ tree: String, from base: String, onto start: String, in repoRoot: URL) async throws -> String {
        let commit = try await output(
            ["commit-tree", "--no-gpg-sign", "-p", base, "-m", "weir-carry", tree],
            in: repoRoot,
            environment: internalIdentity
        )
        let result = try await run(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", "--merge-base=\(base)", start, commit],
            in: repoRoot
        )
        switch result.exitCode {
        case 0:
            return result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        case 1:
            throw UncommittedCarryRefusal.conflicts(UncommittedCarryRules.conflictPaths(mergeTreeOutput: result.stdout))
        default:
            if UncommittedCarryRules.isUnknownOption(exitCode: result.exitCode, stderr: result.stderr) {
                throw UncommittedCarryRefusal.unsupportedGit
            }
            throw UncommittedCarryRefusal.git(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - 3 and 4. Apply, then take away

    /// Puts `placement` into the new worktree at `target`, checks it there,
    /// then takes the snapshot out of its source. Never throws: each way it
    /// can end is an `Outcome`, and none of them loses a change.
    /// `headChecked` runs once the source's HEAD was found unmoved, before
    /// its index is locked: a test moves HEAD there, so only the check
    /// under the lock can see it.
    static func move(
        _ snapshot: Snapshot,
        placement: Placement,
        into target: URL,
        headChecked: @Sendable () async -> Void = {}
    ) async -> Outcome {
        guard await apply(placement, of: snapshot, to: target) else { return .notApplied }
        return await clear(snapshot, headChecked: headChecked)
    }

    /// Step 3. `true` once the new worktree holds the placement, checked;
    /// else the paths we carried are put back to its start. A worktree
    /// with tracked changes of its own is refused before we write and
    /// left as it is.
    private static func apply(_ placement: Placement, of snapshot: Snapshot, to target: URL) async -> Bool {
        // The new worktree is at the start it was made from; anything else
        // and the merge was for another commit.
        guard let head = try? await output(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: target),
              head == placement.start
        else { return false }
        // Nothing in it but its start, before we write: a `post-checkout`
        // hook may have changed or staged a tracked file, and the checks
        // below compare the whole worktree with the placement, so that
        // change would fail them and be taken back as ours. Files Git does
        // not track may stay: `read-tree` refuses to write over one.
        guard await hasNoTrackedChanges(target) else {
            log.info("carry: the new worktree has changes of its own; it is left as it is")
            return false
        }
        // Checks every path before writing any: a file the checkout's hook
        // made where a change goes stops it with nothing written, and the
        // worktree keeps that file. Only a run that did not finish may have
        // written part of the change, which the reset takes back.
        do {
            guard try await run(["read-tree", "-m", "-u", "HEAD", placement.fullTree], in: target).succeeded else {
                log.error("carry: the new worktree refused the changes")
                return false
            }
        } catch {
            await reset(target, from: placement)
            return false
        }
        let isPlaced = await isHolding(placement, in: target)
            && hasSameBytes(snapshot, placement: placement, in: target)
        if !isPlaced {
            await reset(target, from: placement)
        }
        return isPlaced
    }

    /// The index set to the placement's (its working tree is already the
    /// placement's), and both checked: the index as a tree, and every file
    /// against the placement's working tree.
    private static func isHolding(_ placement: Placement, in target: URL) async -> Bool {
        guard await (try? output(["read-tree", placement.indexTree], in: target)) != nil,
              let index = try? await gitPaths(["index"], in: target).first
        else { return false }
        // Stat data for the index just read; the files that differ from it
        // are the unstaged changes, so its exit says nothing here.
        _ = try? await run(["update-index", "-q", "--refresh"], in: target)
        return await (try? withScratch { scratch in
            let copy = scratch.appendingPathComponent("index")
            try copyIndex(index, to: copy)
            let indexTree = try await output(["write-tree"], in: target, environment: ["GIT_INDEX_FILE": copy.path])
            guard indexTree == placement.indexTree else { return false }
            return try await matches(placement.fullTree, in: target, seed: index, scratch: scratch)
        }) ?? false
    }

    /// Whether every file the changes touch is in the new worktree byte
    /// for byte as in the source. Git compares files as it stores them, so
    /// a line-ending conversion or a filter could make two files Git calls
    /// the same differ on disk; the source would then lose its own bytes.
    /// A path the start changed too is the merge's, and only Git can say
    /// what it should be.
    private static func hasSameBytes(_ snapshot: Snapshot, placement: Placement, in target: URL) -> Bool {
        snapshot.changedPaths.allSatisfy { path in
            placement.startChanges.contains(path)
                || FileBytes(at: snapshot.source.appendingPathComponent(path)) == FileBytes(at: target.appendingPathComponent(path))
        }
    }

    /// Whether every file of `tree` is on disk in the worktree at `root`
    /// as `tree` has it, through a copy of the index at `seed` made into
    /// `tree`'s: the entries `tree` shares with the index keep their stat
    /// data, so only the files that differ are read again.
    private static func matches(_ tree: String, in root: URL, seed: URL, scratch: URL) async throws -> Bool {
        let check = scratch.appendingPathComponent("check-\(UUID().uuidString)")
        try copyIndex(seed, to: check)
        let environment = ["GIT_INDEX_FILE": check.path]
        try await output(["read-tree", "--reset", tree], in: root, environment: environment)
        return try await run(["update-index", "--refresh"], in: root, environment: environment).succeeded
    }

    /// Whether the worktree at `root` has no change to a tracked file,
    /// staged or not; `false` when Git cannot say.
    private static func hasNoTrackedChanges(_ root: URL) async -> Bool {
        guard let result = try? await run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=none"],
            in: root
        ) else { return false }
        return result.succeeded && result.stdout.isEmpty
    }

    /// Puts the new worktree back at its start where the placement wrote,
    /// and nowhere else: the index entries and the files of the paths the
    /// placement changes from the start. A reset of the whole worktree
    /// would also take back what anything else wrote there meanwhile, as a
    /// hook's job still running does, and that is not ours to undo.
    ///
    /// The index entries are set to the placement's first, so the restore
    /// removes a file the placement added even where a run that did not
    /// finish wrote the file and not its entry.
    private static func reset(_ target: URL, from placement: Placement) async {
        let start = placement.start
        do {
            let written = try await names(in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", start, placement.fullTree], target)
            let staged = try await names(in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames", start, placement.indexTree], target)
            let carried = Set(written).union(staged)
            guard !carried.isEmpty else { return }
            let entries = try await output(["ls-tree", "-r", "-z", "--full-tree", placement.fullTree], in: target, trims: false)
            let placed = entries.split(separator: "\0").compactMap { cacheInfo($0, keeping: carried) }
            let placedPaths = Set(placed.compactMap { $0.split(separator: ",", maxSplits: 2).last.map(String.init) })
            for batch in batches(of: carried.subtracting(placedPaths).sorted()) {
                try await output(["update-index", "--force-remove", "--"] + batch, in: target)
            }
            for batch in batches(of: placed) {
                try await output(["update-index", "--add", "--replace"] + batch.flatMap { ["--cacheinfo", $0] }, in: target)
            }
            // A path only the index changed has the start's entry now, and
            // its file was never written.
            guard !written.isEmpty else { return }
            try await withScratch { scratch in
                let list = scratch.appendingPathComponent("paths")
                try Data(written.joined(separator: "\0").utf8).write(to: list)
                try await output(
                    ["restore", "--source=HEAD", "--staged", "--worktree", "--pathspec-from-file=\(list.path)", "--pathspec-file-nul"],
                    in: target,
                    // Git takes the paths as they are, never as patterns.
                    environment: ["GIT_LITERAL_PATHSPECS": "1"]
                )
            }
        } catch {
            log.error("carry: the new worktree could not be put back: \(String(describing: error), privacy: .private)")
        }
    }

    /// Step 4: the snapshot taken out of its source, only as it was read.
    private static func clear(_ snapshot: Snapshot, headChecked: @Sendable () async -> Void) async -> Outcome {
        let root = snapshot.source
        guard await isAtSnapshotHead(snapshot), let index = try? await gitPaths(["index"], in: root).first else { return .leftInSource }
        await headChecked()
        // Git's own lock on the index: while we hold it, no other Git
        // writes the index, and every Git that would waits or gives up.
        guard let lock = await IndexLock.acquire(for: index) else {
            log.info("carry: the source's index is locked; its changes stay")
            return .leftInSource
        }
        defer { lock.release() }
        // Again under the lock: `git commit -m` moves HEAD while it holds
        // the lock, and going back to the old HEAD would then undo that
        // commit. A `git commit` waiting on its message editor holds no lock
        // and has not moved HEAD yet; that one we cannot see
        // (docs/known-limitations.md).
        guard await isAtSnapshotHead(snapshot) else { return .leftInSource }
        return await (try? withScratch { scratch -> Outcome in
            // The index as read: nothing staged or unstaged since.
            let copy = scratch.appendingPathComponent("index")
            try copyIndex(index, to: copy)
            let indexTree = try await output(["write-tree"], in: root, environment: ["GIT_INDEX_FILE": copy.path])
            guard indexTree == snapshot.indexTree else { return .leftInSource }
            // The next index starts as the snapshot's, checked against every
            // file on disk; then the working tree goes back to HEAD through
            // it, which refuses, writing nothing, if a file changed since.
            let next = scratch.appendingPathComponent("next")
            try copyIndex(index, to: next)
            let environment = ["GIT_INDEX_FILE": next.path]
            try await output(["read-tree", "--reset", snapshot.fullTree], in: root, environment: environment)
            guard try await run(["update-index", "--refresh"], in: root, environment: environment).succeeded else {
                return .leftInSource
            }
            // Again just before Git writes: an ignored file a build made
            // since the snapshot, where the changes delete a tracked one,
            // would be written over, and Git takes ignored files as its own
            // to replace.
            guard try await ignoredFileInTheWay(in: root, deleted: snapshot.deletedPaths) == nil else { return .leftInSource }
            let cleared: GitResult
            do {
                cleared = try await run(["read-tree", "-m", "-u", snapshot.fullTree, snapshot.head], in: root, environment: environment)
            } catch {
                // A run that did not finish may have written part of it.
                if await isUntouched(snapshot, index: index, scratch: scratch) {
                    return .leftInSource
                }
                log.error("carry: the source was cleared part way: \(String(describing: error), privacy: .private)")
                return await .partlyCleared(stash: keepAsStash(snapshot))
            }
            guard cleared.succeeded else {
                // Git checks every path before it writes any: a refusal, as
                // for a file that changed, wrote nothing.
                log.info("carry: the source changed; its changes stay: \(cleared.stderr, privacy: .private)")
                return .leftInSource
            }
            // HEAD moved by a command that takes no lock on the index
            // (`update-ref`, `reset --soft`): the new index would be for the
            // old one.
            guard await isAtSnapshotHead(snapshot), lock.commit(contentsOf: next) else {
                log.error("carry: the source's new index could not be put in place")
                return await .partlyCleared(stash: keepAsStash(snapshot))
            }
            return .moved(files: snapshot.fileCount)
        }) ?? .leftInSource
    }

    /// Whether the source's HEAD is the commit and the branch it was when
    /// the changes were read.
    private static func isAtSnapshotHead(_ snapshot: Snapshot) async -> Bool {
        let head = try? await output(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: snapshot.source)
        let branch = await headBranch(in: snapshot.source)
        return head == snapshot.head && branch == snapshot.branch
    }

    /// Whether the source's working tree is still the snapshot's, every
    /// file, the ones the snapshot had deleted included: the tree its
    /// index (unchanged while the lock is ours) makes of the whole working
    /// tree is the snapshot's.
    private static func isUntouched(_ snapshot: Snapshot, index: URL, scratch: URL) async -> Bool {
        let copy = scratch.appendingPathComponent("again-\(UUID().uuidString)")
        guard (try? copyIndex(index, to: copy)) != nil else { return false }
        let environment = ["GIT_INDEX_FILE": copy.path]
        guard await (try? output(["add", "-A", "--", ":/"], in: snapshot.source, environment: environment)) != nil else { return false }
        return await (try? output(["write-tree"], in: snapshot.source, environment: environment)) == snapshot.fullTree
    }

    // MARK: - The copy kept

    /// The snapshot stored as a stash entry, shaped as `git stash push
    /// --include-untracked` makes one, so `git stash apply --index` takes
    /// it back: its name, or `nil` when it could not be stored.
    static func keepAsStash(_ snapshot: Snapshot) async -> String? {
        let root = snapshot.source
        let name = "weir-carry-\(UUID().uuidString.prefix(8).lowercased())"
        return await (try? withScratch { scratch -> String in
            let indexCommit = try await output(
                ["commit-tree", "--no-gpg-sign", "-p", snapshot.head, "-m", "index on \(name)", snapshot.indexTree],
                in: root,
                environment: internalIdentity
            )
            // The working tree without the untracked files, which the third
            // parent holds on their own.
            let tracked = ["GIT_INDEX_FILE": scratch.appendingPathComponent("tracked").path]
            try await output(["read-tree", snapshot.fullTree], in: root, environment: tracked)
            var parents = ["-p", snapshot.head, "-p", indexCommit]
            if !snapshot.untracked.isEmpty {
                for batch in batches(of: snapshot.untracked) {
                    try await output(["update-index", "--force-remove", "--"] + batch, in: root, environment: tracked)
                }
                let untracked = ["GIT_INDEX_FILE": scratch.appendingPathComponent("untracked").path]
                let entries = try await output(["ls-tree", "-r", "-z", "--full-tree", snapshot.fullTree], in: root, trims: false)
                let isUntracked = Set(snapshot.untracked)
                let cacheInfo = entries.split(separator: "\0").compactMap { Self.cacheInfo($0, keeping: isUntracked) }
                for batch in batches(of: cacheInfo) {
                    try await output(["update-index", "--add"] + batch.flatMap { ["--cacheinfo", $0] }, in: root, environment: untracked)
                }
                let untrackedTree = try await output(["write-tree"], in: root, environment: untracked)
                let untrackedCommit = try await output(
                    ["commit-tree", "--no-gpg-sign", "-m", "untracked files on \(name)", untrackedTree],
                    in: root,
                    environment: internalIdentity
                )
                parents += ["-p", untrackedCommit]
            }
            let workTree = try await output(["write-tree"], in: root, environment: tracked)
            let stash = try await output(
                ["commit-tree", "--no-gpg-sign"] + parents + ["-m", "On \(name): Weir kept these changes", workTree],
                in: root,
                environment: internalIdentity
            )
            try await output(["stash", "store", "-m", name, stash], in: root)
            return name
        })
    }

    /// `ls-tree`'s `<mode> <type> <object>\t<path>` as `--cacheinfo`'s
    /// `<mode>,<object>,<path>`, for a path among `paths`.
    private static func cacheInfo(_ entry: Substring, keeping paths: Set<String>) -> String? {
        guard let tab = entry.firstIndex(of: "\t") else { return nil }
        let path = String(entry[entry.index(after: tab)...])
        let meta = entry[..<tab].split(separator: " ")
        guard meta.count == 3, paths.contains(path) else { return nil }
        return "\(meta[0]),\(meta[2]),\(path)"
    }

    /// Paths a few hundred at a time, so no command line passes what the
    /// system takes.
    private static func batches(of items: [String]) -> [[String]] {
        stride(from: 0, to: items.count, by: 256).map { Array(items[$0..<min($0 + 256, items.count)]) }
    }

    // MARK: - Running Git

    /// Who the carry's own commits are by. They are in no branch, only in
    /// the trees merged and the stash kept, and must not stop on a person
    /// who set no name: `commit-tree` refuses without one.
    private static let internalIdentity = [
        "GIT_AUTHOR_NAME": "Weir", "GIT_AUTHOR_EMAIL": "weir@localhost",
        "GIT_COMMITTER_NAME": "Weir", "GIT_COMMITTER_EMAIL": "weir@localhost"
    ]

    /// Each run may take as long as adding a worktree may: reading every
    /// file of a large worktree, or writing back what changed, takes far
    /// longer than a read's ten seconds, and a run ended part way is the
    /// one way the carry could leave a worktree half written.
    private static func run(_ arguments: [String], in root: URL, environment: [String: String] = [:]) async throws -> GitResult {
        do {
            return try await GitProcess.run(arguments, cwd: root, timeout: GitProcess.worktreeTimeout, environment: environment)
        } catch {
            throw UncommittedCarryRefusal.git(DisplayText(error: error).resolved(in: Locale(identifier: "en")))
        }
    }

    /// What `git <arguments>` printed, trimmed unless `trims` is off;
    /// throws its words when it fails.
    @discardableResult
    private static func output(
        _ arguments: [String],
        in root: URL,
        environment: [String: String] = [:],
        trims: Bool = true
    ) async throws -> String {
        let result = try await run(arguments, in: root, environment: environment)
        guard result.succeeded else {
            throw UncommittedCarryRefusal.git(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return trims ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdout
    }

    /// Where `names` are in the worktree's Git folder (`index`,
    /// `MERGE_HEAD`), as absolute paths. Git answers relative to its own
    /// working folder unless asked otherwise; resolved here, a relative
    /// answer would land beside the worktree rather than in it, and the
    /// lock taken on an index that is not the worktree's would guard
    /// nothing.
    private static func gitPaths(_ names: [String], in root: URL) async throws -> [URL] {
        let paths = try await output(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }, in: root)
            .split(separator: "\n")
            .map(String.init)
        guard paths.count == names.count, paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw UncommittedCarryRefusal.git(paths.joined(separator: " "))
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func isOn(_ key: String, in root: URL) async -> Bool {
        await (try? output(["config", "--type=bool", "--get", key], in: root)) == "true"
    }

    /// A copy of the index at `index`. A worktree with a commit and no
    /// index is one Git checked nothing out in: read as empty, every file
    /// would look deleted, so it is refused instead.
    private static func copyIndex(_ index: URL, to copy: URL) throws {
        guard FileManager.default.fileExists(atPath: index.path) else {
            throw UncommittedCarryRefusal.git("\(index.path): no index")
        }
        try FileManager.default.copyItem(at: index, to: copy)
    }

    /// `body` with a folder of its own under the temporary folder, removed
    /// after it.
    private static func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("weir-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await body(scratch)
    }
}

/// What is on disk at a path, as the carry compares two worktrees: nothing,
/// a symbolic link and where it points, or a file's bytes and whether it
/// runs. A folder is no file of a change.
struct FileBytes: Equatable {
    enum Kind: Equatable {
        case missing
        case link(String)
        case file(Data, isExecutable: Bool)
        case unreadable
    }

    let kind: Kind

    init(at url: URL) {
        // `lstat`, so a link is read as the link rather than what it names.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            kind = errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            kind = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map(Kind.link) ?? .unreadable
        case S_IFREG:
            let isExecutable = info.st_mode & S_IXUSR != 0
            kind = (try? Data(contentsOf: url)).map { .file($0, isExecutable: isExecutable) } ?? .unreadable
        default:
            kind = .unreadable
        }
    }

    /// Two that could not be read are not the same.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.kind, rhs.kind) {
        case (.unreadable, _), (_, .unreadable): false
        default: lhs.kind == rhs.kind
        }
    }
}

/// Git's lock on an index, taken as Git takes it: `<index>.lock` made with
/// `O_EXCL`, so only one process holds it, then renamed over the index to
/// put a new one in place at once. Any Git that wants to write the index
/// meanwhile finds the lock and stops or waits.
///
/// Not `Sendable`: one task takes it, uses it, and lets it go.
final class IndexLock {
    let index: URL
    private let lock: URL
    /// The open lock file, closed by `commit` or `release`; -1 once closed.
    private var descriptor: Int32

    private init(index: URL, lock: URL, descriptor: Int32) {
        self.index = index
        self.lock = lock
        self.descriptor = descriptor
    }

    /// A lock never let go, as when the task holding it is torn down, is
    /// let go here, or every Git in the worktree would stop on it.
    deinit {
        release()
    }

    /// How long to wait for another Git to let the lock go: `git status`
    /// holds it a moment to refresh the index.
    static let patience: Duration = .seconds(2)

    /// `nil` when another holds the lock past `patience`, or `index` is no
    /// index: a lock beside a file that is not there guards nothing.
    static func acquire(for index: URL) async -> IndexLock? {
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let deadline = ContinuousClock.now + patience
        repeat {
            let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if descriptor >= 0 {
                return IndexLock(index: index, lock: lock, descriptor: descriptor)
            }
            guard errno == EEXIST else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return nil
    }

    /// The index at `next` written into the lock and renamed over the
    /// index, as Git puts a new index in place. `false` leaves the old
    /// index as it was.
    func commit(contentsOf next: URL) -> Bool {
        guard descriptor >= 0, let data = try? Data(contentsOf: next) else { return false }
        let isWritten = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return fsync(descriptor) == 0
        }
        close(descriptor)
        descriptor = -1
        guard isWritten, rename(lock.path, index.path) == 0 else {
            unlink(lock.path)
            return false
        }
        return true
    }

    /// Lets the lock go without changing the index, unless `commit` put a
    /// new one in place already.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        unlink(lock.path)
    }
}
