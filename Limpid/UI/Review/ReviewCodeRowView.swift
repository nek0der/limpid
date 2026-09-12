// ReviewCodeRowView.swift
// Limpid — one selectable code line in the unified review layout.

import AppKit

/// Where a line sits, for the reader who cannot see the gutter. Old and new
/// are named rather than separated by a slash: the order is not something a
/// punctuation mark can say.
private func reviewLinePosition(_ line: ReviewLine) -> String {
    let old = line.oldLine.map(String.init) ?? "-"
    let new = line.newLine.map(String.init) ?? "-"
    return String(localized: "Old \(old) → new \(new)")
}

/// One line of code in the unified layout, on the fill its kind gives it.
/// The numbers and markers belong to the floating gutter beside this view.
final class ReviewCodeRowView: NSView {
    private let code = NSTextField(labelWithString: "")
    private var codeLeading: NSLayoutConstraint?
    /// What the background was resolved from. A `CGColor` does not follow the
    /// appearance, and the gutter resolves its own at draw time.
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

    /// Resolve dynamic colors during the drawing pass, when AppKit has made
    /// the destination appearance current.
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
        intralineRanges: [NSRange] = [],
        selectedRange: NSRange? = nil
    ) {
        codeLeading?.constant = ReviewRowMetrics.gutterTotal(numberWidth: numberWidth)
            + ReviewRowMetrics.codeLeadingInset
        // The attributed form only when there is syntax, search, selection or
        // intraline decoration to draw; plain rows avoid that allocation.
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
            intralineRanges: intralineRanges,
            intralineKind: line.kind,
            selectedRange: selectedRange
        ) {
            code.attributedStringValue = styled
        } else {
            code.stringValue = line.text
        }
        code.textColor = .labelColor
        appearanceInput = (line.kind, isSelected)
        needsDisplay = true
        code.setAccessibilityLabel(reviewLinePosition(line))
        code.setAccessibilityHelp(
            intralineRanges.isEmpty ? nil : String(localized: "Changed characters are highlighted.")
        )
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(code.frame, cursor: .iBeam)
    }
}
