// ReviewComposerFocusTests.swift
// Limpid — focus and IME state after AppKit creates a delayed composer row.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct ReviewComposerFocusTests {
    @Test func aLazilyCreatedComposerTakesFocusAfterItJoinsTheWindow() async throws {
        let parent = makeTable()
        let coordinator = parent.makeCoordinator()
        let table = ReviewTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let column = NSTableColumn(identifier: .init("review"))
        table.addTableColumn(column)
        table.dataSource = coordinator
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = table
        table.reloadData()
        window.makeFirstResponder(table)
        let candidate = coordinator.tableView(table, viewFor: column, row: 1) as? ReviewComposerRowView
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
        _ = coordinator.tableView(table, viewFor: column, row: 1)
        table.addSubview(composer)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(window.firstResponder === composer.textView)
        #expect(composer.textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func markedTextHidesThePlaceholderBeforeTheTextChangeNotification() throws {
        let composer = ReviewComposerRowView()
        let placeholderCandidate = descendants(of: composer).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == String(localized: "Leave a comment") }
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeTable() -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let line = ReviewLine(id: 0, kind: .added, text: "new", oldLine: nil, newLine: 1)
        return ReviewDiffTable(
            rows: [ReviewRow(id: 0, kind: .code(line)), ReviewRow(id: 1, kind: .composer(line))],
            diffLines: [line], contentKey: "focus", widthKey: "focus", layout: .unified,
            files: [file], lineCommentCounts: [:], numberWidth: 26, expandedFileID: file.id, contentIdentity: file.id,
            selection: .constant(ReviewSelection()), composerLineID: line.id, composerStartLine: nil,
            composerIsEditing: false, composerText: .constant("focus-keep"),
            onSelectFile: { _ in }, onCompose: {}, onCancelCompose: {}, onCommit: {}, onInsert: {}, onToggleTerminal: {},
            search: ReviewSearch(), onCloseSearch: {}, searchTargetLineID: nil, language: nil,
            onToggleViewed: {}, onExpand: { _, _ in }, onResolve: { _ in }, onEdit: { _ in }, onDelete: { _ in }, onClose: {}
        )
    }
}
