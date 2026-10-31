// ReviewDiffTable.swift
// Weir — reusable AppKit rows for large review diffs, including comments.

import AppKit
import SwiftUI

/// Keys the table handles itself so a review can be completed without the
/// pointer. The rest of the app is driven from the keyboard; this was the one
/// surface that insisted on clicking.
enum ReviewTableKey {
    case nextLine, previousLine
    case extendNextLine, extendPreviousLine
    case nextHunk, previousHunk
    case nextFile, previousFile
    /// Move the cursor between the two columns of the split layout.
    case oldSide, newSide
    case comment, close, insert
    /// Mark the open file read, or put it back.
    case markViewed
    /// Open the file in the app chosen for files, at the top of the
    /// selection, or at the file's first change when nothing is selected.
    case openInEditor

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.namedKey == .return {
            self = .insert
            return
        }
        if event.namedKey == .escape {
            self = .close
            return
        }
        if let arrow = Self.arrow(event, modifiers: modifiers) {
            self = arrow
            return
        }
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              let characters = event.charactersIgnoringModifiers,
              let key = Self.byCharacter[characters]
        else { return nil }
        self = key
    }

    /// ↑ / ↓ as the line keys, with Shift extending. Left to `NSTableView`
    /// they were a second way of moving that knew nothing of dragged text,
    /// and after a drag they started over at the file's first or last line.
    private static func arrow(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> ReviewTableKey? {
        guard modifiers.isEmpty || modifiers == .shift else { return nil }
        let isExtending = modifiers == .shift
        switch event.namedKey {
        case .down: return isExtending ? .extendNextLine : .nextLine
        case .up: return isExtending ? .extendPreviousLine : .previousLine
        default: return nil
        }
    }

    /// Shift is the only modifier `charactersIgnoringModifiers` keeps, so the
    /// extending pair arrives here as capitals. Internal so a test can hold
    /// the shortcut sheet to these keys.
    static let byCharacter: [String: ReviewTableKey] = [
        "j": .nextLine, "k": .previousLine,
        "J": .extendNextLine, "K": .extendPreviousLine,
        "]": .nextHunk, "[": .previousHunk,
        "h": .oldSide, "l": .newSide,
        "n": .nextFile, "p": .previousFile,
        "c": .comment,
        "v": .markViewed,
        "o": .openInEditor
    ]
}

/// The rows carry their own background and their own selection, so AppKit's
/// separator draws a second line through a diff that already reads as lines.
final class ReviewTableRowView: NSTableRowView {
    override func drawSeparator(in _: NSRect) {}
}

/// `NSTableView`'s own key handling is type-select, which would swallow the
/// single letters above before they reach us.
final class ReviewTableView: NSTableView {
    var onKey: ((ReviewTableKey) -> Bool)?
    var onCopyCode: (() -> Bool)?
    /// The title of the context menu's open item for the row that was
    /// right-clicked, or nil when there is nothing to open. Asked per menu so
    /// it names the app chosen now and the line the editor will land on.
    var openInEditorTitle: ((Int) -> String?)?
    var onOpenInEditor: ((Int?) -> Void)?
    /// The language the context menu is written in: the representable's
    /// `locale`, handed in when it makes the table and set again when it
    /// changes. Required at init, so no table can show a menu in a
    /// language nobody chose.
    var menuLocale: Locale
    /// The row the context menu was built for.
    private var menuRow: Int?
    var hasTextSelection: (() -> Bool)?
    /// Whether a row lies inside the text the reader dragged over.
    var textSelectionCovers: ((Int) -> Bool)?
    var textPosition: ((NSPoint, ReviewTextPosition?) -> ReviewTextPosition?)?
    /// A press on code that did not become a drag. Lines are picked in the
    /// gutter and code is for reading and copying, so this only lets go of
    /// the line selection rather than choosing the line under the pointer.
    /// Returns whether it did; an open composer keeps its lines.
    var onCodePress: (() -> Bool)?
    var onTextSelection: ((ReviewTextSelection) -> Void)?
    var onSelectTextUnit: ((ReviewTextPosition, Int) -> Void)?
    var hidesAccessibilityTree = false
    /// Asked to scroll both code columns sideways. Returns whether it took the
    /// event; the split layout has no horizontal scroll of its own to fall
    /// back on.
    var onScrollCode: ((CGFloat) -> Bool)?
    /// A notch of a mouse wheel or a page key, which scroll without the
    /// live-scroll notifications a trackpad or the scroller sends.
    var onScrollStep: (() -> Void)?
    /// A context menu's items for a row that is not code (a file's header).
    var headerMenuItems: ((Int) -> [NSMenuItem])?
    /// Where the last press landed, in table coordinates. `NSTableView`
    /// selects whole rows, and a row of the split layout is two columns wide —
    /// this is what tells the two apart.
    ///
    /// Cleared by the next key, because it answers for the pointer only: a
    /// stale press was still deciding the column for the keyboard long after
    /// it happened.
    private(set) var lastClickX: CGFloat?
    private var textDragAnchor: ReviewTextPosition?
    private var textDragOrigin: NSPoint?
    private var didDragText = false
    private var latestTextDragEvent: NSEvent?
    /// `nonisolated(unsafe)` permits `deinit` to invalidate the RunLoop timer.
    /// Every write occurs in MainActor-isolated mouse handling, and `deinit`
    /// runs only after those handlers have released the table.
    private nonisolated(unsafe) var textAutoscrollTimer: Timer?
    private var consumesMouseUp = false

    init(frame: NSRect, menuLocale: Locale) {
        self.menuLocale = menuLocale
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func accessibilityChildren() -> [Any]? {
        hidesAccessibilityTree ? [] : super.accessibilityChildren()
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        hidesAccessibilityTree ? [] : super.accessibilityVisibleChildren()
    }

    override func mouseDown(with event: NSEvent) {
        stopTextAutoscroll()
        lastClickX = convert(event.locationInWindow, from: nil).x
        let point = convert(event.locationInWindow, from: nil)
        guard let position = textPosition?(point, nil) else {
            onTextSelection?(ReviewTextSelection())
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if event.clickCount > 1 {
            consumesMouseUp = true
            onSelectTextUnit?(position, event.clickCount)
            return
        }
        textDragAnchor = position
        textDragOrigin = point
        didDragText = false
        onTextSelection?(ReviewTextSelection(anchor: position, head: position))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = textDragAnchor, let origin = textDragOrigin else {
            super.mouseDragged(with: event)
            return
        }
        updateTextDrag(with: event, anchor: anchor, origin: origin)
        latestTextDragEvent = event
        if textAutoscrollTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let anchor = self.textDragAnchor,
                          let origin = self.textDragOrigin,
                          let event = self.latestTextDragEvent
                    else { return }
                    self.updateTextDrag(with: event, anchor: anchor, origin: origin)
                }
            }
            textAutoscrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateTextDrag(with event: NSEvent, anchor: ReviewTextPosition, origin: NSPoint) {
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 2,
              let head = textPosition?(point, anchor)
        else { return }
        didDragText = true
        var selection = ReviewTextSelection()
        selection.select(from: anchor, to: head)
        onTextSelection?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        if consumesMouseUp {
            consumesMouseUp = false
            return
        }
        guard textDragAnchor != nil else {
            super.mouseUp(with: event)
            return
        }
        if !didDragText {
            _ = onCodePress?()
        }
        textDragAnchor = nil
        textDragOrigin = nil
        didDragText = false
        stopTextAutoscroll()
    }

    private func stopTextAutoscroll() {
        textAutoscrollTimer?.invalidate()
        textAutoscrollTimer = nil
        latestTextDragEvent = nil
    }

    deinit {
        textAutoscrollTimer?.invalidate()
    }

    override func scrollWheel(with event: NSEvent) {
        // A deliberate sideways gesture, and only when the split layout has
        // somewhere to go: everything else is the scroll view's. The margin
        // matters — a vertical flick reports a little sideways drift as it
        // starts and as it decays, and taking those events stalled the
        // vertical scroll for a frame at each end.
        let sideways = abs(event.scrollingDeltaX)
        let vertical = abs(event.scrollingDeltaY)
        if sideways > 1, sideways > vertical * 2, onScrollCode?(event.scrollingDeltaX) == true {
            return
        }
        super.scrollWheel(with: event)
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            onScrollStep?()
        }
    }

    override func scrollPageDown(_ sender: Any?) {
        super.scrollPageDown(sender)
        onScrollStep?()
    }

    override func scrollPageUp(_ sender: Any?) {
        super.scrollPageUp(sender)
        onScrollStep?()
    }

    override func pageDown(_ sender: Any?) {
        super.pageDown(sender)
        onScrollStep?()
    }

    override func pageUp(_ sender: Any?) {
        super.pageUp(sender)
        onScrollStep?()
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        super.scrollToBeginningOfDocument(sender)
        onScrollStep?()
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        super.scrollToEndOfDocument(sender)
        onScrollStep?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The key the context menu's Copy item shows, from the same constant.
        if window?.firstResponder === self, StandardEditShortcut.copy.isPressed(in: event) {
            return onCopyCode?() ?? false
        }
        guard window?.firstResponder === self, event.type == .keyDown,
              let key = ReviewTableKey(event: event), key == .insert
        else {
            return super.performKeyEquivalent(with: event)
        }
        return onKey?(key) ?? false
    }

    override func keyDown(with event: NSEvent) {
        lastClickX = nil
        if let key = ReviewTableKey(event: event), onKey?(key) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        menuRow = clicked >= 0 ? clicked : nil
        // A right-click inside the line selection or the dragged text keeps
        // it, so every item acts on what the reader can see highlighted.
        // Outside both, it does what a left click there would: in the gutter
        // it selects the line, on code it lets go of both selections. Either
        // way nothing stale is left for Copy to act on. An open composer
        // keeps its lines, and those are not the line under the pointer that
        // Open names, so Copy Code is left out rather than copy them.
        var offersLineCopy = true
        if clicked >= 0, !selectedRowIndexes.contains(clicked),
           textSelectionCovers?(clicked) != true
        {
            onTextSelection?(ReviewTextSelection())
            if textPosition?(point, nil) != nil {
                if onCodePress?() == true {
                    deselectAll(nil)
                } else {
                    offersLineCopy = false
                }
            } else if delegate?.tableView?(self, shouldSelectRow: clicked) ?? true {
                lastClickX = point.x
                selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
        }
        if let menuRow {
            for item in headerMenuItems?(menuRow) ?? [] {
                menu.addItem(item)
            }
        }
        if let menuRow, let title = openInEditorTitle?(menuRow) {
            let open = NSMenuItem(title: title, action: #selector(openRowInEditor(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        if (offersLineCopy && !selectedRowIndexes.isEmpty) || hasTextSelection?() == true {
            let copyTitle: LocalizedStringResource = hasTextSelection?() == true ? "Copy Selected Text" : "Copy Code"
            let copy = NSMenuItem(
                title: copyTitle.resolved(in: menuLocale),
                action: #selector(copySelectedCode(_:)),
                keyEquivalent: ""
            )
            // The Edit menu's Copy key, which `performKeyEquivalent` answers
            // with this same copy while the table has focus.
            copy.showShortcut(StandardEditShortcut.copy)
            copy.target = self
            menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func copySelectedCode(_: Any?) {
        _ = onCopyCode?()
    }

    @objc private func openRowInEditor(_: Any?) {
        guard let menuRow else { return }
        onOpenInEditor?(menuRow)
    }
}

/// AppKit exposes a representable's document view independently of SwiftUI's
/// accessibility modifiers, so the compact drawer needs a native boundary that
/// can suppress and restore the diff hierarchy without mutating AppKit's cache.
final class ReviewScrollView: NSScrollView {
    var hidesAccessibilityTree = false

    override func accessibilityChildren() -> [Any]? {
        hidesAccessibilityTree ? [] : super.accessibilityChildren()
    }

    override func accessibilityVisibleChildren() -> [Any]? {
        hidesAccessibilityTree ? [] : super.accessibilityVisibleChildren()
    }
}

/// A request to put a file's header at the top of the stacked diff. The
/// serial tells two requests for the same file apart.
struct ReviewStackScroll: Equatable {
    var fileID: String?
    var serial = 0
}

struct ReviewDiffTable: NSViewRepresentable {
    /// Every file of the range, file under file: the rows, and which
    /// file each row belongs to. The one place the table takes its rows
    /// from, so what it draws and what it says a row's file is cannot
    /// disagree.
    let stack: ReviewStack
    /// The open file's patch, for the one question rows cannot answer
    /// cheaply: which changed block a line of it belongs to.
    let diffLines: [ReviewLine]
    /// Cheap stand-in for comparing the row list itself. `updateNSView` runs on
    /// every observable change in the surrounding view, and diffing up to
    /// 100,000 rows there would cost more than the reload it avoids.
    let contentKey: String
    /// The subset of `contentKey` the column's width depends on. See
    /// `ReviewWorkspaceView.widthKey`.
    let widthKey: String
    /// Unified, or the old file beside the new one. The rows arrive already
    /// built for it; the table needs it for row heights, column width and
    /// which half of a split row a click landed in.
    let layout: ReviewDiffLayout
    /// The ordered change list, which `n` / `p` walk.
    let files: [ReviewFile]
    /// One gutter for every file, as wide as the largest line number the
    /// range has needed (`ReviewWorkspaceView.highestLine`): it does not
    /// narrow for a short file.
    let numberWidth: CGFloat
    let expandedFileID: String?
    /// False while a replacement snapshot is loading. The SwiftUI hit-test
    /// gate does not stop an already-focused `NSTableView` receiving keys.
    var isInteractionEnabled = true
    /// The line run and the dragged text. Changed only through its own
    /// methods, which keep one of the two on screen at a time.
    @Binding var selection: ReviewDiffSelection
    /// Read only: every transition goes through `onCompose` / `onCancelCompose`
    /// so the workspace can keep the edit target in step with the line.
    let composerLineID: Int?
    /// First line of the run the composer covers, when it covers more than one.
    let composerStartLine: ReviewLine?
    /// Whether the composer is rewriting a saved comment, which is what its
    /// title and its button say.
    let composerIsEditing: Bool
    @Binding var composerText: String
    let onSelectFile: (ReviewFile) -> Void
    /// Opening and canceling the composer go through the workspace rather than
    /// this binding: the workspace also holds whether the composer is editing an
    /// existing comment, and inferring that from the line alone got it wrong.
    /// It reads the selection for the run to comment on.
    let onCompose: () -> Void
    let onCancelCompose: () -> Void
    let onCommit: () -> Void
    let onInsert: () -> Void
    /// The find bar's state. The query is what the rows mark, and it is
    /// deliberately not part of `contentKey`: the row list does not change
    /// with it, and rebuilding a hundred thousand rows per keystroke is what
    /// the key exists to prevent.
    let search: ReviewSearch
    /// Escape belongs to the find bar while it is up, wherever the focus sits.
    let onCloseSearch: () -> Void
    /// The line the current match is on, which is scrolled to on its own
    /// rather than through the selection: a match can land on an unfolded
    /// line, and the cursor cannot rest on one.
    let searchTargetLineID: Int?
    /// The language the open file is written in, resolved once by the surface
    /// rather than per row: it depends only on the path.
    let language: ReviewSyntax.Language?
    /// Toggles the open file's read mark. Here rather than only in the list
    /// because that is where the reader is when they finish a file.
    let onToggleViewed: () -> Void
    /// Raised when the surface comes back in front (the review tab, from
    /// behind a terminal tab), so the diff takes the keyboard again as it
    /// does when it first opens.
    var focusRequest = 0
    /// The app files open in, which the open item names.
    let fileApplication: FileApplicationResolution
    /// Opens a file at a line of its new side: the row's file in the stacked
    /// diff, `nil` for the open one. The table works out the line; the
    /// surface knows the repository and the app.
    let onOpenLine: (Int, String?) -> Void
    /// Unfolds part of one gap. The review session owns how much is showing; this only
    /// says which gap the reader pressed and which way.
    let onExpand: (Int, ReviewGapAction) -> Void
    let onResolve: (ReviewComment) -> Void
    let onEdit: (ReviewComment) -> Void
    let onDelete: (ReviewComment) -> Void
    /// What each hunk's header offers, by the header's line id: the
    /// review tab's "Discard". Handed in as values, worked out where the
    /// window's state is observed, so a discard or a change of the gate
    /// updates the table; a header with no entry offers nothing.
    var hunkActions: [Int: ReviewHunkAction] = [:]
    /// A hunk's buttons, with the file the hunk belongs to in the stacked
    /// diff (`nil` for the open file).
    var onDiscardHunk: (ReviewLine, String?) -> Void = { _, _ in }
    var onUndoDiscard: (ReviewLine, String?) -> Void = { _, _ in }
    /// "Comment" on a hunk header: a comment on the hunk's changed lines.
    var onCommentHunk: (ReviewLine, String?) -> Void = { _, _ in }
    /// How opaque the surface the stacked diff stands on is filled
    /// (`supervisionSurfaceOpacity`), which its file and hunk headers take
    /// so they do not stand out as opaque bands with transparency on. The
    /// headers are AppKit rows, and SwiftUI's environment stops at the
    /// table. A change reaches each header as it is next configured.
    var surfaceOpacity: Double = 1
    /// Puts a file's header at the top of the stacked diff.
    var scrollRequest = ReviewStackScroll()
    /// Where the review tab's stacked diff was scrolled as the tab went
    /// with its project, put back once, as soon as the file it
    /// names has been read again (`Coordinator.applyStackRestore`). The
    /// table is made only once the surface's first read has listed the
    /// range again, so a file the place names and the list lacks is gone,
    /// not unlisted yet.
    var stackRestore: ReviewScrollAnchor?
    /// Told once `stackRestore` is put back, or given up for the reader's
    /// own move.
    var onStackRestored: () -> Void = {}
    /// Handed, as the table is made, a way to read where the stacked diff
    /// is scrolled (`ProjectWindowState.readReviewScroll`).
    var onScrollReader: ((@escaping @MainActor () -> ReviewScrollAnchor?) -> Void)?
    /// Asked for the diffs of the stacked files about to be on screen.
    var onNeedDiffs: ([String]) -> Void = { _ in }
    /// Whether an input method has unfinished text in the composer.
    var onComposerInputMethodText: (Bool) -> Void = { _ in }
    /// The stacked file the reader has scrolled to, once they stop.
    var onReadingFile: (String) -> Void = { _ in }
    /// A file's checkbox in its header.
    var onToggleFileViewed: (String) -> Void = { _ in }
    /// A checked file's chevron in its header, or a click on the header.
    var onToggleFileFold: (String) -> Void = { _ in }
    /// The worktree the files are in, for a file header's context menu.
    var root: URL?
    /// A transient rail sits above the table and therefore owns Escape before
    /// the composer, find bar, or Review surface beneath it.
    let isOverlayPresented: Bool
    let onCloseOverlay: () -> Void
    let onClose: () -> Void
    /// The language the rows and the context menu are written in: the
    /// pane's `\.locale`, handed in rather than read here because the rows
    /// are AppKit, configured outside SwiftUI's environment, and the
    /// coordinator reads it whenever AppKit asks for a row.
    let locale: Locale
    /// Read here and handed to the painter: the rows are AppKit, and the
    /// system accent they used instead is not the one the picker sets.
    @Environment(\.weirAccent) private var accent

    /// The stack's rows, which the table draws.
    var rows: [ReviewRow] {
        stack.rows
    }

    /// Every drawn file's character highlights, keyed by the ids the rows
    /// carry.
    var intralineHighlights: ReviewIntralineHighlights {
        stack.intralineHighlights
    }

    /// Every drawn file's comment markers, keyed by the ids the rows carry.
    var lineCommentCounts: [Int: Int] {
        stack.commentCounts
    }

    /// The hunk headers, by line id, whose hunk has lines to comment on.
    var commentableHunks: Set<Int> {
        stack.commentableHunks
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ReviewScrollView {
        let table = ReviewTableView(frame: .zero, menuLocale: locale)
        table.headerView = nil
        // Plain, and with no inset of its own: the surface supplies the
        // padding, and the automatic style added a strip above the first row.
        table.style = .plain
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        // The surface behind supplies the color. Left at the default, the
        // table painted `controlBackgroundColor` over it and the diff sat on a
        // different shade from the strip beside it.
        table.backgroundColor = .clear
        table.rowHeight = ReviewRowMetrics.code
        table.intercellSpacing = .zero
        // The diff carries its own color, and a system-blue highlight over a
        // green or red row reads as a third kind of change. The row draws its
        // own selection instead.
        table.selectionHighlightStyle = .none
        // A comment covers a run of lines, so the table has to be able to
        // carry one: shift-click and shift-drag are the pointer half of ⇧J/⇧K.
        table.allowsMultipleSelection = true
        table.usesAutomaticRowHeights = false
        table.setAccessibilityLabel(LocalizedStringResource("Review diff").resolved(in: locale))
        let column = NSTableColumn(identifier: .init("review"))
        // The one column is sized by hand, from the viewport and the file's
        // longest line. Left to AppKit, `.lastColumnOnlyAutoresizingStyle`
        // resizes it on every table frame change — including the narrow
        // intermediate passes SwiftUI lays out through — and the column stayed
        // at that width. The rows then drew inside a strip narrower than the
        // frozen gutter that covers it, which read as a diff with line numbers
        // and no code.
        column.resizingMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.onKey = { [weak coordinator = context.coordinator] key in
            coordinator?.handle(key) ?? false
        }
        table.onCopyCode = { [weak coordinator = context.coordinator] in
            coordinator?.copySelectedCode() ?? false
        }
        table.openInEditorTitle = { [weak coordinator = context.coordinator] row in
            coordinator?.openInEditorTitle(clickedRow: row)
        }
        table.onOpenInEditor = { [weak coordinator = context.coordinator] row in
            coordinator?.openInEditor(clickedRow: row)
        }
        table.hasTextSelection = { [weak coordinator = context.coordinator] in
            coordinator?.parent.selection.text.isEmpty == false
        }
        table.textSelectionCovers = { [weak coordinator = context.coordinator] row in
            coordinator?.parent.selection.text.rowRange?.contains(row) == true
        }
        table.textPosition = { [weak coordinator = context.coordinator, weak table] point, anchor in
            guard let coordinator, let table else { return nil }
            return coordinator.textPosition(at: point, continuingFrom: anchor, in: table)
        }
        table.onCodePress = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.parent.selection.pressCode(keepsLines: coordinator.isComposing)
        }
        table.onTextSelection = { [weak coordinator = context.coordinator] selection in
            guard let coordinator else { return }
            coordinator.parent.selection.selectText(selection, keepsLines: coordinator.isComposing)
        }
        table.onSelectTextUnit = { [weak coordinator = context.coordinator] position, clickCount in
            coordinator?.selectTextUnit(at: position, clickCount: clickCount)
        }
        table.onScrollCode = { [weak coordinator = context.coordinator, weak table] delta in
            guard let table else { return false }
            return coordinator?.scrollCode(by: delta, in: table) ?? false
        }
        table.onScrollStep = { [weak coordinator = context.coordinator] in
            coordinator?.noteScrollStep()
        }
        table.headerMenuItems = { [weak coordinator = context.coordinator] row in
            coordinator?.headerMenuItems(forRow: row) ?? []
        }
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openComposerFromDoubleClick(_:))
        let scroll = ReviewScrollView()
        // Otherwise AppKit reserves room for a title bar that is not there,
        // which showed as a gap above the first line of every file.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        // Line numbers stay put while the diff scrolls sideways for a long
        // line: `addFloatingSubview` is AppKit's frozen-column mechanism, and
        // without it the reader loses their place in the file.
        let gutter = context.coordinator.gutter
        gutter.table = table
        // Selecting a run and having a composer appear under it was too eager:
        // a run is often selected to read it. The marker is the invitation.
        gutter.onAddComment = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCompose()
        }
        scroll.addFloatingSubview(gutter, for: .horizontal)
        // The gutter is as tall as the document, and since macOS 14 a view
        // does not clip its subviews by default — without this it paints over
        // the footer below the scroll view.
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        context.coordinator.observeScroll(of: scroll)
        context.coordinator.observeViewport(of: scroll)
        context.coordinator.observeLiveScroll(of: scroll)
        // Read as the tab goes, not as it scrolls: nothing is written per
        // scroll event. A place still to be put back is where the tab
        // stands: the tab can go again before its file is read.
        if let onScrollReader {
            onScrollReader { [weak coordinator = context.coordinator, weak scroll, weak table] in
                guard let coordinator, let scroll, let table else { return nil }
                return coordinator.pendingStackRestore ?? coordinator.anchor(in: scroll, table: table)
            }
        }
        // Review opens for reading, so the diff takes the keyboard. The origin
        // pane below declines the mount grab while review is presented.
        DispatchQueue.main.async { [weak table] in
            guard let table, let window = table.window else { return }
            window.makeFirstResponder(table)
        }
        return scroll
    }

    func updateNSView(_ scroll: ReviewScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        let previousKey = coordinator.appliedKey
        // SwiftUI's accessibilityHidden modifier does not cross the
        // NSViewRepresentable boundary. Keep the native hierarchy out of
        // VoiceOver while the compact file drawer owns this surface.
        scroll.hidesAccessibilityTree = isOverlayPresented
        scroll.setAccessibilityHidden(isOverlayPresented)
        guard let table = scroll.documentView as? ReviewTableView else { return }
        // A comment being written keeps the keyboard where it is: in the
        // table, its letters would be the table's keys.
        if coordinator.appliedFocusRequest != focusRequest, composerLineID == nil {
            coordinator.appliedFocusRequest = focusRequest
            DispatchQueue.main.async { [weak table] in
                guard let table, let window = table.window else { return }
                window.makeFirstResponder(table)
            }
        }
        table.hidesAccessibilityTree = isOverlayPresented
        table.setAccessibilityHidden(isOverlayPresented)
        coordinator.gutter.setAccessibilityHidden(isOverlayPresented)
        // Taken while the coordinator still holds the previous rows:
        // unfolding a gap inserts rows above what is on screen, and the code
        // the reader was reading must not slide away under them. The anchor
        // names the file as well as the line, and the diff the line was read
        // in, so it holds across a file being opened, closed, or read in
        // above, and a refresh that renumbers a file's rows does not put the
        // reader in front of other code (`ReviewStack.anchorKey`).
        let anchor = coordinator.anchor(in: scroll, table: table)
        coordinator.parent = self
        ReviewRowPainter.setAccent(accent)
        // Per table, not per process: two windows both have to redraw, and the
        // second one to update would otherwise be told the accent was already
        // current. Rows that take their tint when they are built are pooled,
        // so this is a reload rather than a redraw.
        let hasNewAccent = coordinator.appliedAccent != accent
        coordinator.appliedAccent = accent
        if hasNewAccent {
            coordinator.invalidateGutter()
        }
        // The same reload for a language switch: the rows resolve their words
        // when they are configured, and pooled ones keep them until then.
        let hasNewLocale = coordinator.appliedLocale != locale
        coordinator.appliedLocale = locale
        if hasNewLocale {
            table.menuLocale = locale
            table.setAccessibilityLabel(LocalizedStringResource("Review diff").resolved(in: locale))
        }
        // Side by side sizes its column to the viewport, so there is nothing
        // to scroll to and a scroller would sit there permanently disabled.
        scroll.hasHorizontalScroller = layout == .unified
        if previousKey != contentKey || table.numberOfRows != rows.count || hasNewAccent || hasNewLocale {
            let hadComposer = coordinator.hasComposerRow
            coordinator.appliedKey = contentKey
            coordinator.applyColumnWidth(to: table)
            coordinator.prepareComposerForReload(in: table)
            table.reloadData()
            if let anchor {
                coordinator.restore(anchor, in: scroll, table: table)
            }
            if hadComposer, composerLineID == nil {
                table.window?.makeFirstResponder(table)
            }
        }
        // Typing does not change `contentKey` — reloading the row would take
        // the keyboard away mid-sentence — so the height is nudged on its own.
        // Which row to nudge is found when the row list changes, not on every
        // character: the composer sits wherever the reader was reading, and
        // the search for it walked the whole diff.
        if coordinator.appliedComposerKey != contentKey {
            coordinator.appliedComposerKey = contentKey
            coordinator.composerRowIndex = composerLineID.flatMap { lineID in
                rows.firstIndex {
                    if case let .composer(line) = $0.kind {
                        return line.id == lineID
                    }
                    return false
                }
            }
        }
        if composerLineID != nil,
           let index = coordinator.composerRowIndex,
           index < table.numberOfRows,
           rows.indices.contains(index),
           case let .composer(line) = rows[index].kind
        {
            let height = coordinator.composerHeight(for: line, in: table)
            if abs(coordinator.appliedComposerHeight - height) > 0.5 {
                coordinator.appliedComposerHeight = height
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            }
        }
        coordinator.applyFileChange(in: scroll, table: table)
        // A narrower window, or a switch back to unified, can leave the code
        // scrolled past where it can go.
        coordinator.refreshSearch(in: table, scroll: scroll)
        coordinator.clampCodeOffset(in: table)
        coordinator.syncSelection(in: table)
        coordinator.syncTextSelection(in: table)
        coordinator.focusComposerIfNeeded(in: table)
        coordinator.refreshGutter(in: table)
        coordinator.refreshHunkActions(in: table)
        coordinator.refreshHeaderFills(in: table)
    }
}
