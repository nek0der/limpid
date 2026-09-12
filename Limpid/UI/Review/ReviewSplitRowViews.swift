// ReviewSplitRowViews.swift
// Limpid — the row that draws the old file beside the new one.

import AppKit

/// Everything a split row draws besides the pair itself.
///
/// One value rather than five arguments: the row is drawn by hand, so all of
/// this arrives together every time, and the list had outgrown what one call
/// should carry.
struct ReviewSplitRowContext {
    let selection: ReviewSelection
    let textSelection: ReviewTextSelection
    let intralineHighlights: ReviewIntralineHighlights
    let rowIndex: Int
    let commentCounts: [Int: Int]
    let numberWidth: CGFloat
    let codeOffset: CGFloat
    /// What the find bar is looking for, marked in the code as it is drawn.
    let match: String
    /// The language the file is written in, or `nil` for one we do not color.
    let language: ReviewSyntax.Language?
}

/// One row of the side-by-side layout: the old file's line on the left, the new
/// file's on the right, with a hatched placeholder wherever one column has no
/// counterpart.
///
/// Both columns are drawn by this one row rather than by two tables, which is
/// what guarantees they stay in vertical step: a comment card or the composer
/// opening between two lines moves both sides by construction. Everything is
/// drawn rather than laid out as subviews — a row carries two backgrounds, two
/// change bands, two markers, two numbers and two code cells, and the cells
/// have to clip their own text against the column beside them anyway.
final class ReviewSplitCodeRowView: NSView {
    private var pair: ReviewSplitPair?
    private var selection = ReviewSelection()
    private var textSelection = ReviewTextSelection()
    private var intralineHighlights = ReviewIntralineHighlights()
    private var rowIndex = 0
    private var commentCounts: [Int: Int] = [:]
    private var numberWidth = ReviewRowMetrics.defaultNumberWidth
    /// What the find bar is looking for, marked in the code as it is drawn.
    private var match = ""
    private var language: ReviewSyntax.Language?
    /// How far the code in both columns is scrolled to the left. Shared, so the
    /// two sides stay lined up and the divider between them does not move.
    var codeOffset: CGFloat = 0 {
        didSet {
            guard codeOffset != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Pressed the add-comment marker. Which column it was in is already in
    /// the selection, so the surface opens the composer the same way the
    /// unified gutter does.
    var onAddComment: (() -> Void)?

    /// The table draws top-down, and so do the numbers and the hatch.
    override var isFlipped: Bool {
        true
    }

    /// The row draws its own text rather than holding a label, so nothing under
    /// it would be read: without this VoiceOver walked the split layout as an
    /// empty list. The unified rows keep a text field and must not do the same,
    /// or their code is read twice.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    func configure(_ pair: ReviewSplitPair, context: ReviewSplitRowContext) {
        self.pair = pair
        selection = context.selection
        textSelection = context.textSelection
        intralineHighlights = context.intralineHighlights
        rowIndex = context.rowIndex
        commentCounts = context.commentCounts
        numberWidth = context.numberWidth
        codeOffset = context.codeOffset
        match = context.match
        language = context.language
        let old = pair.old.map { "\($0.oldLine.map(String.init) ?? "-") \($0.text)" } ?? ""
        let new = pair.new.map { "\($0.newLine.map(String.init) ?? "-") \($0.text)" } ?? ""
        setAccessibilityLabel(String(localized: "Old \(old) → new \(new)"))
        // A static text element is read from its value, not its label.
        setAccessibilityValue(String(localized: "Old \(old) → new \(new)"))
        let hasIntraline = [pair.old, pair.new].compactMap(\.self).contains {
            !intralineHighlights[$0.id].isEmpty
        }
        setAccessibilityHelp(
            hasIntraline ? String(localized: "Changed characters are highlighted.") : nil
        )
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Colors resolve at draw time, so a switch between light and dark only has
    /// to ask for the row again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Where this row sits in the document, so the hatch of one placeholder
    /// runs on into the next instead of restarting every 23 points.
    private var hatchPhase: CGFloat {
        guard let document = enclosingScrollView?.documentView else { return 0 }
        return convert(NSPoint.zero, to: document).y
    }

    private func cellRect(for side: ReviewSide) -> NSRect {
        let width = ReviewRowMetrics.sideWidth(in: bounds.width)
        switch side {
        case .old:
            return NSRect(x: 0, y: 0, width: width, height: bounds.height)
        case .new:
            let origin = width + ReviewRowMetrics.splitDivider
            return NSRect(x: origin, y: 0, width: max(bounds.width - origin, 0), height: bounds.height)
        }
    }

    /// The marker the pointer can press: the end of the selected run, in the
    /// column the run was started in.
    private func activeMarkerRect() -> NSRect? {
        guard let pair, let end = selection.endLineID else { return nil }
        for side in ReviewSide.allCases where pair.line(on: side)?.id == end {
            guard pair.line(on: side)?.isCommentable == true else { continue }
            guard selection.side == nil || selection.side == side else { continue }
            return ReviewRowPainter.markerRect(in: cellRect(for: side))
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = activeMarkerRect(), marker.contains(point) {
            onAddComment?()
            return
        }
        // Everything else is the table's: clicking a line selects it, and
        // shift-clicking extends the run.
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        if let pair {
            for side in ReviewSide.allCases where pair.line(on: side)?.isCommentable == true {
                let cell = cellRect(for: side)
                let start = cell.minX
                    + ReviewRowMetrics.sideGutterTotal(numberWidth: numberWidth)
                    + ReviewRowMetrics.codeLeadingInset
                addCursorRect(
                    NSRect(x: start, y: cell.minY, width: max(cell.maxX - start, 0), height: cell.height),
                    cursor: .iBeam
                )
            }
        }
        guard let marker = activeMarkerRect() else { return }
        addCursorRect(marker, cursor: .pointingHand)
    }

    override func draw(_: NSRect) {
        guard let pair else { return }
        for side in ReviewSide.allCases {
            let rect = cellRect(for: side)
            guard let line = pair.line(on: side) else {
                ReviewRowPainter.drawPlaceholder(in: rect, phase: hatchPhase)
                continue
            }
            draw(line, on: side, in: rect)
        }
        NSColor.separatorColor.setFill()
        NSRect(
            x: ReviewRowMetrics.sideWidth(in: bounds.width),
            y: 0,
            width: ReviewRowMetrics.splitDivider,
            height: bounds.height
        ).fill()
    }

    private func draw(_ line: ReviewLine, on side: ReviewSide, in rect: NSRect) {
        let metrics = ReviewRowMetrics.self
        let isSelected = selection.contains(line.id, on: side)
        // The same strip the unified layout puts its numbers on. Without it the
        // number column showed whatever is behind the diff, which reads as code
        // rather than as the margin beside it.
        ReviewRowPainter.fillNumberStrip(NSRect(
            x: rect.minX, y: rect.minY,
            width: metrics.sideGutterTotal(numberWidth: numberWidth), height: rect.height
        ))
        ReviewRowPainter.background(for: line.kind, isSelected: isSelected).setFill()
        rect.fill()
        ReviewRowPainter.band(for: line.kind).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: metrics.bandWidth, height: rect.height).fill()

        let marker = ReviewRowPainter.markerRect(in: rect)
        if selection.endLineID == line.id, line.isCommentable,
           selection.side == nil || selection.side == side
        {
            ReviewRowPainter.drawAddMarker(in: marker)
        } else if commentCounts[line.id] ?? 0 > 0 {
            ReviewRowPainter.drawCommentDot(in: marker)
        }

        let emphasis: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        ReviewRowPainter.draw(
            side.position(of: line).map(String.init) ?? "",
            in: NSRect(
                x: rect.minX + metrics.bandWidth + metrics.gutterWidth,
                y: rect.minY,
                width: numberWidth,
                height: rect.height
            ),
            font: metrics.font, color: emphasis, alignment: .right
        )
        let codeX = rect.minX + metrics.sideGutterTotal(numberWidth: numberWidth) + metrics.codeLeadingInset
        ReviewRowPainter.drawCode(
            line,
            in: NSRect(
                x: codeX, y: rect.minY,
                width: max(rect.maxX - codeX - metrics.codeTrailingInset, 0), height: rect.height
            ),
            offset: codeOffset,
            language: language,
            match: match,
            intralineRanges: intralineHighlights[line.id],
            selectedRange: textSelection.range(in: line, at: rowIndex, on: side)
        )
    }
}
