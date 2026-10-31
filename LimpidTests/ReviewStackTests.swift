// ReviewStackTests.swift
// Limpid — the review tab's stacked diff: every file under its header, the reading marks and moving between files.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Review stack")
struct ReviewStackTests {
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")
    private static let first = ReviewFile(path: "Limpid/Core/Turn/TurnTimelineStore.swift", layer: .turns, status: .modified)
    private static let second = ReviewFile(path: "LimpidTests/TurnTimelineStoreTests.swift", layer: .turns, status: .added)
    private static let third = ReviewFile(path: "README.md", layer: .turns, status: .modified)
    private static let files = [first, second, third]

    /// The stack of the suite's three files as the review tab builds it.
    private static func stack(
        open: ReviewFile?,
        entries: [ReviewFile: ReviewDiff],
        viewed: Set<String> = [],
        unfolded: Set<String> = []
    ) throws -> ReviewStack {
        try ReviewStackFixture.stack(files, open: open, entries: entries, viewed: viewed, unfolded: unfolded)
    }

    private static func header(_ stack: ReviewStack, _ file: ReviewFile) -> ReviewStackHeader? {
        guard let row = stack.headerRow(of: file.id), case let .file(header) = stack.rows[row].kind else { return nil }
        return header
    }

    private static func all(lines: Int = 2) throws -> [ReviewFile: ReviewDiff] {
        try Dictionary(uniqueKeysWithValues: files.map { try ($0, ReviewDiffFixture.rewritten($0, lines: lines)) })
    }

    // MARK: - The list's header

    /// The review tab's list opens at 240, wide enough for the
    /// checkbox before each name.
    @Test func theTabsFileList_opensAtTheDefaultWidth() {
        #expect(ReviewPresentation().railWidth == ReviewRail.default)
    }

    @Test func progress_countsTheCheckedFilesOfTheList() {
        let progress = ReviewReadingProgress(fileIDs: Self.files.map(\.id), viewed: [Self.first.id, "turns:gone.swift"])

        #expect(progress.viewed == 1, "a mark on a file no longer listed counts for nothing")
        #expect(progress.total == 3)
        #expect(ReviewStackText.progress(progress, locale: Self.en) == "1 / 3 viewed")
        #expect(ReviewStackText.progress(progress, locale: Self.ja) == "確認済み 1 / 3")
    }

    @Test func theSummary_readsTheDiffsCountsInTheReceiptsOrder() {
        let stats = [
            Self.first.id: ReviewFileStat(added: 2, removed: 1),
            Self.second.id: ReviewFileStat(added: 3, removed: 0)
        ]
        let summary = ReviewStackText.summary(files: [Self.first, Self.second], stats: stats, locale: Self.en)

        #expect(summary.map(\.text).joined() == "2 files +5 −1", "as the receipt and the changes panel write it")
        #expect(summary.contains(ReceiptRun(text: "+5", role: .added(isEmphasized: false))))
        #expect(ReviewStackText.summary(files: [Self.first], stats: stats, locale: Self.ja).map(\.text).joined() == "1 ファイル +2 −1")
    }

    @Test func theScopesTitles_nameWhatTheFilesAre() {
        #expect(ReviewLayer.turns.title.resolved(in: Self.en) == "Turn Changes")
        #expect(ReviewLayer.turns.title.resolved(in: Self.ja) == "ターンの変更")
        #expect(ReviewLayer.turn.title.resolved(in: Self.en) == "Earlier Review", "where a legacy comment came from")
        #expect(ReviewLayer.turn.title.resolved(in: Self.ja) == "以前のレビュー")
        #expect(ReviewLayer.branch.title.resolved(in: Self.en) == "On This Branch", "title case, as the other headings")
        #expect(ReviewLayer.branch.title.resolved(in: Self.ja) == "このブランチの変更")
    }

    @Test func aCommentsPosition_namesOldAndNew_orTheOneLineItHas() {
        func position(_ old: (Int?, Int?), _ new: (Int?, Int?), _ locale: Locale) -> String {
            ReviewComment.position(oldStart: old.0, oldEnd: old.1, newStart: new.0, newEnd: new.1, locale: locale)
        }
        #expect(position((10, nil), (11, nil), Self.en) == "Old 10 → new 11")
        #expect(position((10, nil), (11, nil), Self.ja) == "変更前 10 → 変更後 11")
        #expect(position((nil, nil), (11, nil), Self.en) == "Line 11", "an added line has no old position to write as -")
        #expect(position((nil, nil), (11, nil), Self.ja) == "11 行目")
        #expect(position((7, nil), (nil, nil), Self.ja) == "7 行目")
        #expect(position((nil, nil), (11, 14), Self.en) == "Lines 11-14")
        #expect(position((nil, nil), (11, 14), Self.ja) == "11-14 行目")
        #expect(position((nil, nil), (nil, nil), Self.en).isEmpty, "nothing to place says nothing")
    }

    // MARK: - Checking a file

    @Test func checkingAFile_foldsItToItsHeader() throws {
        let entries = try Self.all(lines: 3)
        let open = try Self.stack(open: Self.first, entries: entries)
        let checked = try Self.stack(open: Self.first, entries: entries, viewed: [Self.first.id, Self.second.id])

        let unchecked = try #require(open.section(of: Self.second.id))
        #expect(unchecked.endRow - unchecked.headerRow > 1, "its diff is under its header")
        for file in [Self.first, Self.second] {
            let section = try #require(checked.section(of: file.id))
            #expect(section.endRow == section.headerRow + 1, "the open file folds too")
            #expect(Self.header(checked, file)?.isViewed == true)
        }
        #expect(Self.header(checked, Self.third)?.isViewed == false)
        #expect(Self.header(checked, Self.second)?.isFolded == true, "its chevron says it is folded")
        #expect(Self.header(checked, Self.third)?.isFolded == false, "an unchecked file is always open")
        #expect(ReviewStackText.foldState(isFolded: true, locale: Self.en) == "Collapsed")
        #expect(ReviewStackText.foldState(isFolded: false, locale: Self.ja) == "展開済み")
    }

    private static func mark(at seconds: TimeInterval) -> ReviewViewMark {
        ReviewViewMark(added: 1, removed: 1, fingerprint: nil, markedAt: Date(timeIntervalSince1970: seconds))
    }

    /// The files of `stack` a search for `query` lands in.
    private static func searchedFiles(_ stack: ReviewStack, _ query: String) -> Set<String> {
        Set(ReviewSearch.hits(in: stack.rows, query: query).compactMap { stack.locate(lineID: $0.lineID)?.fileID })
    }

    /// A checked file the reader opened again from its header is drawn, and
    /// searched, like an unchecked one; its header still says it is checked.
    @Test func aCheckedFileOpenedByHand_isDrawnAndSearchedLikeAnUncheckedOne() throws {
        let entries = try Self.all(lines: 3)
        let viewed = [Self.second.id: Self.mark(at: 1)]
        var opened = ReviewStackOpenedFiles()
        let folded = try Self.stack(open: Self.first, entries: entries, viewed: Set(viewed.keys))
        #expect(!Self.searchedFiles(folded, "new 1").contains(Self.second.id), "folded, it is not searched")

        opened.toggle(Self.second.id, isFolded: true, viewed: viewed)
        #expect(opened.ids(viewed: viewed) == [Self.second.id])
        let unfolded = ReviewStackBuilder.unfolded(openFileID: Self.first.id, isComposerOpen: false, opened: opened.ids(viewed: viewed))
        let open = try Self.stack(open: Self.first, entries: entries, viewed: Set(viewed.keys), unfolded: unfolded)
        let section = try #require(open.section(of: Self.second.id))
        #expect(section.endRow - section.headerRow > 1, "its diff is under its header again")
        #expect(Self.header(open, Self.second)?.isViewed == true)
        #expect(Self.header(open, Self.second)?.isFolded == false)
        #expect(Self.searchedFiles(open, "new 1").contains(Self.second.id))
        #expect(open.readingFile(probe: section.headerRow, bottom: section.endRow - 1) == Self.second.id, "it can be read on into")

        opened.toggle(Self.second.id, isFolded: false, viewed: viewed)
        #expect(opened.ids(viewed: viewed).isEmpty, "its chevron folds it again")
    }

    /// A fresh check folds the file, whichever window made it: one opened by
    /// hand, unchecked and checked again, carries a new mark.
    @Test func checkingAFileAgain_foldsItEvenIfItWasOpenedByHand() throws {
        var opened = ReviewStackOpenedFiles()
        let first = [Self.second.id: Self.mark(at: 1)]
        opened.toggle(Self.second.id, isFolded: true, viewed: first)
        #expect(opened.ids(viewed: [:]).isEmpty, "unchecked, nothing is folded or opened")

        let again = [Self.second.id: Self.mark(at: 2)]
        #expect(opened.ids(viewed: again).isEmpty, "checked again, it folds")
        let stack = try Self.stack(
            open: Self.first,
            entries: Self.all(lines: 3),
            viewed: Set(again.keys),
            unfolded: ReviewStackBuilder.unfolded(openFileID: Self.first.id, isComposerOpen: false, opened: opened.ids(viewed: again))
        )
        #expect(Self.header(stack, Self.second)?.isFolded == true)

        opened.prune(viewed: again)
        #expect(opened == ReviewStackOpenedFiles(), "the old opening is let go of")
        #expect(opened.ids(viewed: first).isEmpty, "and does not come back with its old mark")
    }

    /// The open file stays drawn whole while its composer is open, with the
    /// files opened by hand; folded from its chevron then, it folds once
    /// the comment is closed rather than staying open.
    @Test func theComposerRule_holdsBesideTheFilesOpenedByHand() {
        #expect(ReviewStackBuilder.unfolded(openFileID: "a", isComposerOpen: true, opened: ["b"]) == ["a", "b"])
        #expect(ReviewStackBuilder.unfolded(openFileID: "a", isComposerOpen: false, opened: ["b"]) == ["b"])
        #expect(ReviewStackBuilder.unfolded(openFileID: nil, isComposerOpen: true, opened: ["b"]) == ["b"])

        let viewed = ["a": Self.mark(at: 1)]
        var opened = ReviewStackOpenedFiles()
        // Held open by the composer, its header shows it open: the chevron
        // folds it.
        opened.toggle("a", isFolded: false, viewed: viewed)
        #expect(opened.ids(viewed: viewed).isEmpty)
        #expect(ReviewStackBuilder.unfolded(openFileID: "a", isComposerOpen: false, opened: opened.ids(viewed: viewed)).isEmpty)
        // An unchecked file has nothing to open.
        opened.toggle("b", isFolded: true, viewed: viewed)
        #expect(opened.ids(viewed: viewed).isEmpty)
    }

    /// Blue while the range holds turns past the viewed line, whatever the
    /// files' checkboxes say (they are reading marks); the bar at rest
    /// for a range already viewed and for the main diff.
    @Test func theBand_isTheUnreadReceiptWhileTheRangeIsPastTheViewedLine() throws {
        let turns = try [7, 8].map { number in
            try TurnSummaryFixture.turn(
                "T\(number)",
                phase: "finished",
                changes: TurnSummaryFixture.changedFiles,
                number: number,
                endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", number), root: "/repo"),
                extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo"))
            )
        }
        func context(viewedThrough: Int) -> ReviewTabModel.Context {
            ReviewTabModel.Context(turns: turns, isViewed: { $0.displayNumber <= viewedThrough }, branchBase: "main")
        }
        let tab = try ReviewTabModel.open(.unviewedTurns, context(viewedThrough: 6), root: "/repo", agentPaneID: nil, current: nil).get()

        #expect(ReviewTabModel.bandTone(tab, context(viewedThrough: 6)) == .unread)
        #expect(ReviewTabModel.bandTone(tab, context(viewedThrough: 8)) == .muted, "already viewed")
        let branch = ReviewTabModel.select(.branch(base: "main"), in: tab, context(viewedThrough: 6))
        #expect(ReviewTabModel.bandTone(branch, context(viewedThrough: 6)) == .muted, "no line describes the main diff")
        #expect(ReviewTabText.bandTag(locale: Self.ja) == "レビュー")
    }

    // MARK: - Scrolling to a file

    @Test func choosingAFile_scrollsToItsHeader() throws {
        let entries = try [
            Self.first: ReviewDiffFixture.rewritten(Self.first, lines: 2),
            Self.second: ReviewDiffFixture.rewritten(Self.second, lines: 5),
            Self.third: ReviewDiffFixture.rewritten(Self.third, lines: 1)
        ]
        let stack = try Self.stack(open: Self.first, entries: entries)

        // Each header follows the rows of the file above it: the hunk header
        // and its removed and added lines.
        #expect(stack.headerRow(of: Self.first.id) == 0)
        #expect(stack.headerRow(of: Self.second.id) == 1 + 1 + 4)
        #expect(stack.headerRow(of: Self.third.id) == 6 + 1 + 1 + 10)
        #expect(stack.headerRow(of: "turns:missing.swift") == nil)
        #expect(stack.section(atRow: 7)?.file == Self.second, "a row belongs to the header above it")
        #expect(stack.section(atRow: stack.rows.count - 1)?.file == Self.third)
        #expect(stack.section(atRow: stack.rows.count) == nil)
    }

    @Test func aFileNotYetRead_waitsUnderItsHeader() throws {
        let stack = try Self.stack(open: Self.first, entries: [Self.first: ReviewDiffFixture.rewritten(Self.first)])
        let unread = try #require(stack.section(of: Self.second.id))

        #expect(unread.endRow == unread.headerRow + 2, "one row says it is loading")
        #expect(stack.rows[unread.headerRow + 1].kind == .notice("Loading changes…"))
        #expect(unread.fingerprint == nil, "nothing read to hold the reader's place by")
        #expect(stack.sections(in: unread.headerRow..<unread.endRow).map(\.file) == [Self.second])
    }

    @Test func anotherFilesLines_areNumberedApart_andLeadBackToTheirFile() throws {
        let entries = try Self.all()
        let stack = try Self.stack(open: Self.first, entries: entries)
        let section = try #require(stack.section(of: Self.second.id))
        let line = try #require(stack.rows[section.headerRow..<section.endRow].compactMap(\.line).first { $0.kind == .added })

        #expect(line.id >= ReviewStackIDs.stride, "never an id of the open file")
        let located = try #require(stack.locate(lineID: line.id))
        #expect(located.fileID == Self.second.id)
        #expect(entries[Self.second]?.lines.contains { $0.id == located.lineID && $0.kind == .added } == true)
        #expect(stack.locate(lineID: 2)?.fileID == Self.first.id, "an id of the open file is the open file's")
    }

    // MARK: - Holding the reader's place

    @Test func theReadersPlace_holdsWhenAnotherFileIsOpened() throws {
        let entries = try Self.all()
        let before = try Self.stack(open: Self.first, entries: entries)
        let after = try Self.stack(open: Self.second, entries: entries)
        let section = try #require(before.section(of: Self.second.id))
        let row = section.headerRow + 2
        let key = try #require(before.anchorKey(atRow: row))

        let moved = try #require(after.row(forAnchorKey: key))
        #expect(after.rows[moved].anchorLine?.text == before.rows[row].anchorLine?.text, "the same line, now under the open file's ids")
        #expect(after.row(forAnchorKey: "h|" + Self.third.id) == after.headerRow(of: Self.third.id))
    }

    @Test func aFileThatChanged_putsTheReaderAtItsHeader() throws {
        var entries = try Self.all()
        let before = try Self.stack(open: Self.first, entries: entries)
        let section = try #require(before.section(of: Self.second.id))
        let key = try #require(before.anchorKey(atRow: section.headerRow + 2))
        entries[Self.second] = try ReviewDiffFixture.rewritten(Self.second, lines: 2, fingerprint: "edited")

        let after = try Self.stack(open: Self.first, entries: entries)

        #expect(after.row(forAnchorKey: key) == after.headerRow(of: Self.second.id), "the line's id no longer names that code")
    }

    @Test func aKeptPlace_isPutWhereItWas_orAtItsFilesHeader_orOnWhatIsSelected() throws {
        let entries = try Self.all()
        let read = try Self.stack(open: Self.first, entries: entries)
        let section = try #require(read.section(of: Self.second.id))
        let key = try #require(read.anchorKey(atRow: section.headerRow + 2))
        let anchor = ReviewScrollAnchor(key: key, offset: -4)
        let firstHeader = try #require(read.headerRow(of: Self.first.id))

        // Exactly, whichever file is open, even one above it.
        #expect(read.restorePlacement(of: anchor, openFileID: Self.first.id, hasComposer: false) == .put(
            row: section.headerRow + 2,
            offset: -4
        ))
        // Its file not read yet: it waits, and has the file read.
        let unread = try Self.stack(open: Self.first, entries: [Self.first: entries[Self.first] ?? ReviewDiffFixture.rewritten(Self.first)])
        #expect(unread.restorePlacement(of: anchor, openFileID: Self.first.id, hasComposer: false) == .wait(fileID: Self.second.id))
        // A header names a file read or not: no wait.
        let header = ReviewScrollAnchor(key: "h|" + Self.second.id, offset: 0)
        #expect(unread.restorePlacement(of: header, openFileID: Self.first.id, hasComposer: false)
            == .put(row: unread.headerRow(of: Self.second.id) ?? -1, offset: 0))

        // Gone while its file is listed: the file's header, failed reads
        // and checked files included.
        var edited = entries
        edited[Self.second] = try ReviewDiffFixture.rewritten(Self.second, lines: 2, fingerprint: "edited")
        let changed = try Self.stack(open: Self.first, entries: edited)
        #expect(changed.restorePlacement(of: anchor, openFileID: Self.first.id, hasComposer: true)
            == .put(row: changed.headerRow(of: Self.second.id) ?? -1, offset: 0))
        let checked = try Self.stack(open: Self.first, entries: entries, viewed: [Self.second.id])
        #expect(checked.restorePlacement(of: anchor, openFileID: Self.first.id, hasComposer: false)
            == .put(row: checked.headerRow(of: Self.second.id) ?? -1, offset: 0))

        // Its file gone from the range: the open file, or the composer.
        let missing = ReviewScrollAnchor(key: "l|3|fp|gone.swift", offset: 0)
        #expect(read.restorePlacement(of: missing, openFileID: Self.first.id, hasComposer: false) == .put(row: firstHeader, offset: 0))
        #expect(read.restorePlacement(of: missing, openFileID: Self.first.id, hasComposer: true) == .none)
    }

    @Test func aKeptPlaceInAFileGitCouldNotRead_doesNotWait() throws {
        let failed = try ReviewStackFixture.stack(
            Self.files,
            open: Self.first,
            entries: [:],
            failed: [Self.second: "Git couldn’t load the changes. Try again."]
        )
        let anchor = ReviewScrollAnchor(key: "l|3|fp|" + Self.second.id, offset: 0)

        #expect(failed.restorePlacement(of: anchor, openFileID: Self.first.id, hasComposer: false)
            == .put(row: failed.headerRow(of: Self.second.id) ?? -1, offset: 0))
    }

    // MARK: - Marks

    @Test func eachKindOfFile_carriesItsMarks() {
        func marks(_ status: ReviewFileStatus, bash: Set<String> = [], outside: Set<String> = []) -> [ReviewFileMark] {
            ReviewFileMark.marks(
                for: ReviewFile(path: "a.swift", layer: .turns, status: status),
                changedByBash: bash,
                changedOutsideTurns: outside
            )
        }

        #expect(marks(.added) == [.new])
        #expect(marks(.untracked) == [.new])
        #expect(marks(.copied) == [.new], "a copy is a path that was not there either")
        #expect(marks(.modified).isEmpty)
        #expect(marks(.deleted).isEmpty)
        #expect(marks(.renamed).isEmpty)
        #expect(marks(.modified, bash: ["a.swift"]) == [.changedByBash])
        #expect(marks(.modified, outside: ["a.swift"]) == [.changedOutsideTurns])
        #expect(marks(.modified, outside: ["b.swift"]).isEmpty, "by path")
        #expect(marks(.added, bash: ["a.swift"], outside: ["a.swift"]) == [.new, .changedByBash, .changedOutsideTurns])
        #expect(ReviewFileMark.allCases.map { ReviewStackText.mark($0, locale: Self.en) } == [
            "New",
            "Changed by Bash",
            "Changed Outside Turns"
        ])
        #expect(ReviewFileMark.allCases.map { ReviewStackText.mark($0, locale: Self.ja) } == ["新規", "Bash で変更", "ターン外の変更"])
    }

    @Test func aFilesContent_isTheVersionItsDiffShows_orNotUnfolded() throws {
        let diff = try ReviewDiff(
            file: Self.first,
            fingerprint: "f",
            lines: ReviewDiffParser.parse("@@ -2,3 +2,3 @@\n keep\n-old\n+new\n tail")
        )

        #expect(ReviewSourceCheck.matches(["head", "keep", "new", "tail", "more"], diff: diff))
        #expect(!ReviewSourceCheck.matches(["head", "keep", "newer", "tail"], diff: diff), "an added line changed since")
        #expect(!ReviewSourceCheck.matches(["keep", "new", "tail"], diff: diff), "lines moved")
        #expect(!ReviewSourceCheck.matches(["head", "keep", "new"], diff: diff), "cut short")
    }

    @Test func theFindBar_saysWhatItDidNotSearch() {
        func note(_ isLoadedFilesOnly: Bool, _ skipsViewedFiles: Bool, _ locale: Locale) -> String? {
            ReviewStackText.findNote(isLoadedFilesOnly: isLoadedFilesOnly, skipsViewedFiles: skipsViewedFiles, locale: locale)
        }
        #expect(note(false, false, Self.en) == nil)
        #expect(note(false, true, Self.en) == "Viewed files aren’t searched.", "the word the checkbox and the list use")
        #expect(note(false, true, Self.ja) == "確認済みのファイルは検索しません。")
        #expect(note(true, true, Self.en) ==
            "Searching only the files loaded so far, not the viewed ones: this scope is too large to load at once.")
        #expect(note(true, true, Self.ja) == "この範囲は一度に読み込めないため、確認済みを除く読み込んだファイルだけを検索しています。")
        #expect(note(true, false, Self.en) == "Searching only the files loaded so far: this scope is too large to load at once.")
        #expect(note(true, false, Self.ja) == "この範囲は一度に読み込めないため、読み込んだファイルだけを検索しています。")
    }

    @Test func theHeader_carriesTheMarksAndTheCounts() throws {
        var input = ReviewStackBuilder.Input(files: Self.files, slots: ReviewStackFixture.slots(Self.files))
        input.stats = [Self.second.id: ReviewFileStat(added: 1234, removed: 2)]
        input.marks = [Self.second.id: [.new, .changedOutsideTurns]]
        let stack = ReviewStackBuilder.build(input) { _, _, _ in ReviewStackPiece(rows: []) }
        let header = try #require(Self.header(stack, Self.second))

        #expect(header.marks == [.new, .changedOutsideTurns])
        #expect(header.stat == ReviewFileStat(added: 1234, removed: 2))
        #expect(ReviewStackText.checkboxLabel(path: "a.swift", locale: Self.ja) == "a.swift を確認済みにする")
    }

    // MARK: - A closed file's comments

    @Test func aClosedFilesComment_onAnotherVersion_drawsNoCardAndNoMark() async throws {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let written = try ReviewDiffFixture.rewritten(file, lines: 2, fingerprint: "v1")
        let repository = StackReviewRepository(files: [file], diffs: [written])
        let session = ReviewSession(
            writer: ReviewDraftWriter(
                root: URL(fileURLWithPath: "/tmp/limpid-stack-\(UUID().uuidString)"),
                drafts: RecordingReviewDraftStore()
            ),
            git: repository
        )
        _ = await session.reload(scope: .uncommitted, selectedFileID: file.id)
        let line = try #require(written.lines.first { $0.kind == .added })
        #expect(session.add(line: line, body: "Why?"))
        let comments = session.comments
        let edited = try ReviewDiffFixture.rewritten(file, lines: 2, fingerprint: "v2")

        let current = ReviewStackPiece.closed(
            written,
            offset: ReviewStackIDs.stride,
            comments: comments,
            staleCommentIDs: [],
            layout: .unified
        )
        let moved = ReviewStackPiece.closed(
            edited,
            offset: ReviewStackIDs.stride,
            comments: comments,
            staleCommentIDs: [],
            layout: .unified
        )

        #expect(current.rows.contains {
            if case .comment = $0.kind {
                true
            } else {
                false
            }
        })
        #expect(!moved.rows.contains {
            if case .comment = $0.kind {
                true
            } else {
                false
            }
        }, "not about the line that now has its id")
        #expect(ReviewStackPiece.closedCounts(written, comments: comments) == [line.id: 1])
        #expect(ReviewStackPiece.closedCounts(edited, comments: comments).isEmpty)
    }

    // MARK: - Moving between files

    @Test func aCursorInAnotherFile_opensThatFile_onTheSameLines() throws {
        let entries = try Self.all()
        let stack = try Self.stack(open: Self.first, entries: entries)
        let section = try #require(stack.section(of: Self.second.id))
        let ids = stack.rows[section.headerRow..<section.endRow].compactMap(\.line).filter(\.isCommentable).map(\.id)
        var run = ReviewSelection()
        run.select(ids[0])
        run.extend(to: ids[1])

        let jump = try #require(stack.route(run, then: .compose))
        #expect(jump.fileID == Self.second.id)
        #expect(jump.start == ids[0] - section.idOffset && jump.end == ids[1] - section.idOffset, "in the file's own ids")
        #expect(jump.then == .compose)
        #expect(jump.fingerprint == Self.second.path)

        var crossing = ReviewSelection()
        crossing.select(2)
        crossing.extend(to: ids[1])
        #expect(stack.route(crossing)?.start == ids[1] - section.idOffset, "a run that crossed starts over where it reached")
        var inOpen = ReviewSelection()
        inOpen.select(2)
        #expect(stack.route(inOpen) == nil, "the open file is acted on as it is")
    }

    @Test func aJump_landsOnItsLines_unlessTheFileChanged() throws {
        let diff = try ReviewDiffFixture.rewritten(Self.second, lines: 2)
        let hunk = try #require(diff.lines.first { $0.kind == .hunk })
        let jump = ReviewJump(fileID: Self.second.id, start: 2, end: 3, then: .compose, fingerprint: diff.fingerprint)
        var moved = jump
        moved.fingerprint = "older"
        let comment = UUID()

        #expect(ReviewStackNavigation.landing(jump, in: diff) == .select(start: 2, end: 3, side: nil, composes: true))
        #expect(ReviewStackNavigation.landing(moved, in: diff) == .header, "the ids name other code now")
        #expect(ReviewStackNavigation.landing(
            ReviewJump(fileID: Self.second.id, start: 0, end: 0, then: .edit(comment), fingerprint: diff.fingerprint),
            in: diff
        ) == .edit(comment), "a comment is found by its id")
        #expect(ReviewStackNavigation.landing(
            ReviewJump(fileID: Self.second.id, start: 0, end: 0, then: .edit(comment), fingerprint: "older"),
            in: diff
        ) == .header, "written on another version: not about what is drawn now")
        #expect(ReviewStackNavigation.landing(
            ReviewJump(fileID: Self.second.id, start: hunk.id, end: hunk.id, then: .commentHunk(hunk.id)),
            in: diff
        ) == .commentHunk(hunk.id))
        #expect(ReviewStackNavigation.landing(
            ReviewJump(fileID: Self.second.id, start: 99, end: 99, then: .commentHunk(99)),
            in: diff
        ) == .header)
    }

    @Test func aWaitingJump_isKeptOnlyForTheFileItIsFor() {
        let asked = ReviewJump(fileID: "b", start: 1, end: 1)
        let waiting = ReviewJump(fileID: "a", start: 2, end: 2)

        #expect(ReviewStackNavigation.pending(opening: "b", asked: asked, waiting: waiting) == asked)
        #expect(
            ReviewStackNavigation.pending(opening: "a", asked: nil, waiting: waiting) == waiting,
            "a comment's file, chosen in the list"
        )
        #expect(ReviewStackNavigation.pending(opening: "c", asked: nil, waiting: waiting) == nil, "overtaken")
    }

    @Test func scrollingToAFile_opensIt_onlyWhenThereIsSomethingToActOn() throws {
        let readable = try ReviewStackEntry.loaded(ReviewDiffFixture.rewritten(Self.second))
        let binary = ReviewStackEntry.loaded(ReviewDiff(
            file: Self.second,
            fingerprint: "b",
            lines: [],
            notice: "This file can’t be reviewed as text."
        ))
        let failed = ReviewStackEntry.failed("This diff exceeds the review size limit.")
        let reader = ReviewStackNavigation.Reader(openFileID: Self.first.id)
        func reads(_ entry: ReviewStackEntry?, _ change: (inout ReviewStackNavigation.Reader) -> Void = { _ in }) -> Bool {
            var reader = reader
            change(&reader)
            return ReviewStackNavigation.readsOn(Self.second.id, reader: reader, entry: entry)
        }

        #expect(reads(readable))
        #expect(reads(nil), "a file not read yet is read as it opens")
        #expect(!reads(failed), "a failed read is not tried again on every stop")
        #expect(!reads(binary))
        #expect(!reads(readable) { $0.hasTextSelection = true }, "opening it would let go of the dragged text")
        #expect(!reads(readable) { $0.isComposerOpen = true })
        #expect(!reads(readable) { $0.hasPendingJump = true })
        #expect(!reads(readable) { $0.isLoading = true })
        #expect(!ReviewStackNavigation.readsOn(Self.first.id, reader: reader, entry: readable), "already open")
    }

    @Test func theFileBeingRead_isTheFirstUncheckedOneOnScreen() throws {
        let entries = try Self.all()
        let stack = try Self.stack(open: Self.first, entries: entries, viewed: [Self.second.id])
        let second = try #require(stack.section(of: Self.second.id))
        let third = try #require(stack.section(of: Self.third.id))

        #expect(stack.readingFile(probe: 1, bottom: 3) == Self.first.id)
        #expect(
            stack.readingFile(probe: second.headerRow, bottom: third.headerRow + 1) == Self.third.id,
            "a folded file has nothing to open"
        )
        #expect(stack.readingFile(probe: second.headerRow, bottom: second.headerRow) == nil)
        #expect(stack.readingFile(probe: -1, bottom: 3) == nil)
    }
}
