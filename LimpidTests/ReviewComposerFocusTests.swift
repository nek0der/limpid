// ReviewComposerFocusTests.swift
// Limpid — the comment composer: whether it holds text, and its focus and IME state after AppKit creates its row.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct ReviewComposerFocusTests {
    @Test func aLazilyCreatedComposerTakesFocusAfterItJoinsTheWindow() async throws {
        let parent = makeTable()
        let coordinator = parent.makeCoordinator()
        let table = ReviewTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), menuLocale: Locale(identifier: "en"))
        let column = NSTableColumn(identifier: .init("review"))
        table.addTableColumn(column)
        table.dataSource = coordinator
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = table
        table.reloadData()
        window.makeFirstResponder(table)
        // Under the file's header and its line.
        let candidate = coordinator.tableView(table, viewFor: column, row: 2) as? ReviewComposerRowView
        let composer = try #require(candidate)
        #expect(!composer.focusText())
        table.addSubview(composer)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.firstResponder === composer.textView)
        composer.textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.prepareComposerForReload(in: table)
        composer.removeFromSuperview()
        window.makeFirstResponder(table)
        _ = coordinator.tableView(table, viewFor: column, row: 2)
        table.addSubview(composer)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.firstResponder === composer.textView)
        #expect(composer.textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func markedTextHidesThePlaceholderBeforeTheTextChangeNotification() throws {
        let composer = ReviewComposerRowView()
        let en = Locale(identifier: "en")
        composer.configure(
            ReviewLine(id: 0, kind: .added, text: "new", oldLine: nil, newLine: 1),
            start: nil,
            text: "",
            isEditing: false,
            metrics: ReviewCardMetrics(viewport: 600, numberWidth: 26, layout: .unified),
            locale: en
        )
        let placeholderCandidate = descendants(of: composer).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Leave a comment" }
        let placeholder = try #require(placeholderCandidate)
        #expect(!placeholder.isHidden)
        composer.textView.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(composer.textView.hasMarkedText())
        #expect(placeholder.isHidden)
    }

    @Test func fileRailOverlayConsumesTableCommandsAndOwnsEscape() {
        var composeCount = 0
        var closeOverlayCount = 0
        let parent = makeTable(
            isOverlayPresented: true,
            onCompose: { composeCount += 1 },
            onCloseOverlay: { closeOverlayCount += 1 }
        )
        let coordinator = parent.makeCoordinator()

        #expect(coordinator.handle(.comment))
        #expect(composeCount == 0)
        #expect(coordinator.handle(.close))
        #expect(closeOverlayCount == 1)
    }

    @Test func loadingSnapshotConsumesMutationKeysButStillAllowsClosing() {
        var composeCount = 0
        var closeCount = 0
        let parent = makeTable(
            isInteractionEnabled: false,
            onCompose: { composeCount += 1 },
            onClose: { closeCount += 1 }
        )
        let coordinator = parent.makeCoordinator()

        #expect(coordinator.handle(.comment))
        #expect(composeCount == 0)
        #expect(coordinator.handle(.close))
        #expect(closeCount == 1)
    }

    @Test func textDragPastDocumentEndClampsToTheLastCodeRow() {
        let parent = makeTable()
        let coordinator = parent.makeCoordinator()
        let table = ReviewTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), menuLocale: Locale(identifier: "en"))
        let column = NSTableColumn(identifier: .init("review"))
        column.width = 600
        table.addTableColumn(column)
        table.rowHeight = ReviewRowMetrics.code
        let dataSource = FixedReviewTableDataSource(rowCount: parent.rows.count)
        table.dataSource = dataSource
        table.reloadData()
        // Row 1: the line, under its file's header.
        let anchor = ReviewTextPosition(rowIndex: 1, lineID: 0, side: nil, utf16Offset: 0)

        let result = coordinator.textPosition(
            at: NSPoint(x: 200, y: 10000),
            continuingFrom: anchor,
            in: table
        )

        #expect(result?.rowIndex == 1)
        #expect(result?.lineID == 0)
    }

    private func makeTable(
        isOverlayPresented: Bool = false,
        isInteractionEnabled: Bool = true,
        onCompose: @escaping () -> Void = {},
        onCloseOverlay: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let line = ReviewLine(id: 0, kind: .added, text: "new", oldLine: nil, newLine: 1)
        var selection = ReviewDiffSelection()
        selection.updateLines { $0.select(line.id) }
        return ReviewTableFixture.table(
            file,
            rows: [ReviewRow(id: 0, kind: .code(line)), ReviewRow(id: 1, kind: .composer(line))],
            lines: [line],
            key: "focus",
            selection: .constant(selection),
            composer: .init(lineID: line.id, text: .constant("focus-keep")),
            locale: Locale(identifier: "en"),
            isInteractionEnabled: isInteractionEnabled,
            isOverlayPresented: isOverlayPresented,
            onCompose: onCompose,
            onCloseOverlay: onCloseOverlay,
            onClose: onClose
        )
    }

    @Test func composerDistinguishesAuthoredTextFromAnEmptyDraft() {
        var composer = ReviewComposerState()
        composer.compose(start: 1, end: 1, side: .new)
        #expect(!composer.hasUnsavedText)

        composer.text = "  Keep this feedback.  "
        #expect(composer.hasUnsavedText)

        composer.text = " \n\t "
        #expect(!composer.hasUnsavedText)
    }
}

private final class FixedReviewTableDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in _: NSTableView) -> Int {
        rowCount
    }

    func tableView(_: NSTableView, objectValueFor _: NSTableColumn?, row _: Int) -> Any? {
        nil
    }
}
