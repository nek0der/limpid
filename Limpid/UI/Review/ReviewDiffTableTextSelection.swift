// ReviewDiffTableTextSelection.swift
// Limpid — character-selection input and repainting for review rows.

import AppKit

extension ReviewDiffTable.Coordinator {
    /// Maps a code-area point to a TextKit insertion position. `anchor` is
    /// present after a drag starts and keeps a split selection in its original
    /// column even when the pointer crosses the divider.
    func textPosition(
        at point: NSPoint,
        continuingFrom anchor: ReviewTextPosition?,
        in table: ReviewTableView
    ) -> ReviewTextPosition? {
        let lookupPoint: NSPoint
        if anchor != nil, table.numberOfRows > 0 {
            let firstY = table.rect(ofRow: 0).minY
            let lastY = table.rect(ofRow: table.numberOfRows - 1).maxY - 0.5
            lookupPoint = NSPoint(
                x: min(max(point.x, table.bounds.minX), max(table.bounds.maxX - 1, table.bounds.minX)),
                y: min(max(point.y, firstY), max(lastY, firstY))
            )
        } else {
            lookupPoint = point
        }
        let hitRow = table.row(at: lookupPoint)
        guard parent.rows.indices.contains(hitRow) else { return nil }
        let requestedSide = parent.layout == .sideBySide
            ? (anchor?.side ?? (point.x < ReviewRowMetrics.sideWidth(in: table.bounds.width) ? .old : .new))
            : nil
        let row = anchor.flatMap {
            nearestTextRow(from: hitRow, toward: $0.rowIndex, on: requestedSide)
        } ?? hitRow
        let line: ReviewLine
        let side: ReviewSide?
        let textOrigin: CGFloat
        let hitX: CGFloat
        switch parent.rows[row].kind {
        case let .code(value):
            guard anchor?.side == nil, value.isTextSelectable else { return nil }
            line = value
            side = nil
            textOrigin = ReviewRowMetrics.gutterTotal(numberWidth: parent.numberWidth)
                + ReviewRowMetrics.codeLeadingInset
            // The gutter floats over the horizontally scrolling table. Its
            // visible edge therefore includes the document's current offset;
            // testing against the fixed document origin turns the gutter into
            // a code hit target after a long horizontal scroll.
            let visibleCodeStart = (table.enclosingScrollView?.documentVisibleRect.minX ?? 0)
                + ReviewRowMetrics.gutterTotal(numberWidth: parent.numberWidth)
                + ReviewRowMetrics.codeLeadingInset
            guard anchor != nil || point.x >= visibleCodeStart else { return nil }
            hitX = anchor == nil ? point.x : max(point.x, visibleCodeStart)
        case let .splitCode(pair):
            let width = ReviewRowMetrics.sideWidth(in: table.bounds.width)
            let resolvedSide = requestedSide ?? .new
            guard let value = pair.line(on: resolvedSide), value.isTextSelectable else { return nil }
            line = value
            side = resolvedSide
            let cellOrigin = resolvedSide == .old ? 0 : width + ReviewRowMetrics.splitDivider
            textOrigin = cellOrigin
                + ReviewRowMetrics.sideGutterTotal(numberWidth: parent.numberWidth)
                + ReviewRowMetrics.codeLeadingInset
            guard anchor != nil || point.x >= textOrigin else { return nil }
            let cellEnd = cellOrigin + width - ReviewRowMetrics.codeTrailingInset
            hitX = min(max(point.x, textOrigin), cellEnd)
        case .notice, .hunk, .comment, .composer, .expander:
            return nil
        }
        let x = max(0, hitX - textOrigin + (parent.layout == .sideBySide ? codeOffset : 0))
        return ReviewTextPosition(
            rowIndex: row,
            lineID: line.id,
            side: side,
            utf16Offset: codeTextLayout.utf16Offset(in: line.text, x: x, font: ReviewRowMetrics.font)
        )
    }

    func selectCodeLine(at position: ReviewTextPosition, extending: Bool) {
        guard let line = textLine(at: position), line.isCommentable else { return }
        if extending,
           parent.selection.side == position.side,
           let anchor = parent.selection.anchorLineID,
           ReviewRunBounds.canExtend(parent.diffLines, from: anchor, to: position.lineID)
        {
            parent.selection.extend(to: position.lineID)
        } else {
            parent.selection.select(position.lineID, on: position.side)
        }
    }

    func selectTextUnit(at position: ReviewTextPosition, clickCount: Int) {
        guard let line = textLine(at: position), line.isTextSelectable else { return }
        let length = (line.text as NSString).length
        let range = clickCount >= 3
            ? NSRange(location: 0, length: length)
            : ReviewCodeTextLayout.wordRange(in: line.text, at: position.utf16Offset)
        var selection = ReviewTextSelection()
        selection.select(
            from: ReviewTextPosition(
                rowIndex: position.rowIndex,
                lineID: line.id,
                side: position.side,
                utf16Offset: range.location
            ),
            to: ReviewTextPosition(
                rowIndex: position.rowIndex,
                lineID: line.id,
                side: position.side,
                utf16Offset: NSMaxRange(range)
            )
        )
        parent.textSelection = selection
    }

    func syncTextSelection(in table: NSTableView) {
        let previous = appliedTextSelection
        guard previous != parent.textSelection else { return }
        appliedTextSelection = parent.textSelection
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let upper = min(visible.location + visible.length, parent.rows.count)
        guard visible.location < upper else { return }
        let changed = IndexSet((visible.location..<upper).filter { index in
            switch parent.rows[index].kind {
            case let .code(line):
                previous.range(in: line, at: index, on: nil)
                    != parent.textSelection.range(in: line, at: index, on: nil)
            case let .splitCode(pair):
                ReviewSide.allCases.contains { side in
                    guard let line = pair.line(on: side) else { return false }
                    return previous.range(in: line, at: index, on: side)
                        != parent.textSelection.range(in: line, at: index, on: side)
                }
            case .notice, .hunk, .comment, .composer, .expander:
                false
            }
        })
        guard !changed.isEmpty else { return }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
    }

    private func textLine(at position: ReviewTextPosition) -> ReviewLine? {
        guard parent.rows.indices.contains(position.rowIndex) else { return nil }
        let line: ReviewLine? = switch parent.rows[position.rowIndex].kind {
        case let .code(value):
            position.side == nil ? value : nil
        case let .splitCode(pair):
            position.side.flatMap { pair.line(on: $0) }
        case .notice, .hunk, .comment, .composer, .expander:
            nil
        }
        return line?.id == position.lineID ? line : nil
    }

    private func nearestTextRow(from row: Int, toward anchor: Int, on side: ReviewSide?) -> Int? {
        var candidate = row
        let step = row >= anchor ? -1 : 1
        while parent.rows.indices.contains(candidate) {
            let line: ReviewLine? = switch parent.rows[candidate].kind {
            case let .code(value):
                side == nil ? value : nil
            case let .splitCode(pair):
                side.flatMap { pair.line(on: $0) }
            case .notice, .hunk, .comment, .composer, .expander:
                nil
            }
            if line?.isTextSelectable == true {
                return candidate
            }
            if candidate == anchor {
                return nil
            }
            candidate += step
        }
        return nil
    }
}
