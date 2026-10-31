// ReviewStackRestoreTests.swift
// Weir — the review tab's stacked diff put back where it was as the tab comes back with its project.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// The table's side of bringing a parked review tab's place back: the line
/// at its top, as far from the top as it was, once the file it names has
/// been read again, whichever file is open; nothing once the reader has
/// moved first, even before the range is read again; and the place before
/// the find bar's match. Where a place goes when its line is gone is the
/// stack's own rule (`ReviewStackTests`); the table puts any row back the
/// same way.
@Suite(.hostsWindows)
@MainActor
struct ReviewStackRestoreTests {
    private static let en = Locale(identifier: "en")
    private static let main = ReviewFile(path: "main.swift", layer: .unstaged, status: .modified)
    private static let first = ReviewFile(path: "file01.txt", layer: .unstaged, status: .untracked)
    private static let second = ReviewFile(path: "file02.txt", layer: .unstaged, status: .untracked)
    private static let third = ReviewFile(path: "file03.txt", layer: .unstaged, status: .untracked)
    private static let files = [main, first, second, third]

    /// A table drawing stacks, laid out in a window as the review tab's is.
    @MainActor
    private final class Harness {
        let scroll = ReviewScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let table = ReviewTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 240), menuLocale: ReviewStackRestoreTests.en)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let coordinator: ReviewDiffTable.Coordinator
        var restoredCount = 0

        init(_ parent: ReviewDiffTable) {
            coordinator = parent.makeCoordinator()
            table.headerView = nil
            table.intercellSpacing = .zero
            table.rowHeight = ReviewRowMetrics.code
            let column = NSTableColumn(identifier: .init("review"))
            column.width = 600
            table.addTableColumn(column)
            table.delegate = coordinator
            table.dataSource = coordinator
            scroll.hasVerticalScroller = true
            scroll.documentView = table
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            // As `ReviewDiffTable.makeNSView` does: where the reader stops is
            // heard from the scroll view.
            coordinator.observeLiveScroll(of: scroll)
        }

        /// What `ReviewDiffTable.updateNSView` does for the stacked diff
        /// when its rows change: holds the line at the top across the
        /// rebuild, then the stack's own part of the update, then the find
        /// bar's, in that order.
        func update(_ parent: ReviewDiffTable) {
            let anchor = coordinator.anchor(in: scroll, table: table)
            coordinator.parent = parent
            table.reloadData()
            if let anchor {
                coordinator.restore(anchor, in: scroll, table: table)
            }
            coordinator.applyFileChange(in: scroll, table: table)
            coordinator.refreshSearch(in: table, scroll: scroll)
        }

        var top: CGFloat {
            scroll.documentVisibleRect.minY
        }
    }

    private static func diff(_ file: ReviewFile, lines: Int = 12, fingerprint: String? = nil) throws -> ReviewDiff {
        try ReviewDiffFixture.rewritten(file, lines: lines, fingerprint: fingerprint)
    }

    /// The stack of the suite's files with `open` drawn from its rows and
    /// the others from `entries`, what has been read of them.
    private static func stack(open: ReviewFile, entries: [ReviewFile: ReviewDiff]) throws -> ReviewStack {
        try ReviewStackFixture.stack(files, open: open, entries: entries)
    }

    private static func table(
        _ stack: ReviewStack,
        open: ReviewFile,
        restore: ReviewScrollAnchor?,
        key: String,
        search: ReviewSearch = ReviewSearch(),
        searchTarget: Int? = nil,
        onRestored: @escaping () -> Void = {},
        onNeedDiffs: @escaping ([String]) -> Void = { _ in },
        onReadingFile: @escaping (String) -> Void = { _ in }
    ) -> ReviewDiffTable {
        ReviewDiffTable(
            stack: stack,
            diffLines: [],
            contentKey: key, widthKey: "restore", layout: .unified,
            files: files, numberWidth: 26, expandedFileID: open.id,
            selection: .constant(ReviewDiffSelection()),
            composerLineID: nil, composerStartLine: nil,
            composerIsEditing: false, composerText: .constant(""),
            onSelectFile: { _ in }, onCompose: {}, onCancelCompose: {}, onCommit: {}, onInsert: {},
            search: search, onCloseSearch: {}, searchTargetLineID: searchTarget, language: nil,
            onToggleViewed: {}, fileApplication: .macOSDefault, onOpenLine: { _, _ in }, onExpand: { _, _ in }, onResolve: { _ in },
            onEdit: { _ in },
            onDelete: { _ in },
            stackRestore: restore,
            onStackRestored: onRestored,
            onNeedDiffs: onNeedDiffs,
            onReadingFile: onReadingFile,
            isOverlayPresented: false, onCloseOverlay: {}, onClose: {},
            locale: en
        )
    }

    /// Every file read, `second` open: the reader stood with a line of
    /// `first` at the top, a few points above it.
    private static func leftPlace() throws -> (anchor: ReviewScrollAnchor, entries: [ReviewFile: ReviewDiff]) {
        let entries = try Dictionary(uniqueKeysWithValues: files.map { try ($0, diff($0)) })
        let read = try stack(open: second, entries: entries)
        let section = try #require(read.section(of: first.id))
        let key = try #require(read.anchorKey(atRow: section.headerRow + 8))
        return (ReviewScrollAnchor(key: key, offset: -5), entries)
    }

    /// The row `stack` puts `anchor` back on with `open` open: its line,
    /// once the line's file has been read.
    private static func row(of anchor: ReviewScrollAnchor, in stack: ReviewStack, open: ReviewFile) -> Int? {
        guard case let .put(row, _) = stack.restorePlacement(of: anchor, openFileID: open.id, hasComposer: false) else { return nil }
        return row
    }

    // MARK: - Put back

    /// The usual case: the reader stopped on a line of `first`
    /// while `second` was open, and the tab comes back with only `second`
    /// read. The place is not given up for the restore's own wait, nor
    /// taken over by a report of where the reader is while it waits.
    @Test func aPlaceInAFileNotReadYet_isPutBackExactly_onceTheFileIsRead() async throws {
        let (anchor, entries) = try Self.leftPlace()
        let unread = try Self.stack(open: Self.second, entries: [Self.second: entries[Self.second] ?? Self.diff(Self.second)])
        var restored = 0
        var asked: [[String]] = []
        var opened: [String] = []
        let waiting = { (stack: ReviewStack, key: String) in
            Self.table(
                stack, open: Self.second, restore: anchor, key: key,
                onRestored: { restored += 1 },
                onNeedDiffs: { asked.append($0) },
                onReadingFile: { opened.append($0) }
            )
        }
        let harness = Harness(Self.table(unread, open: Self.second, restore: nil, key: "unread"))
        defer { harness.window.close() }

        harness.update(waiting(unread, "unread"))
        await Self.nextTurn()
        #expect(harness.top == 0, "the diff waits where it is, not on a place the reader never chose")
        #expect(asked.last?.contains(Self.first.id) == true, "the place's file is read where it lies")
        // A report of where the reader is, while the place waits, opens nothing.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: harness.scroll)
        #expect(opened.isEmpty)

        // The file is read.
        let read = try Self.stack(open: Self.second, entries: entries)
        harness.update(waiting(read, "read"))
        let row = try #require(Self.row(of: anchor, in: read, open: Self.second), "the line is there once its file is read")
        #expect(abs(harness.top - (harness.table.rect(ofRow: row).minY - anchor.offset)) < 0.5, "the line, as far from the top as it was")
        await Self.nextTurn()
        #expect(restored == 1)

        // Put back once: the reader's own place holds from then on.
        harness.scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        harness.update(Self.table(read, open: Self.second, restore: anchor, key: "read again"))
        #expect(harness.top == 0)
    }

    @Test func aPlaceIsPutBackExactly_evenPastTheOpenFile() throws {
        let (_, entries) = try Self.leftPlace()
        // The open file did not follow the scroll (a scroller moved without
        // a live scroll): the place is the reader's all the same.
        let read = try Self.stack(open: Self.main, entries: entries)
        let section = try #require(read.section(of: Self.third.id))
        let anchor = try ReviewScrollAnchor(key: #require(read.anchorKey(atRow: section.headerRow + 4)), offset: 0)
        let harness = Harness(Self.table(read, open: Self.main, restore: nil, key: "read"))
        defer { harness.window.close() }

        harness.update(Self.table(read, open: Self.main, restore: anchor, key: "restore"))

        #expect(abs(harness.top - harness.table.rect(ofRow: section.headerRow + 4).minY) < 0.5)
    }

    @Test func searchingWhileThePlaceWaits_givesThePlaceUp() async throws {
        let (anchor, entries) = try Self.leftPlace()
        let unread = try Self.stack(open: Self.second, entries: [Self.second: entries[Self.second] ?? Self.diff(Self.second)])
        let open = try #require(unread.section(of: Self.second.id))
        let lines = unread.rows[(open.headerRow + 1)..<open.endRow].compactMap(\.anchorLine)
        let (first, last) = try (#require(lines.first?.id), #require(lines.last?.id))
        let search = ReviewSearch(query: "new", isPresented: true, index: 0)
        var restored = 0
        let harness = Harness(Self.table(unread, open: Self.second, restore: nil, key: "unread"))
        defer { harness.window.close() }
        harness.update(Self.table(unread, open: Self.second, restore: anchor, key: "unread", search: search, searchTarget: first) {
            restored += 1
        })

        // The person goes to another match while the place's file is read.
        var next = search
        next.index = 5
        harness
            .update(Self
                .table(unread, open: Self.second, restore: anchor, key: "searched", search: next, searchTarget: last) { restored += 1 })
        let atMatch = harness.top
        let read = try Self.stack(open: Self.second, entries: entries)
        harness
            .update(Self.table(read, open: Self.second, restore: anchor, key: "read", search: next, searchTarget: last) { restored += 1 })

        let row = try #require(Self.row(of: anchor, in: read, open: Self.second), "the line is there once its file is read")
        #expect(abs(harness.top - (harness.table.rect(ofRow: row).minY - anchor.offset)) > 0.5, "not taken from the match")
        let match = try #require(read.rows.firstIndex { $0.contains(lineID: last) })
        #expect(harness.scroll.documentVisibleRect.intersects(harness.table.rect(ofRow: match)), "the match stays in sight")
        #expect(atMatch > 0)
        await Self.nextTurn()
        #expect(restored == 1)
    }

    /// Where the reader stops opens the file there again once the place is
    /// put back, or given up: only while it waits is the diff not theirs.
    @Test func theOpenFileFollowsReadingAgain_onceThePlaceIsPutBackOrGivenUp() throws {
        let entries = try Dictionary(uniqueKeysWithValues: Self.files.map { try ($0, Self.diff($0)) })
        let read = try Self.stack(open: Self.third, entries: entries)
        let section = try #require(read.section(of: Self.first.id))
        let anchor = try ReviewScrollAnchor(key: #require(read.anchorKey(atRow: section.headerRow + 8)), offset: 0)
        var opened: [String] = []
        let stopsReading = { (harness: Harness) in
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: harness.scroll)
        }

        let putBack = Harness(Self.table(read, open: Self.third, restore: nil, key: "read"))
        defer { putBack.window.close() }
        putBack.update(Self.table(read, open: Self.third, restore: anchor, key: "restore", onReadingFile: { opened.append($0) }))
        stopsReading(putBack)
        #expect(opened == [Self.first.id], "after it is put back")

        opened = []
        let unread = try Self.stack(open: Self.third, entries: [Self.third: entries[Self.third] ?? Self.diff(Self.third)])
        let givenUp = Harness(Self.table(unread, open: Self.third, restore: nil, key: "unread"))
        defer { givenUp.window.close() }
        givenUp.update(Self.table(unread, open: Self.third, restore: anchor, key: "waiting", onReadingFile: { opened.append($0) }))
        stopsReading(givenUp)
        #expect(opened.isEmpty, "not while it waits")
        givenUp.coordinator.readerMoved()
        stopsReading(givenUp)
        #expect(opened.count == 1, "after it is given up")
    }

    @Test func aTabBackWithItsFindBar_isPutBackOnItsPlace_notOnItsMatch() throws {
        let (anchor, entries) = try Self.leftPlace()
        let read = try Self.stack(open: Self.second, entries: entries)
        let third = try #require(read.section(of: Self.third.id))
        let match = try #require(read.rows[(third.headerRow + 1)..<third.endRow].compactMap(\.anchorLine).last?.id)
        let search = ReviewSearch(query: "new", isPresented: true, index: 3)
        let harness = Harness(Self.table(read, open: Self.second, restore: nil, key: "read"))
        defer { harness.window.close() }

        harness.update(Self.table(read, open: Self.second, restore: anchor, key: "restore", search: search, searchTarget: match))
        let row = try #require(Self.row(of: anchor, in: read, open: Self.second), "the line is there")
        let place = harness.table.rect(ofRow: row).minY - anchor.offset
        #expect(abs(harness.top - place) < 0.5)

        // The person searches again: the match is scrolled to as before.
        var next = search
        next.index = 4
        harness.update(Self.table(read, open: Self.second, restore: nil, key: "searched", search: next, searchTarget: match - 1))
        #expect(abs(harness.top - place) > 0.5)
    }

    @Test func theReaderScrollingFirst_givesThePlaceUp() async throws {
        let (anchor, entries) = try Self.leftPlace()
        let unread = try Self.stack(open: Self.second, entries: [Self.second: entries[Self.second] ?? Self.diff(Self.second)])
        var restored = 0
        let harness = Harness(Self.table(unread, open: Self.second, restore: nil, key: "unread"))
        defer { harness.window.close() }
        harness.update(Self.table(unread, open: Self.second, restore: anchor, key: "unread") { restored += 1 })

        // A wheel step of the reader's, while the file is still being read.
        harness.scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        harness.coordinator.noteScrollStep()
        let read = try Self.stack(open: Self.second, entries: entries)
        harness.update(Self.table(read, open: Self.second, restore: anchor, key: "read"))

        let row = try #require(Self.row(of: anchor, in: read, open: Self.second), "the line is there once its file is read")
        #expect(
            abs(harness.top - (harness.table.rect(ofRow: row).minY - anchor.offset)) > 0.5,
            "where the reader went, not the place given up"
        )
        await Self.nextTurn()
        #expect(restored == 1)
    }

    private static func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
