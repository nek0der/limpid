// ReviewExpansion.swift
// Limpid — the unchanged lines a unified diff leaves out, unfolded on demand.

import Foundation

/// What the reader asked of one gap. `all` is the whole gap at once, for the
/// reader who wants the file rather than another twenty lines of it, and
/// `collapse` puts it back — without which a gap opened all the way could only
/// be closed by leaving the file.
enum ReviewGapAction {
    /// Toward the hunk below the gap, from the bottom up.
    case up
    /// Away from the hunk above the gap, from the top down.
    case down
    case all
    case collapse
}

/// How much of one gap has been unfolded, from each end.
///
/// Two counts rather than one range because a gap opens from both ends: from
/// the hunk above it downward, and from the hunk below it upward. They meet in
/// the middle, and once they do the gap is gone.
struct ReviewGapSpan: Equatable {
    var above = 0
    var below = 0
}

/// One gap's place in the file, read off the patch.
struct ReviewGap: Equatable {
    let index: Int
    /// The hunk this gap sits above, or `nil` for the run after the last hunk.
    let nextHunkID: Int?
    /// The new-side line numbers this gap covers.
    let range: ClosedRange<Int>
    /// What to add to a new-side number to get the old-side one. Constant
    /// across a gap: nothing changed in it, so both sides advance together.
    let delta: Int
}

/// The control drawn where a gap is, and what it can still offer.
struct ReviewExpander: Equatable {
    let gap: Int
    /// The line this control is drawn above, or `nil` for the end of the file.
    let beforeLineID: Int?
    let hidden: Int
    let canExpandUp: Bool
    let canExpandDown: Bool
    /// Whether anything is unfolded here to put back.
    let canCollapse: Bool
}

enum ReviewExpansionPlan {
    /// How many lines one press unfolds. Twenty is about a screen of context
    /// at the sizes this surface draws, and small enough that a reader who
    /// wanted the whole file reaches for the third button instead.
    static let step = 20

    /// Expanded lines are numbered outside the patch's own range so that a
    /// stored comment's row id can never land on one. The patch is capped at
    /// 100,000 rows, and a file's line count is bounded by the diff size cap,
    /// so nothing legitimate reaches this.
    static let idBase = 1 << 40

    /// The gaps in a patch, in file order.
    ///
    /// `sourceCount` is the new side's line count, which only the run after the
    /// last hunk needs; without it that run is not offered, because its length
    /// is the one thing the patch does not say.
    /// `sourceCount` is `nil` when the file's contents could not be read. There
    /// is nothing to unfold then, and offering it drew an Expand control that
    /// named a number of hidden lines and did nothing when pressed.
    static func gaps(in lines: [ReviewLine], sourceCount: Int?) -> [ReviewGap] {
        guard sourceCount != nil else { return [] }
        var result: [ReviewGap] = []
        var previousEnd: (old: Int, new: Int)?
        for line in lines where line.kind == .hunk {
            guard let header = header(line.text) else { continue }
            let start = previousEnd.map { $0.new + 1 } ?? 1
            if header.newStart > start {
                result.append(ReviewGap(
                    index: result.count,
                    nextHunkID: line.id,
                    range: start...(header.newStart - 1),
                    delta: header.oldStart - header.newStart
                ))
            }
            previousEnd = (
                old: header.oldStart + header.oldCount - 1,
                new: header.newStart + header.newCount - 1
            )
        }
        guard let previousEnd, let sourceCount, sourceCount > previousEnd.new else { return result }
        result.append(ReviewGap(
            index: result.count,
            nextHunkID: nil,
            range: (previousEnd.new + 1)...sourceCount,
            delta: previousEnd.old - previousEnd.new
        ))
        return result
    }

    /// The patch with the unfolded lines put back into it, and the controls
    /// for what is still folded.
    ///
    /// Returns lines rather than rows so both layouts can use it: the split
    /// view pairs the merged list the same way it pairs the patch, because
    /// expanded lines are context and context pairs with itself.
    static func apply(
        to lines: [ReviewLine],
        gaps: [ReviewGap],
        spans: [Int: ReviewGapSpan],
        source: [String]
    ) -> (lines: [ReviewLine], expanders: [ReviewExpander]) {
        guard !gaps.isEmpty else { return (lines, []) }
        var merged: [ReviewLine] = []
        var expanders: [ReviewExpander] = []
        var byHunk: [Int: ReviewGap] = [:]
        var trailing: ReviewGap?
        for gap in gaps {
            if let id = gap.nextHunkID {
                byHunk[id] = gap
            } else {
                trailing = gap
            }
        }
        func unfold(_ gap: ReviewGap) {
            let span = spans[gap.index] ?? ReviewGapSpan()
            let total = gap.range.count
            // Clamped together: the two ends are asked for independently and
            // would otherwise overlap in the middle and draw a line twice.
            let below = min(span.below, total)
            let above = min(span.above, total - below)
            let hidden = total - below - above
            let shown = below + above
            // With nothing left folded the control moves to the head of what
            // was unfolded, ahead of the first line it revealed: left where it
            // sits while folding, it would be a whole file's scroll away from
            // the reader who opened the file from the top of it.
            if hidden == 0, shown > 0 {
                expanders.append(control(
                    gap,
                    hidden: 0,
                    canCollapse: true,
                    before: idBase + gap.range.lowerBound
                ))
            }
            for number in gap.range.prefix(below) {
                merged.append(line(number, in: gap, source: source))
            }
            if hidden > 0 {
                // Ahead of what the upward end revealed, not ahead of the
                // hunk. What is still folded lies between the two ends, and a
                // control placed past the revealed lines pointed at a gap that
                // is no longer there — it read as lines hidden between two
                // that are next to each other.
                expanders.append(control(
                    gap,
                    hidden: hidden,
                    canCollapse: shown > 0,
                    before: above > 0 ? idBase + (gap.range.upperBound - above + 1) : nil
                ))
            }
            for number in gap.range.suffix(above) {
                merged.append(line(number, in: gap, source: source))
            }
        }
        for entry in lines {
            if entry.kind == .hunk, let gap = byHunk[entry.id] {
                unfold(gap)
            }
            merged.append(entry)
        }
        if let trailing {
            unfold(trailing)
        }
        return (merged, expanders)
    }

    private static func control(
        _ gap: ReviewGap,
        hidden: Int,
        canCollapse: Bool,
        before: Int? = nil
    ) -> ReviewExpander {
        ReviewExpander(
            gap: gap.index,
            beforeLineID: before ?? gap.nextHunkID,
            hidden: hidden,
            canExpandUp: gap.nextHunkID != nil,
            // A gap that starts at line 1 has no hunk above it to open away
            // from. Read off the range rather than the index: a file whose
            // first hunk starts at line 1 has no leading gap, so gap zero is
            // already between two hunks.
            canExpandDown: gap.range.lowerBound > 1,
            canCollapse: canCollapse
        )
    }

    /// A line read out of the file, numbered on both sides. Out of range means
    /// the file shrank under a plan built against an older read; a placeholder
    /// keeps the numbering intact rather than shifting everything below it.
    private static func line(_ number: Int, in gap: ReviewGap, source: [String]) -> ReviewLine {
        ReviewLine(
            id: idBase + number,
            kind: .context,
            text: source.indices.contains(number - 1) ? source[number - 1] : "",
            oldLine: number + gap.delta,
            newLine: number,
            isExpansion: true
        )
    }

    /// `@@ -a,b +c,d @@`, with either count omitted meaning one line.
    ///
    /// Read here rather than kept from the parse: the numbers are only needed
    /// where a reader asks for more of the file, and carrying four more fields
    /// on every line of every diff to save this is the wrong trade.
    static func header(_ text: String) -> Header? {
        let fields = text.split(separator: " ")
        guard fields.count >= 3, fields[0] == "@@" else { return nil }
        guard let old = pair(fields[1], sign: "-"), let new = pair(fields[2], sign: "+") else { return nil }
        return Header(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    /// Where one hunk sits on each side, which is all a gap needs to place
    /// itself and to number the lines it holds.
    struct Header: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    private static func pair(_ field: Substring, sign: Character) -> (start: Int, count: Int)? {
        guard field.first == sign else { return nil }
        let numbers = field.dropFirst().split(separator: ",")
        guard let start = Int(numbers.first ?? ""), start >= 0 else { return nil }
        guard numbers.count > 1 else { return (start, 1) }
        guard let count = Int(numbers[1]), count >= 0 else { return nil }
        return (start, count)
    }
}
