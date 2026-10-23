// ReviewRowViews.swift
// Limpid — reusable AppKit rows for the review diff.

import AppKit
import SwiftUI

/// Shared metrics. The table asks for a row's height before it builds the
/// view, so the numbers have to live somewhere both sides can read.
enum ReviewRowMetrics {
    /// Tall enough to click. 20pt rows read as a dense diff and were hard to
    /// hit, especially while dragging across a run.
    static let code: CGFloat = 23
    static let hunk: CGFloat = 24
    static let notice: CGFloat = 28
    static let composerMinimum: CGFloat = 118
    static let composerMaximum: CGFloat = 360
    static let commentMinimum: CGFloat = 78
    /// The change band at the very left: green for an added line, red for a
    /// removed one. It replaces the `+` / `-` column, which said the same
    /// thing twice and cost a character of every line's width.
    static let bandWidth: CGFloat = 4
    static let gutterWidth: CGFloat = 16
    /// Used until a diff says how many digits its line numbers need. Fixed
    /// columns wide enough for five digits put a finger-wide gap in front of
    /// every line of a two-hundred-line file.
    static let defaultNumberWidth: CGFloat = 26

    /// Computed rather than stored: `NSFont` is not `Sendable`, and a stored
    /// static of a non-Sendable type is a global mutable reference under Swift 6.
    static var font: NSFont {
        .monospacedSystemFont(ofSize: LimpidFont.Supervision.Size.meta.rawValue, weight: .regular)
    }

    static var commentFont: NSFont {
        .systemFont(ofSize: LimpidFont.Supervision.Size.row.rawValue)
    }

    static var labelFont: NSFont {
        .systemFont(ofSize: LimpidFont.Supervision.Size.caption.rawValue)
    }

    static var digitWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// One number column, sized to the largest line number the file actually
    /// has. Two digits is the floor so short files still read as columns.
    static func numberWidth(forHighestLine line: Int) -> CGFloat {
        let digits = max(2, String(max(line, 1)).count)
        return ceil(CGFloat(digits) * digitWidth) + 8
    }

    /// Width of the frozen strip: change band, comment marker, both numbers.
    static func gutterTotal(numberWidth: CGFloat) -> CGFloat {
        bandWidth + gutterWidth + numberWidth * 2 + 8
    }

    /// The same, for one column of the side-by-side layout, which carries only
    /// its own side's number.
    static func sideGutterTotal(numberWidth: CGFloat) -> CGFloat {
        bandWidth + gutterWidth + numberWidth + 8
    }

    /// The hairline between the two columns.
    static let splitDivider: CGFloat = 1

    /// Both columns are the same width. An adjustable divider would have to
    /// persist its position, clamp it against the card inset and invalidate
    /// the row cache on every drag; an even split needs none of that and is
    /// what the layout is for.
    static func sideWidth(in viewport: CGFloat) -> CGFloat {
        max(((viewport - splitDivider) / 2).rounded(.down), 1)
    }

    static func gutterTotal(numberWidth: CGFloat, layout: ReviewDiffLayout) -> CGFloat {
        switch layout {
        case .unified: gutterTotal(numberWidth: numberWidth)
        case .sideBySide: sideGutterTotal(numberWidth: numberWidth)
        }
    }

    /// Cards — saved comments and the composer — start clear of the frozen
    /// strip. It is sized from the file's line numbers, so this is too: a
    /// fixed inset either overlapped the numbers on a long file or left a
    /// gap on a short one.
    static func cardInset(numberWidth: CGFloat, layout: ReviewDiffLayout) -> CGFloat {
        gutterTotal(numberWidth: numberWidth, layout: layout) + 8
    }

    static let cardTrailing: CGFloat = 14
    /// Gap between a card and the code row above and below it. The same on
    /// both sides: a card sits between two lines, and 3pt over 5pt read as the
    /// card belonging to the line above it.
    static let cardGap: CGFloat = 4
    /// Header, padding and footer around a comment's body.
    static let cardChrome: CGFloat = 62
    /// Header, padding, footer and buttons around the composer's text view.
    static let composerChrome: CGFloat = 96
    /// What the body of a comment card is inset by, both sides together. The
    /// constraints that draw the card read the same number, so a change to the
    /// padding cannot leave the measured width behind — which showed as text
    /// clipped against an edge that had moved.
    static let commentBodyInset: CGFloat = 24
    /// The same, for the composer, whose text view sits inside a scroll view
    /// and so is inset twice.
    static let composerTextInset: CGFloat = 32
    /// What the text view is inset by inside its own scroll view, which is the
    /// half of `composerTextInset` the card's constraints do not draw.
    static let composerFieldPadding: CGFloat = 6
    /// Where a line's text starts after the frozen gutter, and where it stops
    /// before the right edge. Named because the split layout draws with them
    /// and the horizontal scroll limit is computed from their sum, so moving
    /// the text moves what the reader can scroll to with it.
    static let codeLeadingInset: CGFloat = 6
    static let codeTrailingInset: CGFloat = 4
    /// The expander's controls sit where a line's text would, less the bezel
    /// its buttons draw inside their own frames.
    static let expanderLeadingInset: CGFloat = 4
    /// Slack past the longest line, so the last character is not against the
    /// right edge when the column is scrolled to its end.
    static let columnTrailingSlack: CGFloat = 24

    /// The width a card keeps beside the frozen strip. In a column narrower
    /// than the strip plus this, the card steps left over the strip rather
    /// than shrink further: the strip is numbers the card's own header
    /// repeats, and the comment is what the reader is there for.
    static let cardComfortableWidth: CGFloat = 280
    /// Where a card that has stepped over the strip stops: clear of the
    /// viewport's leading edge, as it is clear of the trailing one.
    static let cardEdgeInset: CGFloat = 8

    /// Where a card starts in the visible area, and how wide it is.
    ///
    /// As wide as the visible area allows, never as wide as the column: the
    /// column is sized to the file's longest line. And never wider than the
    /// visible area either. A 280pt floor on the width did that in a narrow
    /// column under a long file's gutter, and the card's trailing edge — its
    /// Add button and its position — went past the edge the reader could
    /// see. The leading steps over the strip first; past that, the card
    /// narrows with the viewport.
    static func cardFrame(
        viewport: CGFloat,
        numberWidth: CGFloat,
        layout: ReviewDiffLayout
    ) -> (leading: CGFloat, width: CGFloat) {
        let inset = cardInset(numberWidth: numberWidth, layout: layout)
        let leading = min(inset, max(cardEdgeInset, viewport - cardTrailing - cardComfortableWidth))
        return (leading, max(viewport - leading - cardTrailing, 0))
    }

    /// The composer grows with the text: a comment worth several lines was
    /// being written through a two-line window. Measured at the width the
    /// card is drawn at, with no floor of its own: a wider one answered with
    /// fewer lines than the text view wrapped to, and the card cut off its
    /// buttons.
    static func composerHeight(for text: String, header: ReviewCardHeader, metrics: ReviewCardMetrics) -> CGFloat {
        let width = metrics.frame.width
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: max(width - composerTextInset, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: commentFont]
        ).height
        // Added after the clamp, so the header's second line takes nothing
        // from the field: under the minimum it would have been absorbed.
        let wrap = header.wraps(inCardWidth: width) ? cardHeaderWrapHeight : 0
        return min(max(composerMinimum, ceil(measured) + composerChrome), composerMaximum) + wrap
    }

    /// Comment bodies wrap, so their row height depends on the text. We measure
    /// with the same font, inset and width the table will draw with.
    static func commentHeight(for body: String, header: ReviewCardHeader, metrics: ReviewCardMetrics) -> CGFloat {
        let width = metrics.frame.width
        let bounds = (body as NSString).boundingRect(
            with: NSSize(width: max(width - commentBodyInset, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: commentFont]
        )
        let wrap = header.wraps(inCardWidth: width) ? cardHeaderWrapHeight : 0
        return max(commentMinimum, ceil(bounds.height) + cardChrome) + wrap
    }

    // MARK: - Card header

    static var cardTitleFont: NSFont {
        .systemFont(ofSize: LimpidFont.Supervision.Size.meta.rawValue, weight: .semibold)
    }

    static var cardDetailFont: NSFont {
        .monospacedSystemFont(ofSize: LimpidFont.Supervision.Size.micro.rawValue, weight: .regular)
    }

    /// Where the title starts: the icon's inset, the icon, and the gap after
    /// it. The constraints that draw the header read the same numbers.
    static let cardIconLeading: CGFloat = 10
    static let cardIconSize: CGFloat = 13
    static let cardIconGap: CGFloat = 6
    static var cardTitleLeading: CGFloat {
        cardIconLeading + cardIconSize + cardIconGap
    }

    static let cardHeaderTrailing: CGFloat = 10
    /// The least space between the title side of the header and the
    /// position; and between a saved comment's title and its state.
    static let cardHeaderGap: CGFloat = 8
    static let cardStateGap: CGFloat = 6
    /// The position's own line, when it does not fit beside the title, and
    /// the gap above it. Fixed rather than left to the label: the row's
    /// height is computed before the row is built, and has to come out as
    /// tall as the line drawn.
    static let cardDetailLineHeight: CGFloat = 14
    static let cardDetailLineGap: CGFloat = 3
    static var cardHeaderWrapHeight: CGFloat {
        cardDetailLineHeight + cardDetailLineGap
    }

    /// How wide a label is with `text` in `font`. A label adds nothing
    /// around its text: its intrinsic width is the text's, rounded up to
    /// the half point, and an empty one is zero wide. Rounded up to the
    /// whole point here, so a header measured as fitting never has a label
    /// that then truncates.
    static func labelWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Line numbers, the change band and the comment marker, drawn once for every
/// visible row and pinned to the left edge.
///
/// A floating subview of the scroll view (`addFloatingSubview(_:for: .horizontal)`)
/// rather than part of each row: the diff scrolls horizontally for long lines,
/// and numbers that slide out of view take the reader's place in the file with
/// them.
final class ReviewGutterView: NSView {
    weak var table: NSTableView?
    var rows: [ReviewRow] = []
    var selection = ReviewSelection()
    var commentCounts: [Int: Int] = [:]
    var numberWidth = ReviewRowMetrics.defaultNumberWidth
    /// Whether the cards' rows are left uncovered: in a column too narrow
    /// for a card beside the strip, the card steps over it
    /// (`ReviewRowMetrics.cardFrame`), and the strip drawn on top would cut
    /// off its icon and title.
    var leavesCardsUncovered = false
    /// Pressed on the marker of the selected run. The composer belongs to the
    /// surface, so opening it goes back through the table's coordinator.
    var onAddComment: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // macOS 14 stopped clipping subview drawing by default, and this view
        // is handed a dirty rect wider than itself. See `draw(_:)`.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    /// Decoration for the rows beside it, which carry the same numbers in
    /// their own labels. Announcing it would read every number twice.
    override func isAccessibilityElement() -> Bool {
        false
    }

    /// The row the add-comment marker is drawn on: the end of the selected
    /// run, which is where the composer would open. The normalized end, not
    /// the line the drag stopped on — a run extended upward ends above where
    /// it started, and the marker sat on one row while the composer opened
    /// under another.
    private var markerRow: Int? {
        guard let end = selection.endLineID else { return nil }
        return rows.firstIndex { $0.line?.id == end && $0.isSelectable }
    }

    private func markerRect(for row: Int) -> NSRect? {
        guard let table, rows.indices.contains(row) else { return nil }
        return ReviewRowPainter.markerRect(in: table.rect(ofRow: row))
    }

    /// Only the marker takes the pointer. The rest of the strip sits over the
    /// rows, and swallowing clicks there would stop a line being selected by
    /// its number.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let row = markerRow, let rect = markerRect(for: row) else { return nil }
        return rect.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with _: NSEvent) {
        onAddComment?()
    }

    override func resetCursorRects() {
        guard let row = markerRow, let rect = markerRect(for: row) else { return }
        addCursorRect(rect, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table else { return }
        // Our own bounds, never the dirty rect. A floating subview reports the
        // scroll view's whole visible area as its `visibleRect`, and that is
        // what arrives here as the rect to draw; since macOS 14 a view does
        // not clip its drawing to its bounds either, so filling it painted an
        // opaque sheet over the diff beside us — line numbers on an empty
        // column, which is exactly what it looked like.
        let area = bounds.intersection(dirtyRect)
        ReviewRowPainter.fillNumberStrip(area)
        let metrics = ReviewRowMetrics.self
        let range = table.rows(in: NSRect(
            x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height
        ))
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) where rows.indices.contains(row) {
            // A file's header starts at the left edge, with its checkbox, and
            // a notice ("Loading changes…", why a file cannot be shown) a
            // little way in; the strip leaves both uncovered rather than cut
            // off their first words. A hunk's header is an opaque band across
            // the row (`ReviewHunkRowView`), which the strip over its start
            // split in two; it carries no numbers.
            let isUncovered = switch rows[row].kind {
            case .file, .notice, .hunk: true
            case .comment, .composer: leavesCardsUncovered
            default: false
            }
            if isUncovered {
                let frame = table.rect(ofRow: row)
                NSColor.clear.setFill()
                NSRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height).intersection(area).fill(using: .copy)
                continue
            }
            guard case let .code(line) = rows[row].kind else { continue }
            let frame = table.rect(ofRow: row)
            let strip = NSRect(
                x: 0, y: frame.minY,
                width: metrics.gutterTotal(numberWidth: numberWidth), height: frame.height
            )
            let isSelected = selection.contains(line.id)
            draw(line: line, in: strip, isSelected: isSelected)
            // `isCommentable` as well as selected: the hit test asks for both,
            // and a marker drawn without it was an invitation the row refused.
            if selection.endLineID == line.id, line.isCommentable {
                ReviewRowPainter.drawAddMarker(in: ReviewRowPainter.markerRect(in: strip))
            }
        }
    }

    private func draw(line: ReviewLine, in strip: NSRect, isSelected: Bool) {
        let metrics = ReviewRowMetrics.self
        // The same fill as the code beside it: a row that changes color
        // halfway across reads as two rows, and the numbers are part of the
        // line they belong to.
        ReviewRowPainter.background(for: line.kind, isSelected: isSelected).setFill()
        strip.fill()
        ReviewRowPainter.band(for: line.kind).setFill()
        NSRect(x: 0, y: strip.minY, width: metrics.bandWidth, height: strip.height).fill()

        if commentCounts[line.id] ?? 0 > 0, selection.endLineID != line.id {
            ReviewRowPainter.drawCommentDot(in: ReviewRowPainter.markerRect(in: strip))
        }
        let emphasis: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        ReviewRowPainter.draw(
            line.oldLine.map(String.init) ?? "",
            in: NSRect(
                x: metrics.bandWidth + metrics.gutterWidth, y: strip.minY,
                width: numberWidth, height: strip.height
            ),
            font: metrics.font, color: emphasis, alignment: .right
        )
        ReviewRowPainter.draw(
            line.newLine.map(String.init) ?? "",
            in: NSRect(
                x: metrics.bandWidth + metrics.gutterWidth + numberWidth + 4, y: strip.minY,
                width: numberWidth, height: strip.height
            ),
            font: metrics.font, color: emphasis, alignment: .right
        )
    }
}

/// The `@@` line, kept as a compact separator. Git's remaining file metadata
/// is not rendered at all — it told the reader nothing and pushed the first
/// real change five rows down.
final class ReviewHunkRowView: NSView {
    private let label = NSTextField(labelWithString: "")
    /// The header's buttons, drawn in SwiftUI so "Discard" looks like
    /// every other destructive action; empty where the header offers
    /// nothing.
    private let actions = NSHostingView(rootView: ReviewHosted(
        environment: .init(),
        content: ReviewHunkActionsView(action: nil, isCommentable: false)
    ))
    /// The hunk header sits beside the frozen strip, which is as wide as the
    /// file's line numbers need.
    private var labelLeading: NSLayoutConstraint?
    /// Whether the hunk was discarded, which the header shows in the hover
    /// gray.
    private var isDiscarded = false
    /// The surface's opacity (`ReviewDiffTable.surfaceOpacity`), which the
    /// header's ground takes; its buttons take it with the rest of what the
    /// table hands over (`ReviewHosted`).
    private var surfaceOpacity: Double = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        // In the supervision window's tokens: its words in `muted`, which
        // reads at 4.5:1 on the header's ground.
        label.font = .monospacedSystemFont(ofSize: LimpidFont.Supervision.Size.detail.rawValue, weight: .regular)
        label.textColor = SupervisionTokens.muted.nsColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(actions)
        let leading = label.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.gutterTotal(numberWidth: ReviewRowMetrics.defaultNumberWidth) + 6
        )
        labelLeading = leading
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A `CGColor` does not follow the appearance, and this row was the one
    /// that kept its old background through a light/dark switch until it
    /// happened to be reused. The color is resolved in `updateLayer`, which
    /// is the pass AppKit runs with the view's own appearance current.
    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Neutral rather than the unread blue: a hunk is what is read, not a
    /// state. A step lighter than the file's header (`sidebar`) so the
    /// two levels read apart, and as see-through as the surface.
    private var background: NSColor {
        (isDiscarded ? SupervisionTokens.hover : SupervisionTokens.column).nsColor
            .withAlphaComponent(surfaceOpacity)
    }

    func configure(
        _ line: ReviewLine,
        numberWidth: CGFloat,
        layout: ReviewDiffLayout,
        surfaceOpacity: Double = 1
    ) {
        self.surfaceOpacity = surfaceOpacity
        // The left column's code, in either layout. Side by side has one number
        // per column, so the unified inset would start the header a whole
        // number's width past the code under it.
        labelLeading?.constant = ReviewRowMetrics.gutterTotal(numberWidth: numberWidth, layout: layout)
            + ReviewRowMetrics.codeLeadingInset
        label.stringValue = line.text
        needsDisplay = true
        label.setAccessibilityLabel(line.text)
    }

    /// What the header offers (`ReviewHunkAction`, and "Comment" where the
    /// hunk has lines to comment on), and what its buttons do.
    func configureActions(
        _ action: ReviewHunkAction?,
        isCommentable: Bool,
        environment: ReviewHostedEnvironment,
        handlers: ReviewHunkActionsView.Handlers
    ) {
        actions.rootView = ReviewHosted(environment: environment, content: ReviewHunkActionsView(
            action: action,
            isCommentable: isCommentable,
            header: label.stringValue,
            handlers: handlers
        ))
        actions.isHidden = action == nil && !isCommentable
        let isDiscarded = switch action {
        case .discarded, .uncertain: true
        default: false
        }
        if self.isDiscarded != isDiscarded {
            self.isDiscarded = isDiscarded
            needsDisplay = true
        }
    }
}
