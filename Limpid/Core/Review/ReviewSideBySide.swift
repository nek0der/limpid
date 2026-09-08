// ReviewSideBySide.swift
// Limpid — pairing a unified diff into a left and a right column.

import Foundation

/// Which column of a side-by-side row a line, a selection or a comment belongs
/// to. `nil` wherever the answer is "both": a comment written in the unified
/// layout covers whatever the run covered, and says so.
extension ReviewSide {
    /// Whether a comment taken in this column covers that line.
    ///
    /// The one predicate. The run's side, the composer's anchor and the dots in
    /// the gutter each used to decide it for themselves, and they disagreed
    /// about the ends of a run that crosses a change block. `nil` is the
    /// unified layout, where a run covers both kinds of line and only
    /// commentability applies.
    static func covers(_ line: ReviewLine, on side: ReviewSide?) -> Bool {
        guard line.isCommentable else { return false }
        guard let side else { return true }
        return side.position(of: line) != nil
    }
}

enum ReviewSide: String, Codable, Equatable, CaseIterable {
    case old
    case new

    /// The position this side gives a line, or `nil` when the line does not
    /// appear in this column. A side's visible run is the unified order
    /// restricted to the lines that answer this, which is what lets a
    /// selection stay a contiguous id range even when it covers one column.
    func position(of line: ReviewLine) -> Int? {
        switch self {
        case .old: line.oldLine
        case .new: line.newLine
        }
    }

    /// The column a line is read in when the reader has not chosen one: the
    /// new file wherever it has the line, since that is the state under
    /// review. `nil` for a line that appears in neither — a hunk header, the
    /// no-newline marker.
    static func covering(_ line: ReviewLine) -> ReviewSide? {
        if line.newLine != nil {
            return .new
        }
        if line.oldLine != nil {
            return .old
        }
        return nil
    }

    var other: ReviewSide {
        switch self {
        case .old: .new
        case .new: .old
        }
    }
}

/// How the diff is laid out. Unified is one column of `+` / `-` lines in file
/// order; side by side puts the old file on the left and the new one on the
/// right, with a placeholder wherever one side has no counterpart.
enum ReviewDiffLayout: String, Equatable, CaseIterable {
    case unified
    case sideBySide
}

/// One rendered row of the split layout. A `nil` cell is the placeholder: the
/// other column changed more lines than this one did.
///
/// The cells hold the parsed `ReviewLine` itself rather than a synthesized
/// copy. Comments and selections are anchored by `ReviewLine.id`, and an id
/// minted for a pair would not survive back into the unified layout.
struct ReviewSplitPair: Equatable {
    let old: ReviewLine?
    let new: ReviewLine?

    func line(on side: ReviewSide) -> ReviewLine? {
        switch side {
        case .old: old
        case .new: new
        }
    }

    func contains(lineID: Int) -> Bool {
        old?.id == lineID || new?.id == lineID
    }

    var isSelectable: Bool {
        old?.isCommentable == true || new?.isCommentable == true
    }
}

/// A row of the split layout before comments and the composer are interleaved.
enum ReviewSplitElement: Equatable {
    case hunk(ReviewLine)
    case pair(ReviewSplitPair)

    /// The parsed lines this row draws, in reading order. A context line is one
    /// line shown twice, so it appears once: anything keyed by `ReviewLine.id`
    /// — a comment, the composer — would otherwise be attached to the row
    /// twice.
    var lines: [ReviewLine] {
        switch self {
        case let .hunk(line):
            [line]
        case let .pair(pair):
            switch (pair.old, pair.new) {
            case let (old?, new?): old.id == new.id ? [old] : [old, new]
            case let (old?, nil): [old]
            case let (nil, new?): [new]
            case (nil, nil): []
            }
        }
    }
}

/// Turns the parsed unified diff into left/right rows.
///
/// Git's unified format says nothing about which removed line a given added
/// line replaced, so within a block of changes we pair by position: the first
/// removed line faces the first added one, and the longer side runs on against
/// placeholders. Similarity matching would guess better on a reordered block
/// and worse on short or reformatted lines, and it would make the pairing —
/// which comments are anchored through — depend on the text rather than the
/// diff.
enum ReviewSideBySideBuilder {
    /// One column of a change block being collected.
    private struct Column {
        private(set) var lines: [ReviewLine] = []
        /// Markers keyed by the index of the line they annotate.
        /// `\ No newline at end of file` is not a line of the file — it is a
        /// note about the line above it — so pairing it as a line of its own
        /// put it opposite unrelated code.
        private(set) var markers: [Int: ReviewLine] = [:]

        mutating func append(_ line: ReviewLine) {
            lines.append(line)
        }

        /// Attaches a marker to the last line collected. Fails when there is
        /// none, which the caller resolves by drawing the marker on both
        /// sides.
        mutating func annotate(_ marker: ReviewLine) -> Bool {
            guard !lines.isEmpty else { return false }
            markers[lines.count - 1] = marker
            return true
        }

        mutating func removeAll() {
            lines.removeAll()
            markers.removeAll()
        }
    }

    /// What the last emitted row was, so a marker can be attached to it.
    private enum Anchor {
        case start
        case context
        case side(ReviewSide)
    }

    static func elements(for lines: [ReviewLine]) -> [ReviewSplitElement] {
        var elements: [ReviewSplitElement] = []
        var old = Column()
        var new = Column()
        var anchor = Anchor.start

        func flush() {
            defer {
                old.removeAll()
                new.removeAll()
            }
            let count = max(old.lines.count, new.lines.count)
            guard count > 0 else { return }
            for index in 0..<count {
                elements.append(.pair(ReviewSplitPair(
                    old: index < old.lines.count ? old.lines[index] : nil,
                    new: index < new.lines.count ? new.lines[index] : nil
                )))
                let oldMarker = old.markers[index]
                let newMarker = new.markers[index]
                guard oldMarker != nil || newMarker != nil else { continue }
                elements.append(.pair(ReviewSplitPair(old: oldMarker, new: newMarker)))
            }
        }

        for line in lines {
            switch line.kind {
            case .fileHeader:
                continue
            case .hunk:
                flush()
                elements.append(.hunk(line))
                anchor = .start
            case .context:
                flush()
                elements.append(.pair(ReviewSplitPair(old: line, new: line)))
                anchor = .context
            case .removed:
                old.append(line)
                anchor = .side(.old)
            case .added:
                new.append(line)
                anchor = .side(.new)
            case .marker:
                switch anchor {
                case .side(.old) where old.annotate(line):
                    continue
                case .side(.new) where new.annotate(line):
                    continue
                default:
                    // Either the marker follows a context line, where it
                    // describes both sides, or the diff put one somewhere we
                    // cannot attach it. Both read correctly as a full-width row.
                    flush()
                    elements.append(.pair(ReviewSplitPair(old: line, new: line)))
                }
            }
        }
        flush()
        return elements
    }
}
