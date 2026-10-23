// ReviewDiffTableCoordinator+Stack.swift
// Limpid — the table's side of the review tab's stacked diff: which file a row is in, reading ahead, and following the reader.

import AppKit

extension ReviewDiffTable.Coordinator {
    /// A file's header row in the stacked diff, as wide as what the reader
    /// sees, with its checkbox, and a checked file's chevron.
    func fileHeaderRow(_ tableView: NSTableView, header: ReviewStackHeader) -> NSView {
        let view = reuse(tableView, "review-file", ReviewFileHeaderRowView.init)
        configure(view, header: header, in: tableView)
        return view
    }

    private func configure(_ view: ReviewFileHeaderRowView, header: ReviewStackHeader, in tableView: NSTableView) {
        let fileID = header.file.id
        let content = ReviewStackFileHeader(
            header: header,
            onToggleViewed: { [weak self] in
                self?.parent.onToggleFileViewed(fileID)
            },
            onToggleFold: { [weak self] in
                self?.parent.onToggleFileFold(fileID)
            }
        )
        view.configure(content, in: hostedEnvironment, width: visibleWidth(of: tableView))
    }

    /// What a view hosted in a row takes from the window, which the
    /// table's own environment no longer reaches (`ReviewHosted`): as of
    /// the last update, which reloads the rows when the accent or the
    /// language changes, and configures the headers again when the opacity
    /// does (`refreshHeaderFills`).
    var hostedEnvironment: ReviewHostedEnvironment {
        ReviewHostedEnvironment(
            locale: parent.locale,
            surfaceOpacity: parent.surfaceOpacity,
            accent: appliedAccent ?? LimpidColor.defaultAccent
        )
    }

    /// The surface's opacity changed (the transparency setting, Reduce
    /// Transparency): the file and hunk headers already built are
    /// configured again, as nothing else that changes then reloads the
    /// table, and a reload would cost the reader their place. Only those
    /// rows: every other row stands on the surface without a fill of its
    /// own.
    func refreshHeaderFills(in table: NSTableView) {
        let opacity = parent.surfaceOpacity
        guard appliedSurfaceOpacity != opacity else { return }
        let isFirst = appliedSurfaceOpacity == nil
        appliedSurfaceOpacity = opacity
        // The first rows were built with it.
        guard !isFirst else { return }
        table.enumerateAvailableRowViews { _, row in
            guard parent.rows.indices.contains(row) else { return }
            switch parent.rows[row].kind {
            case let .file(header):
                if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ReviewFileHeaderRowView {
                    configure(view, header: header, in: table)
                }
            case let .hunk(line):
                if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ReviewHunkRowView {
                    configure(view, line: line, row: row)
                }
            default:
                break
            }
        }
    }

    /// The closed file a row belongs to: `nil` for the open file's rows and
    /// for a row outside every file.
    func closedFileID(forRow row: Int) -> String? {
        guard let section = parent.stack.section(atRow: row), !section.isOpen else { return nil }
        return section.file.id
    }

    /// What a row is found again by after the rows are rebuilt.
    func anchorKey(atRow row: Int) -> String? {
        parent.stack.anchorKey(atRow: row)
    }

    /// The language a row's file is written in: each stacked file has its
    /// own. The open file's stands for a row outside every section.
    func language(forRow row: Int) -> ReviewSyntax.Language? {
        guard let section = parent.stack.section(atRow: row) else { return parent.language }
        if let known = languages[section.file.id] {
            return known
        }
        let language = ReviewSyntax.language(for: section.file.path)
        languages[section.file.id] = language
        return language
    }

    /// Puts a file's header at the top of the diff.
    func scroll(toFile fileID: String?, in scroll: NSScrollView, table: NSTableView) {
        guard let fileID, let row = parent.stack.headerRow(of: fileID), row < table.numberOfRows else { return }
        let top = table.rect(ofRow: row).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Names the files on screen and a screen either side of it, so a file
    /// is usually read before the reader reaches it, and none of them is let
    /// go of while the reader is there. From an update, the session hears of
    /// it after the update rather than during it.
    func requestDiffs(in scroll: NSScrollView, table: NSTableView, isUpdating: Bool = false) {
        let stack = parent.stack
        guard table.numberOfRows > 0 else { return }
        let visible = scroll.documentVisibleRect
        // Laid out at no height yet: the frame change that follows asks
        // again (`observeViewport`).
        guard visible.height > 0 else { return }
        let range = table.rows(in: visible.insetBy(dx: 0, dy: -visible.height))
        var ids = range.length > 0 ? stack.sections(in: range.location..<(range.location + range.length)).map(\.file.id) : []
        // The file a place still to be put back names is read where it is,
        // without taking the diff there first (`applyStackRestore`).
        if let waiting = stackRestoreWaitingFile, !ids.contains(waiting) {
            ids.append(waiting)
        }
        guard !ids.isEmpty else { return }
        let onNeedDiffs = parent.onNeedDiffs
        if isUpdating {
            DispatchQueue.main.async { onNeedDiffs(ids) }
        } else {
            onNeedDiffs(ids)
        }
    }

    /// Says which file the reader stopped at after scrolling with the
    /// trackpad or the scroller. Only a scroll the reader made: the table
    /// also scrolls to follow the cursor or a list choice, and opening the
    /// file at the top then would take the reader's line away.
    func observeLiveScroll(of scroll: NSScrollView) {
        // The reader scrolling their own way gives up a place still to be
        // put back (`applyStackRestore`).
        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scroll,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readerMoved()
            }
        }
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scroll,
            queue: .main
        ) { [weak self, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let self, let scroll else { return }
                self.reportReadingFile(in: scroll)
            }
        }
    }

    /// The same, for a mouse wheel and the page keys, once they stop coming.
    func noteScrollStep() {
        readerMoved()
        wheelSettle?.cancel()
        wheelSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  let scroll = self.gutter.table?.enclosingScrollView
            else { return }
            self.reportReadingFile(in: scroll)
        }
    }

    /// The file under the top quarter of the diff (`ReviewStack.readingFile`).
    /// Not while a place is still to be put back: the reader's own scroll
    /// gives it up first (`noteScrollStep`, a live scroll starting), so
    /// whatever stands on screen meanwhile is not where they read, and
    /// opening the file there would take the place's file and the open file
    /// the tab came back with from them.
    private func reportReadingFile(in scroll: NSScrollView) {
        let stack = parent.stack
        guard pendingStackRestore == nil, let table = scroll.documentView as? NSTableView else { return }
        let visible = scroll.documentVisibleRect
        let probe = table.row(at: NSPoint(x: 1, y: visible.minY + min(visible.height / 4, 80)))
        let bottom = table.row(at: NSPoint(x: 1, y: visible.maxY - 1))
        guard let reading = stack.readingFile(probe: probe, bottom: bottom), reading != parent.expandedFileID else { return }
        parent.onReadingFile(reading)
    }

    /// A file header's context menu: its path, as a row of the file list
    /// offers it (`ReviewFileActionsMenu`).
    func headerMenuItems(forRow row: Int) -> [NSMenuItem] {
        guard parent.rows.indices.contains(row), case let .file(header) = parent.rows[row].kind,
              let root = parent.root
        else { return [] }
        let file = header.file
        let fileURL = ReviewFileAction.fileURL(for: file.path, in: root)
        let locale = parent.locale
        var items = [
            ReviewMenuItem(title: LocalizedStringResource("Copy Relative Path").resolved(in: locale)) {
                Self.copy(file.path)
            }
        ]
        if let fileURL {
            items.append(ReviewMenuItem(title: LocalizedStringResource("Copy Absolute Path").resolved(in: locale)) {
                Self.copy(fileURL.path)
            })
            items.append(ReviewMenuItem(title: LocalizedStringResource("Show in Finder").resolved(in: locale)) {
                let target = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : fileURL.deletingLastPathComponent()
                ReviewFileAction.revealInFinder(target)
            })
        }
        return items
    }

    private static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    /// How many of the longest lines are measured properly. The scan keeps
    /// this many by cell count and then asks the font about them; the last
    /// index is derived from it, so the two cannot disagree.
    static let sampleSize = 8

    /// The longest of `texts` by cell count.
    static func candidates(in texts: some Sequence<String>) -> [(cells: Int, text: String)] {
        var candidates: [(cells: Int, text: String)] = []
        for text in texts {
            let cells = ReviewRowPainter.cells(in: text)
            if candidates.count < sampleSize {
                candidates.append((cells, text))
                candidates.sort { $0.cells > $1.cells }
            } else if cells > candidates[sampleSize - 1].cells {
                candidates[sampleSize - 1] = (cells, text)
                candidates.sort { $0.cells > $1.cells }
            }
        }
        return candidates
    }

    /// The same over the stacked diff, one file at a time, keeping each
    /// file's answer: the stack is rebuilt every time a file is read, and
    /// counting the cells of every line of every file again each time
    /// was a scan of the whole range per file read.
    func stackCandidates(_ stack: ReviewStack) -> [(cells: Int, text: String)] {
        var kept: [String: [(cells: Int, text: String)]] = [:]
        var all: [(cells: Int, text: String)] = []
        for section in stack.sections {
            // The open file's rows change as it is unfolded; the others'
            // only with their diff, which changes their row count or ids.
            let key = section.isOpen
                ? nil
                : "\(section.file.id)|\(section.endRow - section.headerRow)|\(section.idOffset)|\(parent.layout.rawValue)"
            let rows = stack.rows[section.headerRow..<section.endRow]
            let found = key.flatMap { sectionWidths[$0] } ?? Self.candidates(in: rows.lazy.flatMap(\.texts))
            if let key {
                kept[key] = found
            }
            all += found
        }
        sectionWidths = kept
        return Self.candidates(in: all.map(\.text))
    }

    /// Where the row keys start from with no cursor: the open file's header
    /// going forward, its end going back, so the keys read on in the file in
    /// front of the reader rather than from the first file of the range.
    func stackStartRow(forward: Bool) -> Int? {
        guard let section = parent.expandedFileID.flatMap(parent.stack.section(of:)) else { return nil }
        return forward ? section.headerRow : section.endRow
    }

    /// The stacked diff's part of an update: it stays where the reader is
    /// when another file opens, puts a chosen file's header at the top, and
    /// reads the files about to be on screen.
    func applyFileChange(in scroll: NSScrollView, table: NSTableView) {
        if appliedScrollSerial != parent.scrollRequest.serial {
            appliedScrollSerial = parent.scrollRequest.serial
            // A file chosen, or another comparison, is where the reader goes
            // now, not the place the tab came back with.
            readerMoved()
            self.scroll(toFile: parent.scrollRequest.fileID, in: scroll, table: table)
        }
        // Taken as the place is first seen, once per table.
        if searchHeldForRestore == nil, finishedStackRestore == nil, pendingStackRestore != nil {
            searchHeldForRestore = parent.search
        }
        applyStackRestore(in: scroll, table: table)
        requestDiffs(in: scroll, table: table, isUpdating: true)
    }

    /// The reader moved (a scroll, a key in the diff, a file chosen, a
    /// search changed, `revealSearchTarget`): from
    /// now on the diff is where they take it. A place the tab came back
    /// with and has not put back yet is given up, and the find bar's match
    /// is scrolled to again as it changes.
    func readerMoved() {
        giveUpStackRestore()
        searchHeldForRestore = nil
    }

    /// Puts the stacked diff back where it was as the review tab went with
    /// its project (`ReviewDiffTable.stackRestore`), once: where
    /// `ReviewStack.restorePlacement` says, the line that was at the top as
    /// far from the top as it was.
    ///
    /// Its file is read again as the tab comes back. Until it is, the diff
    /// stays where it is and has the file read where it lies
    /// (`stackRestoreWaitingFile`), rather than standing on the file's
    /// header meanwhile: a place the reader never chose, which anything
    /// asking where they read would take for theirs.
    ///
    /// An open composer is kept in sight after the place is put back: it
    /// follows the diff (`ReviewComposerFollow`) and may be elsewhere now.
    /// The find bar's match, which a tab can come back with, does not move
    /// the diff on arrival: the place comes first, and the match is
    /// scrolled to again once the person moves it (`revealSearchTarget`).
    /// AppKit scrolls a clip view without animating, so nothing moves under
    /// Reduce Motion.
    func applyStackRestore(in scroll: NSScrollView, table: NSTableView) {
        let stack = parent.stack
        guard let anchor = pendingStackRestore, table.numberOfRows == parent.rows.count else { return }
        let composerRow = composerRowIndex(in: table)
        switch stack.restorePlacement(of: anchor, openFileID: parent.expandedFileID, hasComposer: composerRow != nil) {
        case .wait:
            return
        case let .put(row, offset):
            self.scroll(toRow: row, offset: offset, in: scroll, table: table)
        case .none:
            break
        }
        if let composerRow {
            table.scrollRowToVisible(composerRow)
        }
        finishStackRestore(anchor)
    }

    /// Puts `row` `offset` points below the top of the viewport, as far as
    /// the document allows: where an anchor names a line
    /// (`restore(_:in:table:)`), and where a place kept for the review tab
    /// is put back (`applyStackRestore`).
    func scroll(toRow row: Int, offset: CGFloat, in scroll: NSScrollView, table: NSTableView) {
        guard row < table.numberOfRows else { return }
        let target = max(table.rect(ofRow: row).minY - offset, 0)
        guard abs(target - scroll.documentVisibleRect.minY) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The place still to be put back (`applyStackRestore`), `nil` once it
    /// is, or once the reader moved first.
    var pendingStackRestore: ReviewScrollAnchor? {
        guard let anchor = parent.stackRestore, anchor != finishedStackRestore else { return nil }
        return anchor
    }

    /// The file a place still to be put back waits to have read.
    var stackRestoreWaitingFile: String? {
        guard let anchor = pendingStackRestore,
              case let .wait(fileID) = parent.stack.restorePlacement(of: anchor, openFileID: nil, hasComposer: false)
        else { return nil }
        return fileID
    }

    /// The reader moved first (`readerMoved`): the place the tab came back
    /// with is not put back after that.
    private func giveUpStackRestore() {
        guard let anchor = pendingStackRestore else { return }
        finishStackRestore(anchor)
    }

    private func finishStackRestore(_ anchor: ReviewScrollAnchor) {
        finishedStackRestore = anchor
        let done = parent.onStackRestored
        // After the update: the surface's state is not written while it
        // draws.
        DispatchQueue.main.async { done() }
    }

}

/// A context-menu item that runs a closure, for menus built per row.
final class ReviewMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run(_: Any?) {
        handler()
    }
}
