// ReviewStackNavigation.swift
// Limpid — moving between the files of the review tab's stacked diff: where a click or a key lands, and which file the reader is in.

import Foundation

/// A place the reader asked to be taken to, held while its file opens.
struct ReviewJump: Equatable {
    let fileID: String
    let start: Int
    let end: Int
    /// The column the comment was written in, so landing on it in the split
    /// layout selects the run the reader will recognize.
    var side: ReviewSide?
    /// What follows the landing. A file opened from the stacked diff by a
    /// key or a button that acts on it does that once the file is open.
    var then: Follow = .select
    /// The diff `start` and `end` were read in, `nil` where any will do. A
    /// file opened from Git can have changed since its rows were drawn, and
    /// the same ids then name other code.
    var fingerprint: String?

    enum Follow: Equatable {
        case select
        /// Opens the composer on the run (`c`).
        case compose
        /// The hunk header's "Comment", by the header's id in the file.
        case commentHunk(Int)
        /// A card's Edit, which finds its comment by id.
        case edit(UUID)
    }
}

/// The decisions behind opening one file of the stacked diff after another.
/// Everything that acts on a line acts on the open file; a click, a key, or
/// a button in another file opens that file first, and so does scrolling to
/// it and stopping there.
enum ReviewStackNavigation {
    /// What a jump does once its file is open.
    enum Landing: Equatable {
        case select(start: Int, end: Int, side: ReviewSide?, composes: Bool)
        case commentHunk(Int)
        case edit(UUID)
        /// The file changed since the jump was made: to its header, with no
        /// line chosen for the reader.
        case header
    }

    static func landing(_ jump: ReviewJump, in diff: ReviewDiff) -> Landing {
        // An edit too: a comment written on another version of the file is
        // not about what is drawn now.
        if let fingerprint = jump.fingerprint, fingerprint != diff.fingerprint {
            return .header
        }
        switch jump.then {
        case let .commentHunk(id):
            return diff.lines.contains { $0.id == id && $0.kind == .hunk } ? .commentHunk(id) : .header
        case .select, .compose:
            return .select(start: jump.start, end: jump.end, side: jump.side, composes: jump.then == .compose)
        case let .edit(id):
            return .edit(id)
        }
    }

    /// The jump left waiting when a file is asked to open: the one asked
    /// for, or one already waiting for that same file (a comment chosen in
    /// the list, then its file). A jump for another file has been overtaken.
    static func pending(opening fileID: String, asked: ReviewJump?, waiting: ReviewJump?) -> ReviewJump? {
        asked ?? waiting.flatMap { $0.fileID == fileID ? $0 : nil }
    }

    /// What the reader's state says about opening the file they scrolled to.
    struct Reader {
        var openFileID: String?
        var isComposerOpen = false
        var isLoading = false
        var hasPendingJump = false
        /// Dragged text, which opening another file would let go of.
        var hasTextSelection = false
    }

    /// Whether to open the file the reader stopped at. Not while a comment
    /// is being written (it belongs to its file), while a load or a jump is
    /// under way, or while text is selected; and not a file whose read gave
    /// nothing to act on (`ReviewStackEntry.isOpenable`). A file not read
    /// yet opens, and is read as it does.
    static func readsOn(_ fileID: String, reader: Reader, entry: ReviewStackEntry?) -> Bool {
        guard fileID != reader.openFileID, !reader.isComposerOpen, !reader.isLoading,
              !reader.hasPendingJump, !reader.hasTextSelection
        else { return false }
        return entry.map(\.isOpenable) ?? true
    }
}

extension ReviewStack {
    /// The jump a cursor or a run makes when it reaches a file other than
    /// the open one, by a click, `j`, `]`, or Find; `nil` while it is in the
    /// open file. A run stays in one file: one that crossed into another
    /// starts over on the line it reached.
    func route(_ lines: ReviewSelection, then follow: ReviewJump.Follow = .select) -> ReviewJump? {
        guard let head = lines.headLineID, let target = locate(lineID: head),
              let section = section(of: target.fileID), !section.isOpen
        else { return nil }
        let anchor = lines.anchorLineID.flatMap { locate(lineID: $0) }
        let start = anchor.flatMap { $0.fileID == target.fileID ? $0.lineID : nil } ?? target.lineID
        return ReviewJump(
            fileID: target.fileID,
            start: start,
            end: target.lineID,
            side: lines.side,
            then: follow,
            fingerprint: section.fingerprint
        )
    }

    /// The file the reader is in: the first file drawn whole with rows from
    /// `probe` down to `bottom`, the last row on screen. A folded file is
    /// only its header and has nothing to open.
    func readingFile(probe: Int, bottom: Int) -> String? {
        guard probe >= 0, probe < rows.count else { return nil }
        let end = bottom >= probe ? min(bottom + 1, rows.count) : rows.count
        return sections(in: probe..<end).first { section in
            if case let .file(header) = rows[section.headerRow].kind {
                return !header.isFolded
            }
            return false
        }?.file.id
    }
}
