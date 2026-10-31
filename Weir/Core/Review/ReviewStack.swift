// ReviewStack.swift
// Weir — every file of the review tab's range as one row list, file under file.

import Foundation
import WeirDomain

/// What a file's header in the stacked diff says about how it changed.
enum ReviewFileMark: Hashable, Sendable, CaseIterable {
    /// The file did not exist before the range.
    case new
    /// A shell command, not only the agent's edit tools, changed the file.
    /// Never given yet: a turn records only whether a shell command changed
    /// anything, not which paths, and the mark stays hidden until that
    /// attribution is recorded per file.
    case changedByBash
    /// The file changed while no turn of the conversation was running.
    case changedOutsideTurns

    /// The marks of one file, in the order the header draws them. The paths
    /// are worktree-relative, as `ReviewFile.path` is.
    static func marks(
        for file: ReviewFile,
        changedByBash: Set<String>,
        changedOutsideTurns: Set<String>
    ) -> [ReviewFileMark] {
        var marks: [ReviewFileMark] = []
        // A copy is a path that was not there either, which is what the mark
        // tells the reader: there is no earlier version to compare against.
        switch file.status {
        case .added, .untracked, .copied:
            marks.append(.new)
        case .deleted, .modified, .renamed, .typeChanged, .unmerged, .unknown:
            break
        }
        if changedByBash.contains(file.path) {
            marks.append(.changedByBash)
        }
        if changedOutsideTurns.contains(file.path) {
            marks.append(.changedOutsideTurns)
        }
        return marks
    }
}

/// A conversation whose turns changed a file within the range read, on the
/// file's header in the stacked diff: its identity bar and badge, with the
/// turns in its tooltip. That the file changed during those turns, not that the
/// conversation wrote it: a turn's diff is what changed in the worktree
/// while it ran, whoever made the change.
struct ReviewFileTag: Hashable, Sendable {
    let provider: AgentKind
    /// The conversation's title, as the changes panel names it
    /// (`ConversationChoice.title`); `nil` for one with none.
    var title: String?
    /// Its place among the worktree's conversations of the kind, from 1,
    /// where its name alone does not tell it apart
    /// (`ConversationChoice.ordinal`); `nil` when the title, or the kind
    /// alone, names it.
    let ordinal: Int?
    /// The numbers of its turns that changed the file, in order.
    let turns: [Int]
    /// Its identity color, as the changes panel shows it
    /// (`ConversationChoice.identity`); `nil` for one that has none.
    var identity: Int?
}

/// The file headers' tags for a range: each file's, by path, and the
/// range's turns whose files could not be read, by conversation, which any
/// file's tags may lack.
struct ReviewFileTagSet: Hashable, Sendable {
    var byPath: [String: [ReviewFileTag]] = [:]
    var unreadable: [ReviewFileTag] = []
}

/// A file's header row in the stacked diff: the checkbox, the path, the
/// marks, the conversations whose turns changed it, and the counts.
struct ReviewStackHeader: Equatable {
    let file: ReviewFile
    /// `nil` for an untracked file, which Git has no counts for, and for a
    /// file whose change has gone since the list was read.
    let stat: ReviewFileStat?
    let marks: [ReviewFileMark]
    /// Empty outside a range of turns, in a worktree of one conversation,
    /// and until the turns' files have been read.
    var tags: [ReviewFileTag] = []
    /// The range's turns whose files could not be read, which the tags may
    /// lack (`ReviewFileTagSet.unreadable`); empty when every turn's were.
    var unreadableTags: [ReviewFileTag] = []
    /// Checked: the reader has read this far.
    let isViewed: Bool
    /// Collapsed to this row: checked, and neither opened again by hand
    /// nor drawn whole for a comment being written in it
    /// (`ReviewStackBuilder.unfolded`). Only a checked file folds, so only
    /// a checked file's header offers to open or fold it.
    let isFolded: Bool
}

/// What the stack holds for a file other than the open one: its diff, or
/// why there is none.
enum ReviewStackEntry {
    case loaded(ReviewDiff)
    /// Kept unresolved, like a diff's notice: the row resolves it in the
    /// language the table is drawn in.
    case failed(LocalizedStringResource)

    /// What a failed read says in place of the file's diff.
    static func failure(_ error: any Error) -> ReviewStackEntry {
        if case let .localized(resource) = DisplayText(error: error) {
            return .failed(resource)
        }
        return .failed("Git couldn’t load the changes. Try again.")
    }

    var diff: ReviewDiff? {
        if case let .loaded(diff) = self {
            return diff
        }
        return nil
    }

    /// Whether opening the file gives the reader something to act on. A
    /// failed read does not (too large, unreadable), nor a diff with no line
    /// to comment on (a binary file): opening those again on every stop of
    /// the scroll only asked Git the same question and put up its answer.
    var isOpenable: Bool {
        diff?.lines.contains(where: \.isCommentable) ?? false
    }
}

/// The ids the stacked rows give the lines of the files that are not open.
///
/// Every interaction of the review — the cursor, the run a comment covers,
/// the composer, unfolding, a hunk's buttons — names a line by its id in
/// the open file's diff. The other files' lines are numbered past every id
/// a diff can produce (`ReviewExpansionPlan.idBase` is below the first
/// offset), one band per file, so a line of one file never answers for a
/// line of another, and an id says which file it belongs to.
enum ReviewStackIDs {
    static let stride = 1 << 44

    /// The offset of the file at `slot` in the change list.
    static func offset(forSlot slot: Int) -> Int {
        (slot + 1) * stride
    }

    /// The slot an offset id belongs to, or `nil` for an id of the open file.
    static func slot(of id: Int) -> Int? {
        id >= stride ? id / stride - 1 : nil
    }
}

extension ReviewLine {
    /// The same line under another id: a file that is not open is drawn
    /// with its ids moved into its own band (`ReviewStackIDs`).
    func offset(by delta: Int) -> ReviewLine {
        ReviewLine(
            id: id + delta,
            kind: kind,
            text: text,
            oldLine: oldLine,
            newLine: newLine,
            isExpansion: isExpansion,
            hunkIndex: hunkIndex
        )
    }
}

extension ReviewRow.Kind {
    /// The same row with its lines moved by `delta`.
    func offset(by delta: Int) -> ReviewRow.Kind {
        guard delta != 0 else { return self }
        switch self {
        case let .hunk(line): return .hunk(line.offset(by: delta))
        case let .code(line): return .code(line.offset(by: delta))
        case let .composer(line): return .composer(line.offset(by: delta))
        case let .splitCode(pair):
            return .splitCode(ReviewSplitPair(old: pair.old?.offset(by: delta), new: pair.new?.offset(by: delta)))
        case .notice, .comment, .expander, .file:
            return self
        }
    }
}

/// A line on screen, and where it sits in the viewport: what the diff is
/// found again by after its rows are rebuilt, and what a review tab that
/// went with its project brings back of where it was read
/// (`ParkedReview.Tab.scroll`).
struct ReviewScrollAnchor: Equatable {
    /// The file and the line in the file's own numbering, or the file's
    /// header (`ReviewStack.anchorKey`).
    let key: String
    /// How far the line's top sits from the viewport's top.
    let offset: CGFloat
}

/// One file's place in the stacked rows.
struct ReviewStackSection: Equatable {
    let file: ReviewFile
    /// The header's row, which is where selecting the file scrolls to.
    let headerRow: Int
    /// One past the file's last row.
    let endRow: Int
    /// What the file's line ids are moved by: 0 for the open file.
    let idOffset: Int
    /// The fingerprint of the diff the rows were drawn from, `nil` while
    /// there is none: what says whether a line id still names the same code.
    let fingerprint: String?
    /// Whether the section's rows are what they stay until its diff
    /// changes: the open file, a file read (or one Git could not read), and
    /// a checked file, folded to its header whatever was read. A file not
    /// read yet stands as "Loading changes…" until it is.
    var isSettled = true

    var isOpen: Bool {
        idOffset == 0
    }
}

/// A file's rows in the stack, with its hunk headers, kept between builds by
/// the caller: a file's rows change only with its diff, its comments, and
/// the layout, and the stack is rebuilt far more often than that.
struct ReviewStackPiece {
    let rows: [ReviewRow]
    let hunkHeaders: [ReviewLine]
    /// The hunk headers, by the ids the rows carry, whose hunk has lines to
    /// comment on (`ReviewHunkRun.commentableHeaders`).
    let commentableHunks: Set<Int>

    init(rows: [ReviewRow], commentableHunks: Set<Int> = []) {
        self.rows = rows
        self.commentableHunks = commentableHunks
        hunkHeaders = rows.compactMap { row in
            if case let .hunk(line) = row.kind {
                return line
            }
            return nil
        }
    }

    /// A closed file's rows: its diff with the comments that are still about
    /// it, its ids moved by `offset`. A comment written against another
    /// version of the file is not about the line that now has its id, so it
    /// is left out here as the open file leaves out a stale one.
    static func closed(
        _ diff: ReviewDiff,
        offset: Int,
        comments: [ReviewComment],
        staleCommentIDs: Set<UUID>,
        layout: ReviewDiffLayout
    ) -> ReviewStackPiece {
        let rows = ReviewRowBuilder.rows(
            expanded: diff,
            comments: comments.filter { $0.fingerprint == diff.fingerprint },
            composerLineID: nil,
            staleCommentIDs: staleCommentIDs,
            layout: layout
        )
        return ReviewStackPiece(
            rows: rows.map { ReviewRow(id: $0.id, kind: $0.kind.offset(by: offset)) },
            commentableHunks: Set(ReviewHunkRun.commentableHeaders(in: diff.lines).map { $0 + offset })
        )
    }

    /// A closed file's comment markers, by its own ids: none, at once, for
    /// a file nobody has commented on, which is most of them.
    static func closedCounts(_ diff: ReviewDiff, comments: [ReviewComment]) -> [Int: Int] {
        let current = comments.filter { $0.fingerprint == diff.fingerprint }
        guard !current.isEmpty else { return [:] }
        return ReviewRowBuilder.lineCommentCounts(comments: current, fileID: diff.file.id, lines: diff.lines)
    }
}

/// The review tab's diff: every file of the range, file under file, each
/// under its header. One row list, so the table draws a screen of it at
/// a time however many files the range has.
///
/// A row's `id` here is its position in its file's rows, not in the stack:
/// each file's rows are kept between builds and appended as they are.
struct ReviewStack {
    private(set) var rows: [ReviewRow] = []
    private(set) var sections: [ReviewStackSection] = []
    /// Every loaded file's character highlights, by the ids the rows carry.
    private(set) var intralineHighlights = ReviewIntralineHighlights()
    /// Every loaded file's comment markers, by the ids the rows carry.
    private(set) var commentCounts: [Int: Int] = [:]
    /// Each drawn file's hunk headers, by file id, with the ids the rows
    /// carry: what the headers' buttons offer is asked per file.
    private(set) var hunkHeaders: [String: [ReviewLine]] = [:]
    /// Every drawn file's hunk headers that "Comment" can act on.
    private(set) var commentableHunks: Set<Int> = []
    private var sectionBySlot: [Int: Int] = [:]
    private var sectionByFile: [String: Int] = [:]

    /// The file a row belongs to.
    func section(atRow row: Int) -> ReviewStackSection? {
        guard row >= 0, row < rows.count else { return nil }
        // The last section whose header is at or above the row.
        var low = 0
        var high = sections.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if sections[middle].headerRow <= row {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found.map { sections[$0] }
    }

    func section(of fileID: String) -> ReviewStackSection? {
        sectionByFile[fileID].map { sections[$0] }
    }

    /// The row selecting a file in the list scrolls to: its header, at the
    /// top of the diff.
    func headerRow(of fileID: String) -> Int? {
        section(of: fileID)?.headerRow
    }

    /// The file a line id of these rows belongs to, and the id that file's
    /// own diff gives the line.
    func locate(lineID: Int) -> (fileID: String, lineID: Int)? {
        guard let slot = ReviewStackIDs.slot(of: lineID) else {
            return sections.first(where: \.isOpen).map { ($0.file.id, lineID) }
        }
        guard let index = sectionBySlot[slot] else { return nil }
        let section = sections[index]
        return (section.file.id, lineID - section.idOffset)
    }

    /// The sections with rows in `range`, for reading the diffs that are
    /// about to be on screen.
    func sections(in range: Range<Int>) -> [ReviewStackSection] {
        guard !range.isEmpty, let first = section(atRow: max(range.lowerBound, 0)) else { return [] }
        guard let start = sectionByFile[first.file.id] else { return [] }
        return Array(sections[start...].prefix { $0.headerRow < range.upperBound })
    }

    /// What a row can be found again by after the rows are rebuilt: the
    /// file, the line in that file's own numbering, which stays the same
    /// when the file is opened or closed and its ids move, and the diff the
    /// line was read in.
    func anchorKey(atRow row: Int) -> String? {
        guard let section = section(atRow: row) else { return nil }
        if row == section.headerRow {
            return "h|" + section.file.id
        }
        guard let line = rows[row].anchorLine else { return nil }
        return "l|\(line.id - section.idOffset)|\(section.fingerprint ?? "")|" + section.file.id
    }

    /// The row an anchor names, or `nil` when it is gone. A file whose diff
    /// has changed since puts the reader at its header: the line's id no
    /// longer names the code they were reading.
    func row(forAnchorKey key: String) -> Int? {
        let parts = key.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        switch parts.first {
        case "h":
            let rest = key.dropFirst(2)
            return headerRow(of: String(rest))
        case "l":
            guard parts.count == 4, let local = Int(parts[1]), let section = section(of: String(parts[3])) else { return nil }
            guard section.fingerprint == String(parts[2]) else { return section.headerRow }
            let id = local + section.idOffset
            return (section.headerRow..<section.endRow).first { rows[$0].anchorLine?.id == id }
        default:
            return nil
        }
    }

    /// Where a position kept for the stacked diff stands in these rows
    /// (`ReviewScrollAnchor`): what bringing it back can do now.
    private enum Restore: Equatable {
        /// The row the anchor names.
        case row(Int)
        /// The anchor's file is not read yet: its lines are there once it is.
        case waiting(fileID: String)
        /// The line is gone: its file left the range, its diff changed, or
        /// it is folded away.
        case gone
    }

    /// The row a position kept for the stacked diff names, once its file
    /// has been read. Unlike `row(forAnchorKey:)`, which answers a line of
    /// a file whose diff changed with the file's header so a rebuild keeps
    /// the reader near it, a kept line whose code changed is gone.
    private func restore(forAnchorKey key: String) -> Restore {
        let parts = key.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        if parts.first == "l", parts.count == 4, let section = section(of: String(parts[3])) {
            guard section.isSettled else { return .waiting(fileID: section.file.id) }
            guard section.fingerprint == String(parts[2]) else { return .gone }
        }
        return row(forAnchorKey: key).map(Restore.row) ?? .gone
    }

    /// What bringing a kept place back does with these rows
    /// (`restorePlacement`).
    enum RestorePlacement: Equatable {
        /// Put `row` `offset` points below the top of the diff.
        case put(row: Int, offset: CGFloat)
        /// Wait for the file to be read, and have it read where it lies.
        case wait(fileID: String)
        /// Move nothing: the composer, kept in sight, is what is selected.
        case none
    }

    /// Where a place kept for the stacked diff goes: the line,
    /// as far from the top as it was, whichever file is open now. The open
    /// file follows the reader's scroll only when they stop on a file it can
    /// open, so it says nothing about how far down they read, and a place
    /// is put back as it was. A line whose file is not read yet waits for
    /// it. A line gone gives way to the header of its own file while the
    /// file is still listed, the nearest thing to where the reader was;
    /// else to what the review has selected: the composer while it is open
    /// (`hasComposer`, kept in sight by whoever puts the place back), else
    /// the open file's header.
    func restorePlacement(of anchor: ReviewScrollAnchor, openFileID: String?, hasComposer: Bool) -> RestorePlacement {
        switch restore(forAnchorKey: anchor.key) {
        case let .row(row):
            return .put(row: row, offset: anchor.offset)
        case let .waiting(fileID):
            return .wait(fileID: fileID)
        case .gone:
            if let header = Self.anchorFileID(anchor.key).flatMap(headerRow(of:)) {
                return .put(row: header, offset: 0)
            }
            if !hasComposer, let header = openFileID.flatMap(headerRow(of:)) {
                return .put(row: header, offset: 0)
            }
            return .none
        }
    }

    /// The file an anchor key names (`anchorKey(atRow:)`).
    private static func anchorFileID(_ key: String) -> String? {
        let parts = key.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        switch parts.first {
        case "h": return String(key.dropFirst(2))
        case "l": return parts.count == 4 ? String(parts[3]) : nil
        default: return nil
        }
    }

    fileprivate mutating func append(_ header: ReviewStackHeader, piece: ReviewStackPiece?, section: SectionFacts) {
        let headerRow = rows.count
        rows.append(ReviewRow(id: 0, kind: .file(header)))
        if let piece {
            rows.append(contentsOf: piece.rows)
            if !piece.hunkHeaders.isEmpty {
                hunkHeaders[header.file.id] = piece.hunkHeaders
            }
            commentableHunks.formUnion(piece.commentableHunks)
        }
        sectionByFile[header.file.id] = sections.count
        if section.idOffset != 0 {
            sectionBySlot[section.slot] = sections.count
        }
        sections.append(ReviewStackSection(
            file: header.file,
            headerRow: headerRow,
            endRow: rows.count,
            idOffset: section.idOffset,
            fingerprint: section.fingerprint,
            isSettled: section.isSettled
        ))
    }

    /// What a section is besides its rows.
    fileprivate struct SectionFacts {
        let idOffset: Int
        let slot: Int
        let fingerprint: String?
        var isSettled = true
    }

    fileprivate mutating func setOpenHighlights(_ highlights: ReviewIntralineHighlights) {
        intralineHighlights.rangesByLineID = highlights.rangesByLineID
    }

    fileprivate mutating func setHighlights(_ highlights: ReviewIntralineHighlights, slot: Int) {
        guard !highlights.rangesByLineID.isEmpty else { return }
        intralineHighlights.bands[slot] = highlights.rangesByLineID
    }

    fileprivate mutating func merge(counts: [Int: Int], offset: Int) {
        for (id, count) in counts {
            commentCounts[id + offset] = count
        }
    }
}

/// Builds the stacked rows from the files, the open file's rows, and what
/// has been read of the others.
enum ReviewStackBuilder {
    struct Input {
        /// The files in reading order: the list's order, less what it hides.
        var files: [ReviewFile]
        /// Every listed file's place in the change list, which numbers its
        /// ids: unlike the reading order, it does not move when the list is
        /// shown as a tree or hides what has been read.
        var slots: [String: Int]
        var stats: [String: ReviewFileStat] = [:]
        var viewed: Set<String> = []
        /// Files drawn whole though checked (`unfolded`): their headers
        /// still say they are checked. Drawn whole, a checked file is laid
        /// out, searched, and commented on like an unchecked one.
        var unfolded: Set<String> = []
        var marks: [String: [ReviewFileMark]] = [:]
        /// The conversations whose turns changed each file, by file id
        /// (`ReviewStackHeader.tags`).
        var tags: [String: [ReviewFileTag]] = [:]
        /// The range's turns whose files could not be read, the same for
        /// every header (`ReviewStackHeader.unreadableTags`).
        var unreadableTags: [ReviewFileTag] = []
        /// The open file, with the rows `ReviewRowBuilder` built for it (the
        /// composer, unfolded context, and its comments), and its markers.
        var open: ReviewDiff?
        var openRows: [ReviewRow] = []
        var openCounts: [Int: Int] = [:]
        /// The other files' diffs, as far as they have been read.
        var entries: [String: ReviewStackEntry] = [:]
        /// Entries read before the list last changed, which are drawn until
        /// they are read again.
        var stale: Set<String> = []
    }

    /// The rows a file that is not open draws, from its diff, with its ids
    /// already moved by the offset given (`ReviewStackPiece.closed`).
    typealias ClosedRows = (ReviewFile, ReviewDiff, Int) -> ReviewStackPiece
    /// The comment markers of a file that is not open, by its own ids
    /// (`ReviewStackPiece.closedCounts`).
    typealias ClosedCounts = (ReviewFile, ReviewDiff) -> [Int: Int]

    /// The files drawn whole though checked: the open file while its
    /// composer is open. The check is shared by every review of the
    /// worktree, and another window can check the file under a comment
    /// being written; folded, the comment would hold the tab unseen. Tied
    /// to the composer being open, not to its text, so typing (an input
    /// method's unfinished text included) never folds the file mid-edit.
    ///
    /// With them, the checked files the reader opened again by hand
    /// (`ReviewStackOpenedFiles`).
    static func unfolded(openFileID: String?, isComposerOpen: Bool, opened: Set<String> = []) -> Set<String> {
        guard isComposerOpen, let openFileID else { return opened }
        return opened.union([openFileID])
    }

    static func build(_ input: Input, closedRows: ClosedRows, closedCounts: ClosedCounts = { _, _ in [:] }) -> ReviewStack {
        var stack = ReviewStack()
        for (position, file) in input.files.enumerated() {
            // Past every listed slot, and a different one for each file the
            // list did not number, so no two files share a band of ids.
            let slot = input.slots[file.id] ?? input.slots.count + position
            let isViewed = input.viewed.contains(file.id)
            let isFolded = isViewed && !input.unfolded.contains(file.id)
            if let open = input.open, open.file.id == file.id {
                if !isFolded {
                    stack.setOpenHighlights(open.intralineHighlights)
                    stack.merge(counts: input.openCounts, offset: 0)
                }
                stack.append(
                    header(file, input, isViewed: isViewed, isFolded: isFolded, isVanished: open.hasVanished),
                    piece: isFolded ? nil : ReviewStackPiece(
                        rows: input.openRows,
                        commentableHunks: ReviewHunkRun.commentableHeaders(in: open.lines)
                    ),
                    section: .init(idOffset: 0, slot: slot, fingerprint: open.fingerprint)
                )
                continue
            }
            let offset = ReviewStackIDs.offset(forSlot: slot)
            let entry = input.entries[file.id]
            var piece: ReviewStackPiece?
            var fingerprint: String?
            var isVanished = false
            switch entry {
            case let .loaded(diff):
                isVanished = diff.hasVanished
                fingerprint = diff.fingerprint
                if !isFolded {
                    piece = closedRows(file, diff, offset)
                    stack.setHighlights(diff.intralineHighlights, slot: slot)
                    stack.merge(counts: closedCounts(file, diff), offset: offset)
                }
            case let .failed(notice):
                piece = ReviewStackPiece(rows: [ReviewRow(id: 0, kind: .notice(notice))])
            case nil:
                piece = ReviewStackPiece(rows: [ReviewRow(id: 0, kind: .notice("Loading changes…"))])
            }
            stack.append(
                header(file, input, isViewed: isViewed, isFolded: isFolded, isVanished: isVanished),
                piece: isFolded ? nil : piece,
                section: .init(idOffset: offset, slot: slot, fingerprint: fingerprint, isSettled: entry != nil || isFolded)
            )
        }
        return stack
    }

    private static func header(
        _ file: ReviewFile,
        _ input: Input,
        isViewed: Bool,
        isFolded: Bool,
        isVanished: Bool
    ) -> ReviewStackHeader {
        ReviewStackHeader(
            file: file,
            stat: isVanished ? nil : input.stats[file.id],
            marks: input.marks[file.id] ?? [],
            tags: input.tags[file.id] ?? [],
            unreadableTags: input.unreadableTags,
            isViewed: isViewed,
            isFolded: isFolded
        )
    }
}

/// The checked files the reader opened again from their headers.
/// Checking a file folds it; the reader can still open it to read it again,
/// and fold it once more. Each is kept with the check it was opened under,
/// so a fresh check folds the file whoever made it: one unchecked and
/// checked again, here or in another window, carries a new mark
/// (`ReviewViewMark.markedAt`) and leaves the opening behind. Kept with the
/// review tab (`ReviewTabViewState`), not with the marks: which files are
/// open is how this tab is being read, not how far the reader has got.
struct ReviewStackOpenedFiles: Equatable {
    /// The files opened, by the mark each was checked with as it was.
    private var marks: [String: ReviewViewMark] = [:]

    /// The checked files drawn whole: those still under the check they
    /// were opened under.
    func ids(viewed: [String: ReviewViewMark]) -> Set<String> {
        Set(marks.compactMap { id, mark in viewed[id] == mark ? id : nil })
    }

    /// Opens a folded checked file, or folds one drawn whole, by what its
    /// header shows rather than by what is kept here: a file held open for
    /// the comment being written in it (`ReviewStackBuilder.unfolded`) and
    /// folded from its chevron folds once the comment is closed, rather
    /// than staying open for a click that said to fold it. An unchecked
    /// file is never folded and has nothing to toggle.
    mutating func toggle(_ id: String, isFolded: Bool, viewed: [String: ReviewViewMark]) {
        if isFolded, let mark = viewed[id] {
            marks[id] = mark
        } else {
            marks.removeValue(forKey: id)
        }
    }

    /// Lets go of the openings no check stands under any more, so they do
    /// not pile up over a long review.
    mutating func prune(viewed: [String: ReviewViewMark]) {
        marks = marks.filter { id, mark in viewed[id] == mark }
    }
}

/// How far the reader has got through the files: "2 / 5 Viewed".
struct ReviewReadingProgress: Equatable {
    let viewed: Int
    let total: Int

    /// Counted over the files listed, so a mark left on a file that has
    /// since left the list counts for nothing.
    init(fileIDs: [String], viewed marks: Set<String>) {
        total = fileIDs.count
        viewed = fileIDs.count { marks.contains($0) }
    }
}
