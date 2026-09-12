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
        .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    }

    static var commentFont: NSFont {
        .systemFont(ofSize: 12)
    }

    static var labelFont: NSFont {
        .systemFont(ofSize: 11)
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
    /// and the horizontal scroll limit is computed from their sum: the limit
    /// used to repeat that sum as one number of its own, so moving the text
    /// left moved what the reader could scroll to and not the other way.
    static let codeLeadingInset: CGFloat = 6
    static let codeTrailingInset: CGFloat = 4
    /// The expander's controls sit where a line's text would, less the bezel
    /// its buttons draw inside their own frames.
    static let expanderLeadingInset: CGFloat = 4
    /// Slack past the longest line, so the last character is not against the
    /// right edge when the column is scrolled to its end.
    static let columnTrailingSlack: CGFloat = 24
    /// How far one keyboard step resizes the terminal strip. Larger than a
    /// point so the key is worth pressing, smaller than a row so it can be
    /// aimed.
    static let strideForResize: CGFloat = 24

    /// The narrowest viewport a card is measured against. A window dragged
    /// smaller than this measures as if it were this wide rather than
    /// answering with a height for a width nothing is drawn at.
    static let minimumMeasurementWidth: CGFloat = 320

    /// A card is as wide as the visible area allows, never as wide as the
    /// column: the column is sized to the file's longest line.
    static func cardWidth(in viewport: CGFloat, numberWidth: CGFloat, layout: ReviewDiffLayout) -> CGFloat {
        max(viewport - cardInset(numberWidth: numberWidth, layout: layout) - cardTrailing, 280)
    }

    /// The composer grows with the text: a comment worth several lines was
    /// being written through a two-line window.
    static func composerHeight(
        for text: String,
        width: CGFloat,
        numberWidth: CGFloat,
        layout: ReviewDiffLayout
    ) -> CGFloat {
        let usable = max(cardWidth(in: width, numberWidth: numberWidth, layout: layout) - composerTextInset, 120)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: usable, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: commentFont]
        ).height
        return min(max(composerMinimum, ceil(measured) + composerChrome), composerMaximum)
    }

    /// Comment bodies wrap, so their row height depends on the text. We measure
    /// with the same font and inset the table will draw with.
    static func commentHeight(
        for body: String,
        width: CGFloat,
        numberWidth: CGFloat,
        layout: ReviewDiffLayout
    ) -> CGFloat {
        let usable = max(cardWidth(in: width, numberWidth: numberWidth, layout: layout) - commentBodyInset, 120)
        let bounds = (body as NSString).boundingRect(
            with: NSSize(width: usable, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: commentFont]
        )
        return max(commentMinimum, ceil(bounds.height) + cardChrome)
    }
}

/// Rounded container shared by the comment and composer rows, so a saved
/// comment and the one being written read as the same object.
final class ReviewCardView: NSView {
    /// A card being written into is the one thing on the surface that takes
    /// input. Drawn identically to a saved comment, the two were impossible to
    /// tell apart at a glance.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Layer colors do not follow an appearance change on their own, and
    /// `updateLayer` is only called for a view that asks to draw that way.
    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        layer?.borderColor = isActive
            ? ReviewRowPainter.accent.withAlphaComponent(0.75).cgColor
            : NSColor.separatorColor.cgColor
        layer?.backgroundColor = isActive
            ? ReviewRowPainter.accent.withAlphaComponent(0.08).cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }
}

/// The composer's text area: a bordered field, so the empty space in it reads
/// as somewhere to type rather than as padding.
final class ReviewFieldView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        applyColors()
    }

    private func applyColors() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.65).cgColor
    }
}

/// One line of code in the unified layout, on the fill its kind gives it.
///
/// The numbers and the markers beside them belong to the frozen gutter, which
/// draws over this row and stays put while the code scrolls sideways. There is
/// no `+` / `-` column: the band at the left says the same thing in less room.
/// Where a line sits, for the reader who cannot see the gutter. Old and new
/// are named rather than separated by a slash: the order is not something a
/// punctuation mark can say.
private func reviewLinePosition(_ line: ReviewLine) -> String {
    let old = line.oldLine.map(String.init) ?? "-"
    let new = line.newLine.map(String.init) ?? "-"
    return String(localized: "Old \(old) → new \(new)")
}

final class ReviewCodeRowView: NSView {
    private let code = NSTextField(labelWithString: "")
    private var codeLeading: NSLayoutConstraint?
    /// What the background was resolved from. A `CGColor` does not follow the
    /// appearance, and the gutter beside this row resolves its own at draw
    /// time — so without this the two halves of a row disagree after a switch
    /// between light and dark.
    private var appearanceInput: (kind: ReviewLine.Kind, isSelected: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        code.translatesAutoresizingMaskIntoConstraints = false
        code.font = ReviewRowMetrics.font
        code.lineBreakMode = .byTruncatingTail
        addSubview(code)
        let leading = code.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.gutterTotal(numberWidth: ReviewRowMetrics.defaultNumberWidth) + 6
        )
        codeLeading = leading
        NSLayoutConstraint.activate([
            leading,
            code.trailingAnchor.constraint(equalTo: trailingAnchor),
            code.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Through `updateLayer` rather than straight out of
    /// `viewDidChangeEffectiveAppearance`: `NSColor.cgColor` resolves against
    /// `NSAppearance.current`, which AppKit sets for the drawing pass but not
    /// for the notification. Reading it there returned the appearance we were
    /// leaving, so the row kept its old background across a light/dark switch.
    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        guard let appearanceInput else { return }
        layer?.backgroundColor = ReviewRowPainter.background(
            for: appearanceInput.kind,
            isSelected: appearanceInput.isSelected
        ).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(
        _ line: ReviewLine,
        isSelected: Bool,
        numberWidth: CGFloat,
        language: ReviewSyntax.Language? = nil,
        match: String = "",
        selectedRange: NSRange? = nil
    ) {
        codeLeading?.constant = ReviewRowMetrics.gutterTotal(numberWidth: numberWidth) + ReviewRowMetrics.codeLeadingInset
        // The attributed form only when there is something to draw with it:
        // it carries its own paragraph style, and a line with no keyword and
        // no match in it pays nothing.
        if let styled = ReviewRowPainter.styled(
            line.text,
            language: language,
            match: match,
            attributes: ReviewRowPainter.attributes(
                font: ReviewRowMetrics.font,
                color: .labelColor,
                alignment: .left,
                truncates: true
            ),
            selectedRange: selectedRange
        ) {
            code.attributedStringValue = styled
        } else {
            code.stringValue = line.text
        }
        code.textColor = .labelColor
        // Recorded, not resolved: a `CGColor` made here takes whatever
        // appearance happens to be current outside a drawing pass, which is
        // the same mistake `updateLayer` exists to avoid.
        appearanceInput = (line.kind, isSelected)
        needsDisplay = true
        // On the label, not on the row. A bare `NSView` is not an
        // accessibility element however it is labeled, so the row's own label
        // was never read and the numbers — drawn by the frozen gutter, which
        // is not an element either — were lost. The text field is an element,
        // and naming it leaves the code as its value: read once, after where
        // it is.
        code.setAccessibilityLabel(reviewLinePosition(line))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(code.frame, cursor: .iBeam)
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
    /// The hunk header sits beside the frozen strip, which is as wide as the
    /// file's line numbers need.
    private var labelLeading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        let leading = label.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.gutterTotal(numberWidth: ReviewRowMetrics.defaultNumberWidth) + 6
        )
        labelLeading = leading
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
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
        layer?.backgroundColor = Self.background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static var background: NSColor {
        NSColor.labelColor.withAlphaComponent(0.04)
    }

    func configure(_ line: ReviewLine, numberWidth: CGFloat, layout: ReviewDiffLayout) {
        // The left column's code, in either layout. Side by side has one number
        // per column, so the unified inset would start the header a whole
        // number's width past the code under it.
        labelLeading?.constant = ReviewRowMetrics.gutterTotal(numberWidth: numberWidth, layout: layout)
            + ReviewRowMetrics.codeLeadingInset
        label.stringValue = line.text
        needsDisplay = true
        label.setAccessibilityLabel(line.text)
    }
}

/// What a card needs from the table to place itself: the width the reader can
/// actually see, and the frozen strip it has to start clear of.
struct ReviewCardMetrics {
    let viewport: CGFloat
    let numberWidth: CGFloat
    /// Cards stay full width in both layouts, but where they start depends on
    /// the layout: they line up with the left column's code.
    let layout: ReviewDiffLayout
}

/// A saved comment, drawn under the last line of the run it covers. It used to
/// live in a horizontal strip at the bottom of the surface, where nothing
/// connected it to its lines.
final class ReviewCommentRowView: NSView {
    private let card = ReviewCardView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    /// Says whether this comment has already gone to an agent. Only two of the
    /// three states can appear on a card — a resolved comment is not drawn in
    /// the diff at all — so one label carries it.
    private let state = NSTextField(labelWithString: "")
    private let resolveButton = NSButton()
    private let editButton = NSButton()
    private let deleteButton = NSButton()
    var onResolve: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    private var cardWidth: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "text.bubble",
            accessibilityDescription: nil
        )
        icon.contentTintColor = .secondaryLabelColor
        card.addSubview(icon)
        for label in [title, position, body, state] {
            label.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(label)
        }
        state.font = ReviewRowMetrics.labelFont
        state.textColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.stringValue = String(localized: "Comment")
        position.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        position.textColor = .tertiaryLabelColor
        position.alignment = .right
        body.font = ReviewRowMetrics.commentFont
        body.isSelectable = true
        configure(button: resolveButton, title: String(localized: "Resolve"), action: #selector(resolve))
        configure(button: editButton, title: String(localized: "Edit"), action: #selector(edit))
        configure(button: deleteButton, title: String(localized: "Delete"), action: #selector(remove))
        installConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = ReviewRowMetrics.labelFont
        button.contentTintColor = ReviewRowPainter.accent
        button.target = self
        button.action = action
        button.setAccessibilityLabel(title)
        card.addSubview(button)
    }

    private func installConstraints() {
        // Width comes from the viewport rather than the row: the column is as
        // wide as the file's longest line, and a card that followed it put the
        // comment body on one endless line off the right edge.
        let width = card.widthAnchor.constraint(equalToConstant: 400)
        cardWidth = width
        let leading = card.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.cardInset(
                numberWidth: ReviewRowMetrics.defaultNumberWidth,
                layout: .unified
            )
        )
        cardLeading = leading
        NSLayoutConstraint.activate([
            leading,
            width,
            card.topAnchor.constraint(equalTo: topAnchor, constant: ReviewRowMetrics.cardGap),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ReviewRowMetrics.cardGap),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            state.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            state.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            position.leadingAnchor.constraint(greaterThanOrEqualTo: state.trailingAnchor, constant: 8),
            position.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            position.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            body.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: ReviewRowMetrics.commentBodyInset / 2
            ),
            body.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -ReviewRowMetrics.commentBodyInset / 2
            ),
            body.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            deleteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -12),
            resolveButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -12),
            resolveButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            editButton.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 2),
            deleteButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            editButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)
        ])
    }

    func configure(_ comment: ReviewComment, metrics: ReviewCardMetrics) {
        cardLeading?.constant = ReviewRowMetrics.cardInset(
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
        cardWidth?.constant = ReviewRowMetrics.cardWidth(
            in: metrics.viewport,
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
        position.stringValue = "\(comment.file.layer.title) · \(comment.oldSpan) / \(comment.newSpan)"
        body.stringValue = comment.body
        state.stringValue = comment.insertedAt == nil ? "" : String(localized: "Inserted")
        // Re-applied rather than left from construction: these rows are pooled,
        // so one built under the previous accent comes back tinted with it.
        for button in [resolveButton, editButton, deleteButton] {
            button.contentTintColor = ReviewRowPainter.accent
        }
        body.setAccessibilityLabel([position.stringValue, state.stringValue, comment.body]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
    }

    @objc private func resolve() {
        onResolve?()
    }

    @objc private func edit() {
        onEdit?()
    }

    @objc private func remove() {
        onDelete?()
    }
}

/// The composer, opened in place under the run it covers. An `NSTextView`
/// rather than SwiftUI's `TextEditor` because this is where Japanese prose is
/// written and the input method has to behave.
final class ReviewComposerRowView: NSView {
    private let card = ReviewCardView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let field = ReviewFieldView()
    private let scroll = NSScrollView()
    let textView = ReviewComposerTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let addButton = NSButton()
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    private var cardWidth: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        icon.contentTintColor = ReviewRowPainter.accent
        card.addSubview(icon)
        for field in [title, position, placeholder] {
            field.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(field)
        }
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.stringValue = String(localized: "Comment")
        position.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        position.textColor = .tertiaryLabelColor
        position.alignment = .right
        placeholder.font = ReviewRowMetrics.commentFont
        placeholder.textColor = .tertiaryLabelColor
        // A hint, not a question: a form that asks the reader something reads
        // as waiting for an answer, and a comment is as often an observation
        // or a question of its own as it is a change request.
        placeholder.stringValue = String(localized: "Leave a comment")
        textView.font = ReviewRowMetrics.commentFont
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.onCompositionChanged = { [weak self] in self?.updateEnabled() }
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.setAccessibilityLabel(String(localized: "Review comment"))
        field.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(field)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        field.addSubview(scroll)
        card.isActive = true
        style(cancelButton, title: String(localized: "Cancel"), action: #selector(cancel))
        cancelButton.bezelStyle = .inline
        cancelButton.isBordered = false
        cancelButton.contentTintColor = .secondaryLabelColor
        style(addButton, title: String(localized: "Add"), action: #selector(commit))
        addButton.bezelStyle = .rounded
        installConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func style(_ button: NSButton, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.controlSize = .small
        button.font = ReviewRowMetrics.labelFont
        button.target = self
        button.action = action
        button.setAccessibilityLabel(title)
        card.addSubview(button)
    }

    private func installConstraints() {
        let width = card.widthAnchor.constraint(equalToConstant: 400)
        cardWidth = width
        let leading = card.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.cardInset(
                numberWidth: ReviewRowMetrics.defaultNumberWidth,
                layout: .unified
            )
        )
        cardLeading = leading
        NSLayoutConstraint.activate([
            leading,
            width,
            card.topAnchor.constraint(equalTo: topAnchor, constant: ReviewRowMetrics.cardGap),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ReviewRowMetrics.cardGap),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            position.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            position.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            position.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: ReviewRowMetrics.composerTextInset / 2 - ReviewRowMetrics.composerFieldPadding
            ),
            field.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -(ReviewRowMetrics.composerTextInset / 2 - ReviewRowMetrics.composerFieldPadding)
            ),
            field.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -4),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 2),
            addButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            addButton.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
    }

    /// Take a new width without being rebuilt. The composer is one instance
    /// that holds live text and first responder, so a viewport change has to
    /// reach it this way rather than through a reload.
    func resize(to metrics: ReviewCardMetrics) {
        cardLeading?.constant = ReviewRowMetrics.cardInset(
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
        cardWidth?.constant = ReviewRowMetrics.cardWidth(
            in: metrics.viewport,
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
    }

    /// `start` is the first line of the run when more than one line is
    /// selected; the composer is always drawn under the last one.
    func configure(
        _ line: ReviewLine,
        start: ReviewLine?,
        text: String,
        isEditing: Bool,
        metrics: ReviewCardMetrics
    ) {
        cardLeading?.constant = ReviewRowMetrics.cardInset(
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
        cardWidth?.constant = ReviewRowMetrics.cardWidth(
            in: metrics.viewport,
            numberWidth: metrics.numberWidth,
            layout: metrics.layout
        )
        // The composer is one long-lived view rather than a pooled row, so
        // nothing else would ever put a new accent on it.
        icon.contentTintColor = ReviewRowPainter.accent
        // Both headings name the action, so they read as a pair rather than as
        // one action and one noun.
        title.stringValue = isEditing
            ? String(localized: "Edit comment")
            : String(localized: "Add comment")
        // The button says only the verb: the card it sits in holds one comment
        // and says so directly above, and the object repeated three inches
        // below the heading that already carried it read as boilerplate. The
        // full phrase stays on the button for anyone reading it out of that
        // context.
        addButton.title = isEditing ? String(localized: "Save") : String(localized: "Add")
        // Spoken as well as drawn: set once at construction, VoiceOver went on
        // calling it Add while it said Save.
        addButton.setAccessibilityLabel(addButton.title)
        addButton.setAccessibilityTitle(
            isEditing ? String(localized: "Save Comment") : String(localized: "Add Comment")
        )
        let first = start ?? line
        let old = ReviewComment.span(first.oldLine, line.oldLine)
        let new = ReviewComment.span(first.newLine, line.newLine)
        position.stringValue = String(localized: "Old \(old) → new \(new)")
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        updateEnabled()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === textView, !textView.hasMarkedText(),
              event.type == .keyDown, ReviewTableKey(event: event) == .insert
        else {
            return super.performKeyEquivalent(with: event)
        }
        if addButton.isEnabled {
            onCommit?()
        }
        return true
    }

    @discardableResult
    func focusText(restoring selection: NSRange? = nil) -> Bool {
        guard let window else { return false }
        if window.firstResponder === textView {
            return true
        }
        guard window.makeFirstResponder(textView) else { return false }
        // UTF-16 units, which is what `NSRange` counts: a character count puts
        // the caret short of the end as soon as the text holds an emoji.
        let length = (textView.string as NSString).length
        let location = min(selection?.location ?? length, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection?.length ?? 0, length - location)))
        return true
    }

    private func updateEnabled() {
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        addButton.isEnabled = !trimmed.isEmpty && !textView.hasMarkedText()
        placeholder.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
    }

    @objc private func commit() {
        onCommit?()
    }

    @objc private func cancel() {
        onCancel?()
    }
}

extension ReviewComposerRowView: NSTextViewDelegate {
    func textDidChange(_: Notification) {
        updateEnabled()
        onTextChange?(textView.string)
    }

    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return inserts a newline; the comment is committed with ⌘↩ so a
        // multi-line comment can be written without a modifier per line.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
