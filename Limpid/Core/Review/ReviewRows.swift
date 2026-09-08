// ReviewRows.swift
// Limpid — the rendered row list, which is no longer the parsed diff itself.

import Foundation

/// One rendered row. The table shows more than diff lines: a hunk header
/// separates the blocks, comments sit under the line they were written on, an
/// expander stands in for what is folded, and the composer opens in place. The
/// file's own name is drawn in a fixed bar above the scroll rather than as a
/// row. Git's file metadata (`diff --git`, `index`, `---`, `+++`) contributes
/// nothing a reader needs and is dropped here.
struct ReviewRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case notice(String)
        case hunk(ReviewLine)
        case code(ReviewLine)
        /// One row of the side-by-side layout: the old file on the left, the
        /// new one on the right, either of them a placeholder.
        case splitCode(ReviewSplitPair)
        case comment(ReviewComment)
        case composer(ReviewLine)
        /// The control standing in for the lines a unified diff left out.
        case expander(ReviewExpander)
    }

    /// Position in the built list. The table addresses rows by index, and
    /// `ReviewLine.id` no longer matches that index once headers are dropped
    /// and comments are interleaved.
    let id: Int
    let kind: Kind

    /// The one line this row is about. A split row carries two, and answering
    /// with either of them anchored comments and the cursor on a line the
    /// reader was not looking at — it says `nil`, and callers that can handle
    /// both sides ask `line(on:)`.
    var line: ReviewLine? {
        switch kind {
        case let .code(line), let .composer(line): line
        case .notice, .hunk, .comment, .splitCode, .expander: nil
        }
    }

    func line(on side: ReviewSide) -> ReviewLine? {
        switch kind {
        case let .code(line), let .composer(line): line
        case let .splitCode(pair): pair.line(on: side)
        case .notice, .hunk, .comment, .expander: nil
        }
    }

    /// The code this row draws, for measuring how far the columns can scroll.
    /// A split row carries two lines, and measuring only one of them stopped
    /// the scroll short of the longer column.
    var texts: [String] {
        switch kind {
        case let .code(line), let .composer(line):
            [line.text]
        case let .splitCode(pair):
            [pair.old?.text, pair.new?.text].compactMap(\.self)
        case .notice, .hunk, .comment, .expander:
            []
        }
    }

    /// The line this row can be found again by after the list is rebuilt.
    ///
    /// Used to hold the reader's place: unfolding a gap inserts rows above
    /// what is on screen, and without an anchor the code they were reading
    /// slides down the viewport by however much they asked for. A comment has
    /// no line of its own to answer with, and a control moves with the fold it
    /// belongs to, so neither is an anchor.
    var anchorLine: ReviewLine? {
        switch kind {
        case let .code(line), let .hunk(line), let .composer(line): line
        case let .splitCode(pair): pair.new ?? pair.old
        case .notice, .comment, .expander: nil
        }
    }

    func contains(lineID: Int) -> Bool {
        switch kind {
        case let .code(line), let .composer(line), let .hunk(line): line.id == lineID
        case let .splitCode(pair): pair.contains(lineID: lineID)
        case .notice, .comment, .expander: false
        }
    }

    /// The line the cursor lands on when it reaches this row from `side`, or
    /// `nil` when that column has nothing to comment on here. One accessor for
    /// both layouts: the cursor, the selection and hunk navigation all ask it,
    /// and having each of them unwrap `kind` was how the two layouts drifted.
    func commentableLineID(on side: ReviewSide?) -> Int? {
        switch kind {
        case let .code(line):
            line.isCommentable ? line.id : nil
        case let .splitCode(pair):
            if let side {
                pair.line(on: side).flatMap { $0.isCommentable ? $0.id : nil }
            } else {
                pair.old.flatMap { $0.isCommentable ? $0.id : nil }
                    ?? pair.new.flatMap { $0.isCommentable ? $0.id : nil }
            }
        case .notice, .hunk, .comment, .composer, .expander:
            nil
        }
    }

    var isSelectable: Bool {
        switch kind {
        case let .code(line): line.isCommentable
        case let .splitCode(pair): pair.isSelectable
        case .notice, .hunk, .comment, .composer, .expander: false
        }
    }
}

/// The composer is either adding a comment to a line or rewriting an existing
/// one. Holding those as two independent optionals let an abandoned edit
/// survive into the next add, which then silently overwrote the edited comment
/// with text meant for a different line.
struct ReviewComposerState: Equatable {
    /// First line of the run being commented on.
    private(set) var startLineID: Int?
    /// Last line of the run, and where the composer is drawn.
    private(set) var lineID: Int?
    /// The column the run was selected in, carried through to the comment so
    /// the quoted code and the line numbers are the ones the reader saw.
    private(set) var side: ReviewSide?
    private(set) var editingCommentID: UUID?
    var text = ""

    var isOpen: Bool {
        lineID != nil
    }

    mutating func compose(start: Int, end: Int, side: ReviewSide?) {
        startLineID = min(start, end)
        lineID = max(start, end)
        self.side = side
        editingCommentID = nil
        text = ""
    }

    mutating func edit(_ comment: ReviewComment) {
        startLineID = comment.lineID
        lineID = comment.lastLineID
        side = comment.side
        editingCommentID = comment.id
        text = comment.body
    }

    /// Follow a selection the user is still extending. Keeps the text, and
    /// refuses to move an edit: an existing comment's run is its own.
    mutating func retarget(start: Int, end: Int, side: ReviewSide?) {
        guard isOpen, editingCommentID == nil else { return }
        startLineID = min(start, end)
        lineID = max(start, end)
        self.side = side
    }

    mutating func cancel() {
        startLineID = nil
        lineID = nil
        side = nil
        editingCommentID = nil
        text = ""
    }
}

/// The run of lines a comment will cover.
///
/// Held as the line the selection started on and the line it currently
/// reaches, so extending upward and downward are the same operation; readers
/// of the selection take the normalized range.
struct ReviewSelection: Equatable {
    private(set) var anchorLineID: Int?
    private(set) var headLineID: Int?
    /// The column the run was started in. `nil` in the unified layout, where a
    /// row shows one line and there is no other column to leave out.
    private(set) var side: ReviewSide?

    var isEmpty: Bool {
        headLineID == nil
    }

    var startLineID: Int? {
        guard let anchor = anchorLineID, let head = headLineID else { return headLineID }
        return min(anchor, head)
    }

    var endLineID: Int? {
        guard let anchor = anchorLineID, let head = headLineID else { return headLineID }
        return max(anchor, head)
    }

    func contains(_ lineID: Int) -> Bool {
        guard let start = startLineID, let end = endLineID else { return false }
        return (start...end).contains(lineID)
    }

    /// Whether the run covers this line as the given column draws it.
    ///
    /// A run started in one column only ever covers what that column shows,
    /// and a column shows exactly the lines that have a position on its side.
    /// That is why the run stays a contiguous id range even in the split
    /// layout: filtering the range by side reproduces the visible run.
    func contains(_ lineID: Int, on side: ReviewSide?) -> Bool {
        guard contains(lineID) else { return false }
        guard let runSide = self.side, let side else { return true }
        return runSide == side
    }

    /// Move to one line, dropping any run.
    mutating func select(_ lineID: Int?, on side: ReviewSide? = nil) {
        anchorLineID = lineID
        headLineID = lineID
        self.side = lineID == nil ? nil : side
    }

    /// Follow a layout change. The run itself does not move — the same lines
    /// stay covered, drawn wherever the new layout draws them — but a run
    /// belongs to one column in the split layout and to neither in the
    /// unified one.
    mutating func follow(_ layout: ReviewDiffLayout, head: ReviewLine?, lines: [ReviewLine] = []) {
        switch layout {
        case .unified:
            side = nil
        case .sideBySide:
            guard side == nil, let head else { return }
            let column = ReviewSide.covering(head)
            side = column
            // And narrow the run to what that column draws. A run taken in the
            // unified layout can cover a removed line and an added one; one
            // column shows only half of it, so leaving both ends standing left
            // the highlight, the marker and the saved comment answering to
            // different lines.
            guard let start = startLineID, let end = endLineID else { return }
            let covered = lines
                .filter { $0.id >= start && $0.id <= end && ReviewSide.covers($0, on: column) }
                .map(\.id)
            guard let low = covered.min(), let high = covered.max() else {
                anchorLineID = head.id
                headLineID = head.id
                return
            }
            // The end the reader was moving stays the head, so extending the
            // run keeps going the way it was going.
            let isHeadHigh = (headLineID ?? high) >= (anchorLineID ?? low)
            anchorLineID = isHeadHigh ? low : high
            headLineID = isHeadHigh ? high : low
        }
    }

    /// Keep the anchor where it is and move the far end.
    mutating func extend(to lineID: Int) {
        if anchorLineID == nil {
            anchorLineID = lineID
        }
        headLineID = lineID
    }
}

enum ReviewRowBuilder {
    /// What a diff line becomes, or nothing for Git's own file metadata, which
    /// says nothing a reader of the change needs.
    private static func kind(for line: ReviewLine) -> ReviewRow.Kind? {
        switch line.kind {
        case .fileHeader: nil
        case .hunk: .hunk(line)
        case .context, .added, .removed, .marker: .code(line)
        }
    }

    /// The controls split by where they are drawn: above a hunk, or after
    /// everything.
    private static func placement(
        of expanders: [ReviewExpander]
    ) -> (byLine: [Int: ReviewExpander], trailing: ReviewExpander?) {
        var byLine: [Int: ReviewExpander] = [:]
        var trailing: ReviewExpander?
        for expander in expanders {
            if let id = expander.beforeLineID {
                byLine[id] = expander
            } else {
                trailing = expander
            }
        }
        return (byLine, trailing)
    }

    /// The scroll carries one file: its header, then its diff. Listing the
    /// other changed files here as collapsed headers only repeated the rail,
    /// which already names them and carries their size and comment count. It
    /// would earn its place only if those files expanded in the same scroll,
    /// and expanding them would make `ReviewLine.id` ambiguous across the
    /// snapshots comments are written against.
    static func rows(
        expanded: ReviewDiff?,
        comments: [ReviewComment],
        composerLineID: Int?,
        editingCommentID: UUID? = nil,
        staleCommentIDs: Set<UUID> = [],
        layout: ReviewDiffLayout = .unified,
        source: [String] = [],
        gapSpans: [Int: ReviewGapSpan] = [:]
    ) -> [ReviewRow] {
        var rows: [ReviewRow] = []
        func append(_ kind: ReviewRow.Kind) {
            rows.append(ReviewRow(id: rows.count, kind: kind))
        }
        guard let expanded else { return rows }
        // A comment on a run belongs under its last line: that is where the
        // reader's eye is once they have read the block it is about.
        let byLine = Dictionary(grouping: comments) { $0.lastLineID }
        let unfolded = ReviewExpansionPlan.apply(
            to: expanded.lines,
            gaps: ReviewExpansionPlan.gaps(in: expanded.lines, sourceCount: source.isEmpty ? nil : source.count),
            spans: gapSpans,
            source: source
        )
        // Keyed by the line each control is drawn above, so both layouts can
        // place them without walking the list a second time.
        let placed = placement(of: unfolded.expanders)
        let expanders = placed.byLine
        let trailingExpander = placed.trailing
        if let notice = expanded.notice {
            append(.notice(notice))
        }
        /// Comments and the composer belong under the row that draws the line
        /// they end on, which is the one thing the two layouts have to agree on:
        /// a comment written in one has to come back in the same place in the
        /// other.
        func attach(_ line: ReviewLine) {
            for comment in byLine[line.id] ?? [] where comment.file.id == expanded.file.id {
                // The composer below is showing this comment's text; drawing
                // the saved card as well read as two copies of one comment.
                guard comment.id != editingCommentID else { continue }
                // A comment written against a diff that has since changed is
                // not about the line that now carries its row id. Drawing it
                // there claimed a connection that no longer exists; it is
                // listed with the others instead, marked, to redo or delete.
                guard !staleCommentIDs.contains(comment.id) else { continue }
                append(.comment(comment))
            }
            if composerLineID == line.id, line.isCommentable {
                append(.composer(line))
            }
        }
        switch layout {
        case .unified:
            for line in unfolded.lines {
                if let expander = expanders[line.id] {
                    append(.expander(expander))
                }
                guard let kind = kind(for: line) else { continue }
                append(kind)
                attach(line)
            }
        case .sideBySide:
            for element in ReviewSideBySideBuilder.elements(for: unfolded.lines) {
                // Read off the element rather than the hunk: the control that
                // folds a fully unfolded gap sits above the first line it
                // revealed, and in this layout that line arrives as a pair.
                if let first = element.lines.first, let expander = expanders[first.id] {
                    append(.expander(expander))
                }
                switch element {
                case let .hunk(line):
                    append(.hunk(line))
                case let .pair(pair):
                    append(.splitCode(pair))
                }
                for line in element.lines {
                    attach(line)
                }
            }
        }
        if let trailingExpander {
            append(.expander(trailingExpander))
        }
        return rows
    }

    /// Comment counts keyed by `ReviewLine.id` for the expanded file, used by
    /// the gutter so a reader scrolling the diff can see which lines already
    /// carry feedback.
    static func lineCommentCounts(
        comments: [ReviewComment],
        fileID: String?,
        lines: [ReviewLine] = []
    ) -> [Int: Int] {
        guard let fileID else { return [:] }
        // Keyed once rather than searched per id: a run can be long, and a file
        // can carry a hundred comments. Empty means "no diff to check against",
        // which is how the pure row tests call this.
        let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return comments.reduce(into: [:]) { counts, comment in
            guard comment.file.id == fileID else { return }
            // Every line of a run carries the marker, so the block a comment
            // covers is visible while scrolling past it — but only the lines
            // the comment's own column covers. A run that crosses a change
            // block put dots on lines `ReviewStore.add` had already dropped,
            // which claimed the comment quoted code it does not.
            for lineID in comment.lineIDs {
                if let line = byID[lineID], !ReviewSide.covers(line, on: comment.side) {
                    continue
                }
                counts[lineID, default: 0] += 1
            }
        }
    }
}

/// Somewhere to keep the last row list. `ReviewRowBuilder.rows` walks the whole
/// diff, and the surface's body re-evaluates far more often than the rows
/// change — every keystroke in the composer, every tick of the destination
/// poll. A class rather than a value so reading through it from a body is not
/// a state mutation.
@MainActor
final class ReviewRowCache {
    private var rowKey: String?
    private var cachedRows: [ReviewRow] = []
    private var countKey: String?
    private var cachedCounts: [Int: Int] = [:]
    private var hitKey: String?
    private var cachedHits: [ReviewSearchHit] = []

    func rows(for key: String, build: () -> [ReviewRow]) -> [ReviewRow] {
        if key == rowKey {
            return cachedRows
        }
        cachedRows = build()
        rowKey = key
        return cachedRows
    }

    /// Same reasoning as `rows`: a hundred thousand rows are scanned for the
    /// query, and the answer only changes when the query or the rows do —
    /// not on every pass of the surface's body.
    func hits(for key: String, build: () -> [ReviewSearchHit]) -> [ReviewSearchHit] {
        if key == hitKey {
            return cachedHits
        }
        cachedHits = build()
        hitKey = key
        return cachedHits
    }

    /// Same reasoning as `rows`: the marker counts walk every line of every
    /// comment, and nothing about them changes between keystrokes.
    func counts(for key: String, build: () -> [Int: Int]) -> [Int: Int] {
        if key == countKey {
            return cachedCounts
        }
        cachedCounts = build()
        countKey = key
        return cachedCounts
    }
}

/// Whether a run may reach from one line to another.
///
/// A comment names a span, and a span is only true of lines that are
/// contiguous in the file. Two hunks sit next to each other on screen with
/// hundreds of lines between them, so a run that crossed the `@@` between them
/// would tell the agent to look at all of it. Both ways of extending a run —
/// the keyboard and the pointer — ask this.
enum ReviewRunBounds {
    /// Answered from the diff rather than from the rows: a run is bounded by
    /// the patch it was taken from, and the rows are the same lines with the
    /// cards and controls between them. Walking the rows meant two full scans
    /// of a hundred thousand of them on every press of ⇧J.
    ///
    /// An id that names no line, or a line that belongs to no hunk, is let
    /// through. Expanded context is not commentable and cannot be either end
    /// of a run, so this is the case where the ids have stopped describing the
    /// patch — and refusing there would leave the reader unable to select
    /// anything with no way to see why.
    static func canExtend(_ lines: [ReviewLine], from anchor: Int?, to candidate: Int) -> Bool {
        guard let anchor, anchor != candidate else { return true }
        guard let start = lines.first(where: { $0.id == anchor })?.hunkIndex,
              let end = lines.first(where: { $0.id == candidate })?.hunkIndex
        else { return true }
        return start == end
    }
}
