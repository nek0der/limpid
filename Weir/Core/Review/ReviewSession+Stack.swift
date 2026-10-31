// ReviewSession+Stack.swift
// Weir — the session's side of the review tab's stacked diff: which files to read, and what each read changes.

import Foundation

extension ReviewSession {
    /// The files on screen and a screen either side: read the ones not read
    /// yet, and keep them all while the reader is there.
    func loadStacked(window fileIDs: [String]) {
        let window = Set(fileIDs)
        // Asked on every scroll event, so the common answer, nothing new, is
        // found before the list is looked at.
        guard window != stackLoader.window || window.contains(where: stackLoader.needsDiff) else { return }
        let requests = files
            .filter { window.contains($0.id) && stackLoader.needsDiff($0.id) }
            .map { ReviewStackLoader.Request(file: $0, scope: scopeForFile($0)) }
        stackLoader.request(requests, window: window)
    }

    /// Find searches every file of the range: reads the rest of
    /// `files`, as far as the budget goes (`estimatedLines`). The estimate
    /// opens untracked files, so it is worked out off the main actor; a list
    /// read again meanwhile is asked about by the review itself.
    func loadStackForSearch(_ files: [ReviewFile]) {
        let stats = stats
        let root = root
        let listRead = listReadCount
        // Taken now, so a Find closed before the estimate is back drops it.
        let ticket = stackLoader.beginSearch()
        let requests = files.map { ReviewStackLoader.Request(file: $0, scope: scopeForFile($0)) }
        Task {
            let estimates = await Task.detached(priority: .userInitiated) {
                files.reduce(into: [String: Int]()) { estimates, file in
                    if let estimate = Self.estimatedLines(file, stat: stats[file.id], root: root) {
                        estimates[file.id] = estimate
                    }
                }
            }.value
            guard listReadCount == listRead else { return }
            // A file whose counts say it is past what a diff can hold cannot
            // be read, and is not counted against the budget; the find bar
            // then says it searched the files read. Only where the counts
            // are the diff's own size (a file added or deleted whole): the
            // estimate for the rest is rough, and they are tried.
            let unreadable = Set(files.filter { file in
                Self.isExactEstimate(file, stat: stats[file.id]) && (estimates[file.id] ?? 0) >= ReviewDiffParser.maxRows
            }.map(\.id))
            stackLoader.requestAll(
                requests.filter { !unreadable.contains($0.file.id) },
                estimates: estimates,
                ticket: ticket,
                isPartial: !unreadable.isEmpty
            )
        }
    }

    /// Whether a file's counts are its diff's size: it was added or deleted
    /// whole, so every line is in the diff and nothing else is.
    nonisolated static func isExactEstimate(_ file: ReviewFile, stat: ReviewFileStat?) -> Bool {
        guard let stat, !stat.isBinary else { return false }
        switch file.status {
        case .added, .deleted, .untracked: return true
        default: return false
        }
    }

    /// About how many rows a file's diff holds before it is read, at most
    /// `ReviewDiffParser.maxRows` (past that it is not read at all). A file
    /// added or deleted whole is its lines and a header; a change elsewhere
    /// adds a hunk header and its context for about every dozen changed
    /// lines; an untracked file is its length, a line for every 32 bytes,
    /// near what source runs to, and one row if it is not text. `nil` where
    /// none of that is known, and the stack assumes
    /// `ReviewStackLoader.unknownLineEstimate`.
    nonisolated static func estimatedLines(_ file: ReviewFile, stat: ReviewFileStat?, root: URL) -> Int? {
        let rows: Int
        if let stat {
            guard !stat.isBinary else { return 1 }
            let changed = stat.added + stat.removed
            switch file.status {
            case .added, .deleted, .untracked:
                rows = changed + 2
            default:
                rows = changed + contextPerHunk * max(1, changed / 12) + 1
            }
        } else {
            guard file.layer == .untracked, let size = untrackedTextSize(root.appendingPathComponent(file.path)) else { return nil }
            rows = size / 32 + 1
        }
        return min(rows, ReviewDiffParser.maxRows)
    }

    /// An untracked file's size, `0` for one that is not text (a NUL in its
    /// first few kilobytes, as Git decides), `nil` when it cannot be read.
    private nonisolated static func untrackedTextSize(_ url: URL) -> Int? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8000)) ?? Data()
        return head.contains(0) ? 0 : size
    }

    /// A hunk header and the three lines of context Git gives either side.
    private nonisolated static var contextPerHunk: Int {
        7
    }

    /// Keeps the open file's diff in the stack, so the file draws the same
    /// rows when another is opened.
    func rememberInStack(_ diff: ReviewDiff, read: StackRead) {
        stackLoader.remember(diff, state: read.state, serial: read.serial, scope: scopeForFile(diff.file))
    }

    /// A read of the open file, as the stack numbers and records its own.
    struct StackRead {
        let serial: Int
        let state: ReviewReadState?
    }

    /// Starts a read of the open file for the stack: its number, and what
    /// the file is just before it (nothing for a fixed range of turns, which
    /// cannot change). `nil` with no file to read.
    func beginStackRead(_ file: ReviewFile?, scope: ReviewScope) async -> StackRead? {
        guard let file else { return nil }
        if case .turns = scope {
            return StackRead(serial: stackLoader.beginRead(), state: nil)
        }
        let state = await stackLoader.takeState(of: file, scope: scope)
        // Numbered after its state, as the stack's own reads are: the read
        // itself comes next.
        return StackRead(serial: stackLoader.beginRead(), state: state)
    }

    /// Each file the stack read is checked as the open file is: a comment
    /// written against another version of it is stale, and a read mark on
    /// code that has since changed comes off.
    func reconcileStacked(_ diffs: [ReviewDiff]) {
        let listed = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Not the open file: what is displayed of it is its own diff, which
        // a background read can be another version of.
        for diff in diffs where diff.file.id != self.diff?.file.id {
            guard let file = listed[diff.file.id] else { continue }
            reconcileLoadedDiff(diff, for: file)
        }
    }
}
