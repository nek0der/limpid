// ReviewCardRowViews.swift
// Limpid — the review diff's cards: a saved comment and the composer, placed in what the reader can see.

import AppKit

/// The words on a card's header line: the title, a saved comment's state,
/// and the lines the card covers. The table measures a card's height before
/// the card exists, so the header is a value both sides compute from the
/// same inputs.
struct ReviewCardHeader: Equatable {
    let title: String
    /// A saved comment's state: "Inserted" once it went to an agent, and
    /// empty before. `nil` on the composer, which has no label for one.
    var state: String?
    let detail: String

    /// The narrowest card the header fits on one line, added up the way
    /// the constraints lay it out: the title's inset, the title, the state
    /// label with the gap before it — there whether or not it says
    /// anything, since its constraint is — the gap before the position, the
    /// position, and its inset.
    var singleLineWidth: CGFloat {
        let metrics = ReviewRowMetrics.self
        var width = metrics.cardTitleLeading + metrics.labelWidth(title, font: metrics.cardTitleFont)
        if let state {
            width += metrics.cardStateGap + metrics.labelWidth(state, font: metrics.labelFont)
        }
        return width + metrics.cardHeaderGap + metrics.labelWidth(detail, font: metrics.cardDetailFont)
            + metrics.cardHeaderTrailing
    }

    /// Whether the position goes on a line of its own under the title. One
    /// line that could not wrap cut the position off: "Old 12 → new 14" in
    /// Japanese is wider than a narrow card has to spare beside the title.
    func wraps(inCardWidth width: CGFloat) -> Bool {
        singleLineWidth > width
    }
}

/// The two ways a card's header is laid out, switched as the card's width
/// changes. Shared by the saved comment and the composer, whose headers are
/// the same line.
@MainActor
private struct ReviewCardHeaderLayout {
    /// The position on the title's line, at its trailing end.
    private let inline: [NSLayoutConstraint]
    /// The position on a line of its own under the title, where the title
    /// starts.
    private let wrapped: [NSLayoutConstraint]
    private let position: NSTextField

    /// `leading` is the last view on the title's side of the line; `below`
    /// is what starts under the header.
    init(card: NSView, icon: NSView, leading: NSView, position: NSTextField, below: NSView) {
        let metrics = ReviewRowMetrics.self
        self.position = position
        inline = [
            position.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: metrics.cardHeaderGap),
            position.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -metrics.cardHeaderTrailing),
            position.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            below.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6)
        ]
        wrapped = [
            position.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: metrics.cardTitleLeading),
            position.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -metrics.cardHeaderTrailing),
            position.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: metrics.cardDetailLineGap),
            position.heightAnchor.constraint(equalToConstant: metrics.cardDetailLineHeight),
            below.topAnchor.constraint(equalTo: position.bottomAnchor, constant: 6)
        ]
        NSLayoutConstraint.activate(inline)
    }

    var isWrapped: Bool {
        wrapped.first?.isActive ?? false
    }

    func apply(wraps: Bool) {
        guard wraps != isWrapped else { return }
        if wraps {
            NSLayoutConstraint.deactivate(inline)
            NSLayoutConstraint.activate(wrapped)
        } else {
            NSLayoutConstraint.deactivate(wrapped)
            NSLayoutConstraint.activate(inline)
        }
        position.alignment = wraps ? .left : .right
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

    /// The card's width, set from the viewport. Just under required: a
    /// viewport too narrow for the card's fixed insets gives way to them
    /// rather than raising a constraint conflict, and the width still wins
    /// over every label's wish to be wider, which truncates instead.
    func makeWidthConstraint() -> NSLayoutConstraint {
        let width = widthAnchor.constraint(equalToConstant: 400)
        width.priority = NSLayoutConstraint.Priority(999)
        return width
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
            : SupervisionTokens.reviewCard.nsColor.cgColor
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

/// What a card needs from the table to place itself: the width the reader can
/// actually see, and the frozen strip it has to start clear of.
struct ReviewCardMetrics {
    let viewport: CGFloat
    let numberWidth: CGFloat
    /// Cards stay full width in both layouts, but where they start depends on
    /// the layout: they line up with the left column's code.
    let layout: ReviewDiffLayout
    /// How far the column is scrolled sideways: the left edge of what the
    /// reader can see, in the row's coordinates. A card is placed from it.
    /// Placed from the row's own edge, a card on a file with long lines
    /// slid out of view with the code, and its buttons went with it.
    var scrollOffset: CGFloat = 0

    /// The card's frame in the row: `ReviewRowMetrics.cardFrame` moved to
    /// the visible area.
    var frame: (leading: CGFloat, width: CGFloat) {
        let frame = ReviewRowMetrics.cardFrame(viewport: viewport, numberWidth: numberWidth, layout: layout)
        return (frame.leading + scrollOffset, frame.width)
    }
}

/// A saved comment, drawn under the last line of the run it covers, so it
/// stands beside the lines it is about rather than apart from them.
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
    /// Optional only because it is built from constraints that need the
    /// labels in the hierarchy first; set at the end of `init`.
    private var headerLayout: ReviewCardHeaderLayout?
    private var header = ReviewCardHeader(title: "", state: "", detail: "")

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
        icon.contentTintColor = SupervisionTokens.muted.nsColor
        card.addSubview(icon)
        for label in [title, position, body, state] {
            label.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(label)
        }
        state.font = ReviewRowMetrics.labelFont
        state.textColor = SupervisionTokens.muted.nsColor
        title.font = ReviewRowMetrics.cardTitleFont
        title.textColor = SupervisionTokens.muted.nsColor
        position.font = ReviewRowMetrics.cardDetailFont
        position.textColor = SupervisionTokens.muted.nsColor
        position.alignment = .right
        position.lineBreakMode = .byTruncatingTail
        body.font = ReviewRowMetrics.commentFont
        body.isSelectable = true
        // Titles are set in `configure`, not here: these rows are pooled, so
        // one built before a language switch would keep the old words.
        configure(button: resolveButton, action: #selector(resolve))
        configure(button: editButton, action: #selector(edit))
        configure(button: deleteButton, action: #selector(remove))
        editButton.contentTintColor = SupervisionTokens.muted.nsColor
        deleteButton.contentTintColor = SupervisionTokens.muted.nsColor
        installConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = ReviewRowMetrics.labelFont
        button.contentTintColor = ReviewRowPainter.accent
        button.target = self
        button.action = action
        card.addSubview(button)
    }

    private static func setTitle(_ button: NSButton, _ title: LocalizedStringResource, in locale: Locale) {
        button.title = title.resolved(in: locale)
        button.setAccessibilityLabel(button.title)
    }

    private func installConstraints() {
        // Width comes from the viewport rather than the row: the column is as
        // wide as the file's longest line, and a card that followed it put the
        // comment body on one endless line off the right edge.
        let width = card.makeWidthConstraint()
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
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ReviewRowMetrics.cardIconLeading),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: ReviewRowMetrics.cardIconSize),
            icon.heightAnchor.constraint(equalToConstant: ReviewRowMetrics.cardIconSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ReviewRowMetrics.cardIconGap),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            state.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: ReviewRowMetrics.cardStateGap),
            state.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -ReviewRowMetrics.cardHeaderTrailing),
            state.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            body.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: ReviewRowMetrics.commentBodyInset / 2
            ),
            body.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -ReviewRowMetrics.commentBodyInset / 2
            ),
            deleteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -12),
            resolveButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -12),
            // Inside the card however narrow it gets: the first button gives
            // up its words before any of them leaves the card.
            resolveButton.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 12),
            resolveButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            editButton.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 2),
            deleteButton.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
            editButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)
        ])
        resolveButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerLayout = ReviewCardHeaderLayout(card: card, icon: icon, leading: state, position: position, below: body)
    }

    /// The header a saved comment is drawn with, which the table measures the
    /// row's height from before the row is built.
    static func header(for comment: ReviewComment, locale: Locale) -> ReviewCardHeader {
        ReviewCardHeader(
            title: LocalizedStringResource("Comment").resolved(in: locale),
            state: comment.insertedAt == nil ? "" : LocalizedStringResource("Inserted").resolved(in: locale),
            detail: AgentStatusText.joined(
                [comment.file.layer.title.resolved(in: locale), comment.position(locale: locale)],
                locale: locale
            )
        )
    }

    /// Where the card sits in the row and how wide it is. Its own entry
    /// point as well as part of `configure`: a sideways scroll moves the
    /// card without anything about the comment changing.
    func place(_ metrics: ReviewCardMetrics) {
        let frame = metrics.frame
        cardLeading?.constant = frame.leading
        cardWidth?.constant = frame.width
        headerLayout?.apply(wraps: header.wraps(inCardWidth: frame.width))
    }

    /// `locale` is the table's, handed down on every reload, so a row taken
    /// from the pool after a language switch speaks the new language.
    func configure(_ comment: ReviewComment, metrics: ReviewCardMetrics, locale: Locale) {
        header = Self.header(for: comment, locale: locale)
        title.stringValue = header.title
        Self.setTitle(resolveButton, "Resolve", in: locale)
        Self.setTitle(editButton, "Edit", in: locale)
        Self.setTitle(deleteButton, "Delete", in: locale)
        position.stringValue = header.detail
        body.stringValue = comment.body
        state.stringValue = header.state ?? ""
        place(metrics)
        // Re-applied rather than left from construction: these rows are pooled,
        // so one built under the previous accent comes back tinted with it.
        // Only Resolve, the card's main action, takes the accent; Edit and
        // Delete step back in `muted`. Delete is not drawn as destructive: it
        // drops a comment, not anything in the person's files.
        resolveButton.contentTintColor = ReviewRowPainter.accent
        // The card is read from its body: the heading, the place in words,
        // and the state as its label, the comment as its value. The drawn
        // header's " · " and "→" would be read as symbols, so its fields
        // stay out of VoiceOver's way.
        for field in [title, position, state] {
            field.setAccessibilityElement(false)
        }
        body.setAccessibilityLabel(AgentStatusText.spokenList(
            [
                header.title,
                comment.file.layer.title.resolved(in: locale),
                comment.spokenPosition(locale: locale),
                state.stringValue
            ],
            locale: locale
        ))
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
    /// Told whether an input method has unfinished text in the comment, as
    /// it starts and as it ends.
    var onInputMethodText: ((Bool) -> Void)?
    private var cardWidth: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?
    /// Optional only because it is built from constraints that need the
    /// labels in the hierarchy first; set at the end of `init`.
    private var headerLayout: ReviewCardHeaderLayout?
    /// Kept so a resize, which has no line to rebuild it from, can decide
    /// again whether the position fits beside the title.
    private(set) var header = ReviewCardHeader(title: "", detail: "")

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
        title.font = ReviewRowMetrics.cardTitleFont
        position.font = ReviewRowMetrics.cardDetailFont
        position.textColor = SupervisionTokens.muted.nsColor
        position.alignment = .right
        position.lineBreakMode = .byTruncatingTail
        placeholder.font = ReviewRowMetrics.commentFont
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.textColor = SupervisionTokens.muted.nsColor
        textView.font = ReviewRowMetrics.commentFont
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.onCompositionChanged = { [weak self] in self?.updateEnabled() }
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        field.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(field)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        field.addSubview(scroll)
        card.isActive = true
        // Every word on the card is set in `configure`, which runs again after
        // a language switch; the composer lives as long as the table does.
        style(cancelButton, action: #selector(cancel))
        cancelButton.bezelStyle = .inline
        cancelButton.isBordered = false
        cancelButton.contentTintColor = SupervisionTokens.muted.nsColor
        style(addButton, action: #selector(commit))
        addButton.bezelStyle = .rounded
        installConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func style(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .small
        button.font = ReviewRowMetrics.labelFont
        button.target = self
        button.action = action
        card.addSubview(button)
    }

    private func installConstraints() {
        let width = card.makeWidthConstraint()
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
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: ReviewRowMetrics.cardIconLeading),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: ReviewRowMetrics.cardIconSize),
            icon.heightAnchor.constraint(equalToConstant: ReviewRowMetrics.cardIconSize),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: ReviewRowMetrics.cardIconGap),
            title.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -ReviewRowMetrics.cardHeaderTrailing),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            field.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: ReviewRowMetrics.composerTextInset / 2 - ReviewRowMetrics.composerFieldPadding
            ),
            field.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -(ReviewRowMetrics.composerTextInset / 2 - ReviewRowMetrics.composerFieldPadding)
            ),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -4),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 2),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -4),
            addButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -10),
            // Inside the card however narrow it gets: Cancel gives up its
            // word before Add, which is what the card is for, leaves it.
            cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 10),
            cancelButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            addButton.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        cancelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerLayout = ReviewCardHeaderLayout(card: card, icon: icon, leading: title, position: position, below: field)
    }

    /// The header the composer is drawn with for this run, which the table
    /// measures the row's height from before it configures the row.
    static func header(line: ReviewLine, start: ReviewLine?, isEditing: Bool, locale: Locale) -> ReviewCardHeader {
        // Both headings name the action, so they read as a pair rather than as
        // one action and one noun.
        let heading: LocalizedStringResource = isEditing ? "Edit comment" : "Add comment"
        let first = start ?? line
        return ReviewCardHeader(
            title: heading.resolved(in: locale),
            detail: ReviewComment.position(
                oldStart: first.oldLine,
                oldEnd: line.oldLine,
                newStart: first.newLine,
                newEnd: line.newLine,
                locale: locale
            )
        )
    }

    /// Take a new width, or a new place after a sideways scroll, without
    /// being rebuilt. The composer is one instance that holds live text and
    /// first responder, so a viewport change has to reach it this way rather
    /// than through a reload.
    func resize(to metrics: ReviewCardMetrics) {
        let frame = metrics.frame
        cardLeading?.constant = frame.leading
        cardWidth?.constant = frame.width
        headerLayout?.apply(wraps: header.wraps(inCardWidth: frame.width))
    }

    /// `start` is the first line of the run when more than one line is
    /// selected; the composer is always drawn under the last one. `locale`
    /// is the table's: the composer outlives a language switch, so every
    /// word on it is set here rather than once at construction.
    func configure( // swiftlint:disable:this function_parameter_count
        _ line: ReviewLine,
        start: ReviewLine?,
        text: String,
        isEditing: Bool,
        metrics: ReviewCardMetrics,
        locale: Locale
    ) {
        header = Self.header(line: line, start: start, isEditing: isEditing, locale: locale)
        resize(to: metrics)
        // The composer is one long-lived view rather than a pooled row, so
        // nothing else would ever put a new accent on it.
        icon.contentTintColor = ReviewRowPainter.accent
        title.stringValue = header.title
        // A hint, not a question: a form that asks the reader something reads
        // as waiting for an answer, and a comment is as often an observation
        // or a question of its own as it is a change request.
        placeholder.stringValue = LocalizedStringResource("Leave a comment").resolved(in: locale)
        textView.setAccessibilityLabel(LocalizedStringResource("Review comment").resolved(in: locale))
        cancelButton.title = LocalizedStringResource("Cancel").resolved(in: locale)
        cancelButton.setAccessibilityLabel(cancelButton.title)
        // The button says only the verb: the card it sits in holds one comment
        // and says so directly above, and the object repeated just below
        // the heading that already carried it read as boilerplate. The
        // full phrase stays on the button for anyone reading it out of that
        // context.
        let verb: LocalizedStringResource = isEditing ? "Save" : "Add"
        addButton.title = verb.resolved(in: locale)
        // Spoken as well as drawn: set once at construction, VoiceOver went on
        // calling it Add while it said Save.
        addButton.setAccessibilityLabel(addButton.title)
        let phrase: LocalizedStringResource = isEditing ? "Save Comment" : "Add Comment"
        addButton.setAccessibilityTitle(phrase.resolved(in: locale))
        position.stringValue = header.detail
        // The run in words; a static text is read from its value.
        position.setAccessibilityValue(ReviewComment.spokenPosition(
            oldStart: (start ?? line).oldLine,
            oldEnd: line.oldLine,
            newStart: (start ?? line).newLine,
            newEnd: line.newLine,
            locale: locale
        ))
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
        onInputMethodText?(textView.hasMarkedText())
    }

    func textViewDidChangeSelection(_: Notification) {
        // An input method's text ends without changing the text when it is
        // given up: the caret moves.
        onInputMethodText?(textView.hasMarkedText())
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
