// ReviewExpanderRowView.swift
// Limpid — the control that stands in for the lines a unified diff left out.
//
// Its own file rather than more of `ReviewRowViews`: that file had reached the
// length one file is allowed, and this view shares nothing with the rows
// around it but its metrics.

import AppKit

/// The lines a unified diff left out, offered rather than drawn.
///
/// Four controls at most: twenty lines toward the hunk below, twenty away from
/// the hunk above, the whole run at once, and putting it back. A gap has both
/// neighbours only in the middle of a file, so the ends show what applies to
/// them.
///
/// Two pairs of mirrored glyphs rather than four unrelated ones: a chevron
/// steps by twenty in the direction it points, and the arrows either side of a
/// line open or close the run whole. Read together, each button's opposite is
/// its own reflection.
final class ReviewExpanderRowView: NSView {
    private let count = NSTextField(labelWithString: "")
    private let up = NSButton()
    private let down = NSButton()
    private let all = NSButton()
    private let fold = NSButton()
    var onExpand: ((ReviewGapAction) -> Void)?
    private var labelLeading: NSLayoutConstraint?
    private var controls: NSStackView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.lineBreakMode = .byTruncatingTail
        addSubview(count)
        // Labels are set in `configure`, not here: these rows are pooled, so
        // one built before a language switch would keep the old words.
        configure(button: up, action: #selector(expandUp))
        configure(button: down, action: #selector(expandDown))
        configure(button: all, action: #selector(expandAll))
        configure(button: fold, action: #selector(collapse))
        // A stack, because the controls come and go: a gap has both
        // neighbours only in the middle of a file, and a fully unfolded one
        // offers nothing but the way back. Constrained individually, a hidden
        // button keeps the space it would have taken, which left the one
        // remaining control adrift in the middle of the row.
        let controls = NSStackView(views: [up, down, all, fold])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.detachesHiddenViews = true
        addSubview(controls)
        self.controls = controls
        let leading = controls.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ReviewRowMetrics.gutterTotal(numberWidth: ReviewRowMetrics.defaultNumberWidth)
                + ReviewRowMetrics.expanderLeadingInset
        )
        labelLeading = leading
        NSLayoutConstraint.activate([
            leading,
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The count reads as the label of the buttons before it, so it
            // follows them rather than sitting alone against the gutter with
            // the controls somewhere off to the right.
            count.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
    }

    /// The glyph carries its label as its description, so it is rebuilt with
    /// the label whenever the row is configured.
    private static func label(
        _ button: NSButton,
        symbol: String,
        _ resource: LocalizedStringResource,
        in locale: Locale
    ) {
        let label = resource.resolved(in: locale)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// A `CGColor` does not follow the appearance, so it is re-read whenever
    /// the row is reused or the system switches — in `updateLayer`, which is
    /// the pass AppKit runs with the view's own appearance current.
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
        NSColor.labelColor.withAlphaComponent(0.03)
    }

    /// `locale` is the table's, handed down on every reload.
    func configure(_ expander: ReviewExpander, numberWidth: CGFloat, layout: ReviewDiffLayout, locale: Locale) {
        labelLeading?.constant = ReviewRowMetrics.gutterTotal(numberWidth: numberWidth, layout: layout)
            + ReviewRowMetrics.expanderLeadingInset
        Self.label(up, symbol: "chevron.up", "Expand Up", in: locale)
        Self.label(down, symbol: "chevron.down", "Expand Down", in: locale)
        Self.label(all, symbol: "arrow.up.and.line.horizontal.and.arrow.down", "Expand All", in: locale)
        Self.label(fold, symbol: "arrow.down.and.line.horizontal.and.arrow.up", "Collapse Context", in: locale)
        let resource: LocalizedStringResource = expander.hidden > 0
            ? "\(expander.hidden) hidden lines"
            : "Expanded"
        let text = resource.resolved(in: locale)
        count.stringValue = text
        up.isHidden = !expander.canExpandUp || expander.hidden == 0
        down.isHidden = !expander.canExpandDown || expander.hidden == 0
        all.isHidden = expander.hidden == 0
        fold.isHidden = !expander.canCollapse
        needsDisplay = true
        count.setAccessibilityLabel(text)
    }

    @objc private func expandUp() {
        onExpand?(.up)
    }

    @objc private func expandDown() {
        onExpand?(.down)
    }

    @objc private func expandAll() {
        onExpand?(.all)
    }

    @objc private func collapse() {
        onExpand?(.collapse)
    }
}

/// Why a file cannot be reviewed as text, shown where its diff would be.
final class ReviewNoticeRowView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ReviewRowMetrics.labelFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ notice: LocalizedStringResource, locale: Locale) {
        let text = notice.resolved(in: locale)
        label.stringValue = text
        label.setAccessibilityLabel(text)
    }
}
