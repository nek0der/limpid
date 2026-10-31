// ReviewCommentHeldTests.swift
// Weir — a comment being written as the diff, the tab's place, and its owner change under it.

import Foundation
import Testing
@testable import Weir

/// The rules a comment being written in a review follows, whether the review
/// stayed open or came back with its tab: it follows its code, it is set
/// aside in the banner where it cannot, and nothing drops it unseen; the
/// tab that brought it back is not closed by the switch; the owner of a
/// review is the one it was last opened from.
@MainActor
struct ReviewCommentHeldTests {
    typealias Fixture = ProjectWindowsFixture

    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
    private static let other = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)

    // MARK: - The switch that brings a tab back

    @Test func theRowRule_keepsAnArrival_putsAHeldCommentBehind_andClosesTheRest() {
        #expect(ReviewTabActions.rowChange(hasReview: false, isArrival: false, holdsComment: false) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: true, holdsComment: false) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: true, holdsComment: true) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: false, holdsComment: true) == .putBehind)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: false, holdsComment: false) == .close)
    }

    @Test func aTabBroughtBackBehind_isNotClosedByTheSwitch_butByTheNextMove() throws {
        let fixture = Fixture()
        var tab = try ProjectWindowsFixture.review()
        tab.isShown = false
        fixture.primary.review = tab

        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        // The row the switch lands on is the arrival.
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        // The person moves on: the usual rule, with nothing held.
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .close)
    }

    // MARK: - The diff changing under a comment

    private static let written = "@@ -1,2 +1,3 @@\n keep\n+let added = 1\n tail"
    private static let moved = "@@ -1,3 +1,4 @@\n head\n keep\n+let added = 1\n tail"

    @Test func aQuoteNeverSpansTwoChangedBlocks_inAColumn() throws {
        let patch = "@@ -1,2 +1,2 @@\n-old1\n+new1\n }\n@@ -20,2 +20,2 @@\n }\n-old2\n+new2"
        let diff = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f", patch: patch)
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f0",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            side: .new,
            code: "}\n}",
            codeMarkers: "  ",
            body: "Why?"
        )

        #expect(ReviewCommentRelocation.placement(of: comment, in: diff, scopeID: "s") == .notFound)
    }

    @Test func aLargeRun_followsWhole() throws {
        let lines = (0..<120).map { "+let value\($0) = \"\(String(repeating: "x", count: 40))\"" }
        let old = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f1",
            patch: "@@ -1,1 +1,121 @@\n keep\n" + lines.joined(separator: "\n")
        )
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,2 +1,122 @@\n head\n keep\n" + lines.joined(separator: "\n")
        )
        let composer = try ReviewDiffFixture.composer(on: old)
        let added = new.lines.filter { $0.kind == .added }

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("not moved")
            return
        }
        #expect(moved.startLineID == added.first?.id)
        #expect(moved.lineID == added.last?.id)
    }

    @Test func aLineLongerThanTheExcerpt_follows() throws {
        let long = String(repeating: "y", count: 3000)
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: "@@ -1,1 +1,2 @@\n keep\n+\(long)")
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,2 +1,3 @@\n head\n keep\n+\(long)")
        let composer = try ReviewDiffFixture.composer(on: old)

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("not moved")
            return
        }
        #expect(moved.lineID == new.lines.first { $0.kind == .added }?.id)
    }

    @Test func aCommentOnRemovedLinesOnly_follows_inTheUnifiedLayoutAndTheOldColumn() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: "@@ -1,3 +1,1 @@\n keep\n-gone one\n-gone two")
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,4 +1,2 @@\n head\n keep\n-gone one\n-gone two")
        let removed = new.lines.filter { $0.kind == .removed }
        for side in [ReviewSide?.none, .old] {
            let composer = try ReviewDiffFixture.composer(on: old, side: side) { $0.kind == .removed }
            guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
                Issue.record("not moved in \(String(describing: side))")
                continue
            }
            #expect(moved.startLineID == removed.first?.id)
            #expect(moved.lineID == removed.last?.id)
        }
    }

    @Test func anEditOpenedButUnchanged_justCloses_asTheDiffChanges() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        let line = try #require(old.lines.first { $0.kind == .added })
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: line.id, oldLine: nil, newLine: line.newLine),
            code: line.text,
            codeMarkers: "+",
            body: "Was"
        )
        var composer = ReviewComposerState()
        composer.edit(comment)

        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new, editedBody: "Was") == .closed)
        composer.text = "Was, and now"
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new, editedBody: "Was") == .setAside)
    }

    @Test func aCommentFollowsItsCode_asTheDiffChangesUnderIt() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        let composer = try ReviewDiffFixture.composer(on: old)
        let line = try #require(new.lines.first { $0.kind == .added })

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("not moved")
            return
        }
        #expect(moved.startLineID == line.id)
        #expect(moved.lineID == line.id)
        #expect(moved.text == "Why this?")
        #expect(line.id != composer.lineID)
        // The same diff, or nothing typed: nothing to do.
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: old) == .kept)
        #expect(ReviewComposerFollow.outcome(of: ReviewComposerState(), from: old, to: new) == .kept)
    }

    @Test func aCommentWhoseCodeWent_isSetAside() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let composer = try ReviewDiffFixture.composer(on: old)
        let changed = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,2 +1,3 @@\n keep\n+let added = 2\n tail")
        let twice = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f3",
            patch: "@@ -1,2 +1,4 @@\n keep\n+let added = 1\n+let added = 1\n tail"
        )
        let other = try ReviewDiffFixture.diff(
            of: ReviewFile(path: "b.swift", layer: .unstaged, status: .modified),
            fingerprint: "b",
            patch: Self.written
        )

        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: changed) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: twice) == .setAside)
        // The same code in another file is not where it was written.
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: other) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: nil) == .setAside)
    }

    @Test func anEditUnderWay_isSetAside_asTheDiffChanges() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        let line = try #require(old.lines.first { $0.kind == .added })
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: line.id, oldLine: nil, newLine: line.newLine),
            code: line.text,
            codeMarkers: "+",
            body: "Was"
        )
        var composer = ReviewComposerState()
        composer.edit(comment)
        composer.text = "Was, and now"

        // The comment stays on the code it was written on, out of date; the
        // text typed into it is offered, not moved somewhere else.
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: old) == .kept)
    }

    @Test func aCommentInOneColumn_followsItsLinesAcrossTheOtherColumns() throws {
        let patch = "@@ -1,3 +1,3 @@\n keep\n-old line\n+new line\n tail"
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: patch)
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,4 +1,4 @@\n head\n keep\n-old line\n+new line\n tail"
        )
        // The new column: the context line and the added one, with the
        // removed one between them in the unified order.
        let newSide = try ReviewDiffFixture.composer(on: old, side: .new) { $0.text == "keep" || $0.kind == .added }
        let added = try #require(new.lines.first { $0.kind == .added })
        let keep = try #require(new.lines.first { $0.text == "keep" })
        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: newSide, from: old, to: new) else {
            Issue.record("the new column's run did not follow")
            return
        }
        #expect(moved.startLineID == keep.id)
        #expect(moved.lineID == added.id)
        // The old column, a removed line after the context.
        let oldSide = try ReviewDiffFixture.composer(on: old, side: .old) { $0.text == "keep" || $0.kind == .removed }
        guard case .moved = ReviewComposerFollow.outcome(of: oldSide, from: old, to: new) else {
            Issue.record("the old column's run did not follow")
            return
        }
    }

    @Test func aCommentFromAnEarlierReview_inOneColumn_movesAcrossTheOtherColumns() throws {
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,4 +1,4 @@\n head\n keep\n-old line\n+new line\n tail"
        )
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            side: .new,
            code: "keep\nnew line",
            codeMarkers: " +",
            body: "Why?"
        )

        guard case let .placed(placed) = ReviewCommentRelocation.placement(of: comment, in: new, scopeID: "s") else {
            Issue.record("not placed")
            return
        }
        #expect(placed.lineID == new.lines.first { $0.text == "keep" }?.id)
        #expect(placed.lastLineID == new.lines.first { $0.kind == .added }?.id)
    }

    /// A review of `a.swift` reading `diff` as its open file.
    private static func review(reading diff: ReviewDiff) async throws -> (ReviewSession, FakeReviewRepository) {
        let repository = FakeReviewRepository()
        repository.files = [file]
        repository.diffs[file.id] = diff
        let review = ReviewSession(
            writer: ReviewDraftWriter(
                root: URL(fileURLWithPath: "/tmp/weir-held-\(UUID().uuidString)"),
                drafts: RecordingReviewDraftStore()
            ),
            git: repository
        )
        _ = await review.reload(scope: .uncommitted, selectedFileID: nil)
        #expect(review.diff?.fingerprint == diff.fingerprint)
        return (review, repository)
    }

    @Test func aReviewReadAgain_movesItsCommentWithTheCode() async throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let (review, repository) = try await Self.review(reading: old)
        review.composer = try ReviewDiffFixture.composer(on: old)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        repository.diffs[Self.file.id] = new

        // The same read whether the review stayed open or its tab came back.
        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        let line = try #require(new.lines.first { $0.kind == .added })
        #expect(review.composer.startLineID == line.id)
        #expect(review.composer.text == "Why this?")
        #expect(review.unplacedComment == nil)
    }

    @Test func aReviewReadAgain_setsAsideACommentWhoseCodeWent() async throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let (review, repository) = try await Self.review(reading: old)
        review.composer = try ReviewDiffFixture.composer(on: old)
        repository.diffs[Self.file.id] = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,2 +1,3 @@\n keep\n+let added = 2\n tail"
        )

        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        #expect(!review.composer.isOpen)
        #expect(review.unplacedComment == "Why this?")
        // Held until it is copied or thrown away.
        #expect(review.holdsComment)
        review.unplacedComment = nil
        #expect(!review.holdsComment)
    }

    /// A review of `a.swift` and `b.swift`, read with `a.swift` open, from
    /// a repository that answers the stack as well as the review.
    private static func review(_ diffs: [ReviewDiff]) async throws -> (ReviewSession, StackReviewRepository) {
        let repository = StackReviewRepository(files: [file, other], diffs: diffs)
        let review = ReviewSession(
            writer: ReviewDraftWriter(
                root: URL(fileURLWithPath: "/tmp/weir-held-\(UUID().uuidString)"),
                drafts: RecordingReviewDraftStore()
            ),
            git: repository
        )
        _ = await review.reload(scope: .uncommitted, selectedFileID: file.id)
        return (review, repository)
    }

    @Test func anotherFileOpened_setsTheCommentAside_throughEveryWayAFileOpens() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)

        // By reading it.
        let (loaded, _) = try await Self.review([mine, theirs])
        #expect(loaded.diff?.file.id == Self.file.id)
        loaded.composer = try ReviewDiffFixture.composer(on: mine)
        await loaded.load(Self.other)
        #expect(loaded.diff?.file.id == Self.other.id)
        #expect(loaded.unplacedComment == "Why this?")
        #expect(!loaded.composer.isOpen)

        // From what the stack read of it.
        let (stacked, _) = try await Self.review([mine, theirs])
        stacked.stackLoader.request([ReviewStackLoader.Request(file: Self.other, scope: .uncommitted)], window: [Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { stacked.stackLoader.entries[Self.other.id] != nil }
        stacked.composer = try ReviewDiffFixture.composer(on: mine)
        #expect(stacked.openFromStack(Self.other) != nil)
        #expect(stacked.unplacedComment == "Why this?")
    }

    @Test func aReviewReadAgainOnTheSameDiff_keepsTheComment() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let (review, _) = try await Self.review([mine])
        let composer = try ReviewDiffFixture.composer(on: mine)
        review.composer = composer

        // What Refresh does, with nothing changed.
        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        #expect(review.composer == composer)
        #expect(review.unplacedComment == nil)
    }

    @Test func aCheckedOpenFile_isDrawnWhole_whileItsComposerIsOpen_andStillSaysItIsChecked() throws {
        #expect(ReviewStackBuilder.unfolded(openFileID: "a", isComposerOpen: true) == ["a"])
        #expect(ReviewStackBuilder.unfolded(openFileID: "a", isComposerOpen: false).isEmpty)
        #expect(ReviewStackBuilder.unfolded(openFileID: nil, isComposerOpen: true).isEmpty)

        let diff = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        func stack(unfolded: Set<String>) -> ReviewStack {
            var input = ReviewStackBuilder.Input(files: [Self.file], slots: [Self.file.id: 0])
            input.viewed = [Self.file.id]
            input.unfolded = unfolded
            input.open = diff
            input.openRows = ReviewRowBuilder.rows(expanded: diff, comments: [], composerLineID: nil)
            return ReviewStackBuilder.build(input) { _, diff, offset in
                ReviewStackPiece.closed(diff, offset: offset, comments: [], staleCommentIDs: [], layout: .unified)
            }
        }
        for (unfolded, rowCount) in [(Set<String>(), 1), ([Self.file.id], 1 + diff.lines.count)] {
            let drawn = stack(unfolded: unfolded)
            let row = try #require(drawn.headerRow(of: Self.file.id))
            guard case let .file(header) = drawn.rows[row].kind else {
                Issue.record("no header")
                continue
            }
            #expect(header.isViewed, "the check shows what is recorded")
            #expect(drawn.rows.count >= rowCount)
        }
        #expect(stack(unfolded: [Self.file.id]).rows.count > stack(unfolded: []).rows.count)
    }

    // MARK: - What holds the tab, and what it says

    @Test func theRefusal_saysWhatHoldsTheTab() throws {
        let fixture = Fixture()
        fixture.primary.review = try ProjectWindowsFixture.review()
        #expect(ReviewTabActions.heldCommentRefusal(fixture.primary) == nil)
        let review = fixture.primary.writeComment()
        #expect(ReviewTabActions.heldCommentRefusal(fixture.primary) == .unsavedComment)
        review.setComposerAside()
        #expect(ReviewTabActions.heldCommentRefusal(fixture.primary) == .unplacedCommentHeld)
        #expect(fixture.primary.reviewHasUnsavedComment)
        review.unplacedComment = nil
        #expect(ReviewTabActions.heldCommentRefusal(fixture.primary) == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        // Copied or thrown away from the banner, the tab closes.
        ReviewTabActions.close(
            window: fixture.primary,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: fixture.primary.id, registry: fixture.registry)
        )
        #expect(fixture.primary.review == nil)

        let ja = Locale(identifier: "ja")
        #expect(ReviewError.unplacedCommentHeld.message.resolved(in: ja) == "戻せなかったコメントを先にコピーするか破棄してください。")
        #expect(ReviewError.worktreeMoved.message.resolved(in: ja)
            == "このレビューのワークツリーは元の場所にありません。レビューを閉じて開き直してください。")
    }

    @Test func aSecondCommentSetAside_joinsTheFirst() throws {
        let fixture = Fixture()
        fixture.primary.review = try ProjectWindowsFixture.review()
        let review = fixture.primary.writeComment("First")
        review.setComposerAside()
        fixture.primary.writeComment("Second")

        review.setComposerAside()

        #expect(review.unplacedComment == "First\n\nSecond")
    }

    @Test func aCommentThatCannotGoBack_isToldInBothLanguages() {
        let message = LocalizedStringResource(
            "The comment you were writing couldn’t be put back where it was. Copy it to write it again."
        )
        #expect(message.resolved(in: Locale(identifier: "en"))
            == "The comment you were writing couldn’t be put back where it was. Copy it to write it again.")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "入力中のコメントを元の場所に戻せませんでした。コピーして書き直してください。")
    }

    // MARK: - A review that cannot open

    @Test func aReviewTabThatCannotOpen_offersItsComment_andDrawsNoOtherReview() throws {
        let failing = ProjectWindowState.reviewSession(root: "/repo")
        failing.composer = try ReviewDiffFixture.composer(on: ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written))
        guard case .cannotOpen = ReviewPaneOpening.choose(kept: failing, resolved: .failure(ReviewError.gitFailed))
        else {
            Issue.record("opened")
            return
        }
        // Deciding touches nothing; the surface sets the comment aside.
        #expect(failing.composer.text == "Why this?")
        failing.setComposerAside()
        #expect(failing.unplacedComment == "Why this?")
        #expect(!failing.composer.isOpen)

        // The worktree resolves to another repository: not the pool's
        // review in its place.
        let moved = ProjectWindowState.reviewSession(root: "/repo")
        moved.composer = failing.composer
        moved.composer.compose(start: 1, end: 1, side: nil)
        moved.composer.text = "Moved"
        guard case .cannotOpen = ReviewPaneOpening.choose(
            kept: moved,
            resolved: .success(URL(fileURLWithPath: "/elsewhere"))
        ) else {
            Issue.record("drew another review")
            return
        }
        #expect(moved.composer.text == "Moved")

        let kept = ProjectWindowState.reviewSession(root: "/repo")
        guard case let .kept(drawn) = ReviewPaneOpening.choose(
            kept: kept,
            resolved: .success(URL(fileURLWithPath: "/repo/"))
        ) else {
            Issue.record("not kept")
            return
        }
        #expect(drawn === kept)
    }

    // MARK: - The owner

    @Test func theLatestOpeningFromAPane_decidesTheOwner() throws {
        var context = ReviewTabModel.Context(turns: [], isViewed: { _ in false }, branchBase: nil)
        let scratchPane = UUID()
        let projectPane = UUID()
        context.isAgentPaneOfNoProject = true
        let opened = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: scratchPane, current: nil).get()
        #expect(opened.isOfNoProject)

        // The same worktree opened from no pane: the owner stays.
        context.isAgentPaneOfNoProject = false
        let again = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: nil, current: opened).get()
        #expect(again.opening == opened.opening)
        #expect(again.isOfNoProject)

        // From a project's pane: the project's from now on, the same tab.
        let reopened = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: projectPane, current: opened).get()
        #expect(reopened.opening == opened.opening)
        #expect(!reopened.isOfNoProject)
    }

    // MARK: - Composing over text

    private static func selection(_ start: Int, _ end: Int) -> ReviewSelection {
        var selection = ReviewSelection()
        selection.select(start)
        if end != start {
            selection.extend(to: end)
        }
        return selection
    }

    @Test func textBeingWritten_neverMovesToLinesItWasNotWrittenOn() {
        var composer = ReviewComposerState()
        composer.compose(start: 5, end: 6, side: nil)
        composer.text = "Why this?"
        let onComposer = Self.selection(5, 6)
        let elsewhere = Self.selection(20, 20)

        // A click elsewhere, then extending from there: it stays.
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: onComposer, to: elsewhere) == .keep)
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: elsewhere, to: Self.selection(20, 22)) == .keep)
        // Extending its own run carries it.
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: onComposer, to: Self.selection(5, 8)) == .retarget)
        // With nothing typed, a click elsewhere closes it, and extending carries it.
        composer.text = ""
        #expect(ReviewComposerSelection.change(of: composer, holdsText: false, from: onComposer, to: elsewhere) == .cancel)
        #expect(ReviewComposerSelection.change(of: composer, holdsText: false, from: onComposer, to: Self.selection(5, 8)) == .retarget)
    }

    @Test func theComposersRun_followsAnExtensionOfItsOwn_andNothingElse() {
        var composer = ReviewComposerState()
        composer.compose(start: 5, end: 6, side: nil)
        composer.text = "Why this?"

        // A second ⇧↓, then shrinking: each from the composer's own run.
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 6), to: Self.selection(5, 7)) == .retarget)
        composer.retarget(start: 5, end: 7, side: nil)
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 7), to: Self.selection(5, 8)) == .retarget)
        composer.retarget(start: 5, end: 8, side: nil)
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 8), to: Self.selection(5, 6)) == .retarget)

        // From nothing selected to its own line, then extended from there.
        var single = ReviewComposerState()
        single.compose(start: 9, end: 9, side: nil)
        single.text = "Here"
        #expect(ReviewComposerSelection.change(of: single, holdsText: true, from: ReviewSelection(), to: Self.selection(9, 9)) == .keep)
        #expect(ReviewComposerSelection
            .change(of: single, holdsText: true, from: Self.selection(9, 9), to: Self.selection(9, 11)) == .retarget)

        // An edit with new text stays where its comment is.
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f",
            anchor: ReviewAnchor(lineID: 5, oldLine: nil, newLine: 5),
            code: "x",
            body: "Was"
        )
        var edit = ReviewComposerState()
        edit.edit(comment)
        edit.text = "Was, and now"
        #expect(ReviewComposerSelection.change(of: edit, holdsText: true, from: Self.selection(5, 5), to: Self.selection(5, 7)) == .keep)

        // `c` on dragged text: the composer opened for the new run in the
        // same keystroke goes with it, with nothing typed yet.
        var opened = ReviewComposerState()
        opened.compose(start: 20, end: 22, side: nil)
        #expect(ReviewComposerSelection
            .change(of: opened, holdsText: false, from: Self.selection(5, 5), to: Self.selection(20, 22)) == .retarget)
    }

    @Test func anEditLeftAsItWas_holdsNothing() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let (review, _) = try await Self.review([mine])
        let line = try #require(review.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(review.add(line: line, body: "Saved"))
        let comment = try #require(review.comments.first)
        review.composer.edit(comment)

        #expect(!review.composerHoldsUnsavedText)
        #expect(!review.holdsComment)
        review.composer.text = "Saved, and more"
        #expect(review.composerHoldsUnsavedText)
        // A new comment with text always holds.
        review.composer.compose(start: line.id, end: line.id, side: nil)
        review.composer.text = "New"
        #expect(review.composerHoldsUnsavedText)
    }

    @Test func aKeptTabWhoseCommentWentMeanwhile_givesWay() throws {
        let fixture = Fixture()
        let window = fixture.primary
        window.review = try ProjectWindowsFixture.review()
        window.writeComment()
        let wentMeanwhile = try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        window.review = try ProjectWindowsFixture.review()
        window.reviewSession = nil
        window.writeComment()
        let written = try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        // A read that ended while the tab was kept let its comment go.
        wentMeanwhile.session?.composer.cancel()

        #expect(ParkedReview.tabs(written, joining: [wentMeanwhile]).map(\.review.opening) == [written.review.opening])
    }

    // MARK: - The stack of a review with a comment

    /// The hold a surface puts on `review`'s stack, as
    /// `ReviewWorkspaceView.holdStack` does.
    private static func hold(_ review: ReviewSession, isComposingInputMethodText: Bool) {
        review.stackLoader.hold(ReviewStackLoader.holdsPublishing(isComposingInputMethodText: isComposingInputMethodText))
    }

    @Test func aTabBackWithItsComment_readsItsOtherFilesAgain_withNothingMoreDone() async throws {
        let fixture = Fixture()
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, _) = try await Self.review([mine, theirs])
        let window = fixture.primary
        window.review = try ProjectWindowsFixture.review()
        window.reviewSession = review
        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { review.stackLoader.entries[Self.other.id] != nil }
        review.composer = try ReviewDiffFixture.composer(on: mine)
        // The composer is open, with no input method's text in it.
        Self.hold(review, isComposingInputMethodText: false)

        // To `b`, and back to `a`: the stack let go of, then drawn again.
        fixture.choose(fixture.bTab, in: window)
        #expect(review.stackLoader.entries.isEmpty)
        fixture.choose(fixture.aTab, in: window)
        #expect(window.reviewSession === review)

        // What the surface drawn again does: read the scope again on the
        // open file, hold as its composer says, and name the files on screen.
        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)
        Self.hold(review, isComposingInputMethodText: false)
        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { review.stackLoader.entries[Self.other.id] != nil }

        #expect(review.stackLoader.entries[Self.other.id]?.diff != nil)
        #expect(review.composer.text == "Why this?")
    }

    @Test func refreshWithACommentBeingWritten_readsTheOtherFilesAgain() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, _) = try await Self.review([mine, theirs])
        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { review.stackLoader.entries[Self.other.id] != nil }
        review.composer = try ReviewDiffFixture.composer(on: mine)
        Self.hold(review, isComposingInputMethodText: false)

        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)
        #expect(review.stackLoader.stale.contains(Self.other.id), "drawn until it is read again")
        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { !review.stackLoader.stale.contains(Self.other.id) }

        #expect(!review.stackLoader.stale.contains(Self.other.id))
        #expect(review.composer.text == "Why this?")
    }

    @Test func aReadWhileHeld_isWithheld_untilLetGo() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, _) = try await Self.review([mine, theirs])
        Self.hold(review, isComposingInputMethodText: true)

        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { review.stackLoader.isWaitingToPublish(Self.other.id) }

        #expect(review.stackLoader.isWaitingToPublish(Self.other.id), "read")
        #expect(review.stackLoader.entries[Self.other.id] == nil, "and not published")

        Self.hold(review, isComposingInputMethodText: false)

        #expect(review.stackLoader.entries[Self.other.id]?.diff != nil)
    }

    @Test func onlyAnInputMethodsText_holdsTheStack_andADrawingAgainLetsGo() async throws {
        #expect(ReviewStackLoader.holdsPublishing(isComposingInputMethodText: true))
        #expect(!ReviewStackLoader.holdsPublishing(isComposingInputMethodText: false))
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, _) = try await Self.review([mine, theirs])
        // The surface that went held for an input method's text.
        Self.hold(review, isComposingInputMethodText: true)
        review.releaseStack()

        review.resumeStack()
        review.loadStacked(window: [Self.file.id, Self.other.id])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { review.stackLoader.entries[Self.other.id] != nil }

        #expect(review.stackLoader.entries[Self.other.id]?.diff != nil)
    }
}
