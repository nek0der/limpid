// ReviewTests.swift
// Limpid — review parsing, persistence, and paste-validation regressions.

import AppKit
import Foundation
import Testing
@testable import Limpid

struct ReviewTests {
    @MainActor
    @Test func presentationOpensAndClosesWithoutPersistingIntoSession() {
        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/review")

        let originPaneID = UUID()

        presentation.open(directory, originPaneID: originPaneID)
        #expect(presentation.directory == directory)
        #expect(presentation.isPresented)
        #expect(presentation.originPaneID == originPaneID)
        #expect(!presentation.isStripCollapsed)

        presentation.insertedPaneID = UUID()
        presentation.close()
        #expect(presentation.directory == nil)
        #expect(!presentation.isPresented)
        #expect(presentation.originPaneID == nil)
        #expect(presentation.insertedPaneID != nil)
    }

    @MainActor
    @Test func stripResizesWithinTheWindowAndCollapsesToNoPane() {
        let presentation = ReviewPresentation()
        presentation.open(URL(fileURLWithPath: "/tmp/review"), originPaneID: UUID())

        presentation.toggleStrip()
        // Collapsed renders no pane rather than a zero-height one, which is
        // what keeps libghostty from handing the agent's tty a new size.
        #expect(presentation.isStripCollapsed)
        #expect(presentation.stripHeight(in: 900) == nil)
        presentation.toggleStrip()
        #expect(presentation.stripHeight(in: 900) != nil)

        presentation.resizeStrip(to: 10, in: 900)
        #expect(presentation.stripHeight == ReviewStrip.minimum)
        presentation.resizeStrip(to: 5000, in: 900)
        #expect(presentation.stripHeight == 720)
        // Dragging the divider is also how the pane comes back.
        presentation.isStripCollapsed = true
        presentation.resizeStrip(to: 300, in: 900)
        #expect(!presentation.isStripCollapsed && presentation.stripHeight == 300)
    }

    @MainActor
    @Test func togglePutsReviewAwayAndFollowsAnotherWorktree() {
        let presentation = ReviewPresentation()
        let first = URL(fileURLWithPath: "/tmp/review")
        let second = URL(fileURLWithPath: "/tmp/other")
        let pane = UUID()

        presentation.toggle(first, originPaneID: pane)
        #expect(presentation.isPresented)
        // The entry point is one control, so a second press has to close it.
        presentation.toggle(first, originPaneID: pane)
        #expect(!presentation.isPresented)

        presentation.toggle(first, originPaneID: pane)
        presentation.toggle(second, originPaneID: pane)
        #expect(presentation.directory == second)

        presentation.resizeStrip(to: 310, in: 900)
        presentation.retarget(first, originPaneID: pane)
        #expect(presentation.directory == first)
        // Retargeting follows the user; the strip height is theirs to keep.
        #expect(presentation.stripHeight == 310)

        presentation.close()
        presentation.retarget(second, originPaneID: pane)
        #expect(!presentation.isPresented)
    }

    /// The composer draws the comment it is editing, and a comment written
    /// against a diff that has moved on is not about the line it used to sit
    /// under. Neither may appear beside the code.
    @Test func rowsHideTheCommentBeingEditedAndTheOnesThatNoLongerMatch() {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let lines = [
            ReviewLine(id: 0, kind: .context, text: "one", oldLine: 1, newLine: 1),
            ReviewLine(id: 1, kind: .added, text: "two", oldLine: nil, newLine: 2)
        ]
        let diff = ReviewDiff(file: file, fingerprint: "f", lines: lines, notice: nil)
        let editing = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 0, oldLine: 1, newLine: 1),
            code: "one", body: "being edited"
        )
        let stale = ReviewComment(
            file: file, fingerprint: "old",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 2),
            code: "two", body: "written against an older diff"
        )
        let kept = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 2),
            code: "two", body: "still current"
        )

        let rows = ReviewRowBuilder.rows(
            expanded: diff,
            comments: [editing, stale, kept],
            composerLineID: nil,
            editingCommentID: editing.id,
            staleCommentIDs: [stale.id]
        )
        let bodies = rows.compactMap { row -> String? in
            if case let .comment(comment) = row.kind {
                return comment.body
            }
            return nil
        }
        #expect(bodies == ["still current"])
    }

    /// A window too short to hold the terminal renders no pane at all rather
    /// than a zero-height one, which would hand the agent's tty a new size.
    @Test func stripHasNoHeightInAWindowThatCannotHoldIt() {
        #expect(ReviewStrip.height(240, isCollapsed: false, in: ReviewStrip.minimum) == nil)
        #expect(ReviewStrip.height(240, isCollapsed: false, in: 400) == 240)
        // Never more than four fifths of the window, so the diff keeps a share.
        #expect(ReviewStrip.height(5000, isCollapsed: false, in: 900) == 720)
    }

    /// The list the rail draws and the list `n` / `p` walk are one list. They
    /// were two: the keys stepped through layer-then-path order while the tree
    /// showed directory order, so in tree mode they jumped around the rail
    /// rather than down it.
    @Test func fileOrderIsTheOrderTheRailDraws() {
        let files = [
            ReviewFile(path: "b/two.swift", layer: .unstaged, status: .modified),
            ReviewFile(path: "a/one.swift", layer: .untracked, status: .untracked),
            ReviewFile(path: "a/three.swift", layer: .staged, status: .modified)
        ]
        #expect(ReviewFileTree.ordered(files, isTree: true).map(\.path) == [
            "a/one.swift", "a/three.swift", "b/two.swift"
        ])
        // Flat is the rail's section order, which is how the layers are
        // declared — not how their raw values sort.
        #expect(ReviewFileTree.ordered(files, isTree: false).map(\.layer) == [
            .staged, .unstaged, .untracked
        ])
    }

    /// The list goes away rather than pushing the diff out of the window.
    @Test func theFileListYieldsWhenThereIsNoRoomForBoth() {
        #expect(ReviewRail.width(232, in: 900) == 232)
        // Wide enough for both, but not for the width that was asked for.
        #expect(ReviewRail.width(400, in: 640) == 640 - ReviewRail.diffMinimum)
        // Not wide enough for the list and a readable diff together.
        #expect(ReviewRail.width(232, in: 500) == nil)
    }

    /// The tree groups by the directory that holds each file, and the files at
    /// the repository root group under an empty path.
    @Test func fileRailGroupsFilesByTheirDirectory() {
        let files = [
            ReviewFile(path: "README.md", layer: .unstaged, status: .modified),
            ReviewFile(path: "Limpid/App/LimpidApp.swift", layer: .unstaged, status: .modified),
            ReviewFile(path: "Limpid/App/Scene.swift", layer: .staged, status: .modified)
        ]
        let groups = ReviewFileTree.directories(files)
        // Explicit closure rather than a key path: these are labeled tuples,
        // and `\.path` on one compiles but crashes the test host.
        // swiftformat:disable:next preferKeyPath
        #expect(groups.map { $0.path } == ["", "Limpid/App"])
        #expect(groups[1].files.count == 2)
        #expect(ReviewFileTree.name("Limpid/App/LimpidApp.swift") == "LimpidApp.swift")
        #expect(ReviewFileTree.parent("Limpid/App/LimpidApp.swift") == "Limpid/App")
        #expect(ReviewFileTree.parent("README.md") == nil)
    }

    /// What a row says besides its name, for a reader who cannot see it.
    @Test func fileRowSummaryNamesTheLayerCountsAndFeedback() {
        let summary = ReviewFileTree.summary(
            layer: .unstaged,
            stat: ReviewFileStat(added: 3, removed: 1),
            comments: 2
        )
        #expect(summary == [ReviewLayer.unstaged.title, "+3 −1", String(localized: "\(2) comments")].joined(separator: ", "))
        #expect(ReviewFileTree.summary(layer: .staged, stat: ReviewFileStat(added: -1, removed: -1), comments: 0)
            == [ReviewLayer.staged.title, String(localized: "binary")].joined(separator: ", "))
        #expect(ReviewFileTree.summary(layer: .untracked, stat: nil, comments: 0) == ReviewLayer.untracked.title)
    }

    @Test func commentCoversARunOfLinesEndToEnd() throws {
        try ReviewValidationScenarios.ranges()
    }

    @Test func sideBySidePairsTheSameLinesTheUnifiedLayoutShows() throws {
        try ReviewValidationScenarios.sideBySide()
    }

    @Test func tmuxClientAndPaneResolutionParseTmuxOutput() throws {
        try ReviewValidationScenarios.tmuxDelivery()
    }

    @Test func rowListDropsFileMetadataAndPlacesCommentsOnTheirLine() throws {
        try ReviewValidationScenarios.rows()
    }

    @Test func numstatParsesRenamesAndBinaryCounts() throws {
        try ReviewValidationScenarios.numstat()
    }

    @Test func composerDoesNotCarryAnAbandonedEditIntoTheNextComment() throws {
        try ReviewValidationScenarios.composer()
    }

    @Test func unifiedDiffPreservesBothSidesAndUnusualPaths() throws {
        try ReviewValidationScenarios.parser()
    }

    @Test func reviewPromptQuotesPathsAndRejectsControlSequences() throws {
        try ReviewValidationScenarios.prompt()
    }

    @Test func gitSeparatesStagedUnstagedAndUntrackedChanges() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.git(at: directory) }
    }

    @Test func aCommitAgesOutStagedFingerprintsOnly() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.fingerprints(at: directory) }
    }

    @Test func branchViewCarriesCommittedAndUncommittedWorkTogether() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.branchScope(at: directory) }
    }

    @MainActor
    @Test func sendingAndResolvingAreSeparateStates() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.lifecycle(at: directory) }
    }

    @Test func theLexerColorsWholeWordsOnly() throws {
        try ReviewValidationScenarios.syntax()
    }

    @Test func gapsUnfoldWithoutMovingThePatch() throws {
        try ReviewValidationScenarios.expansion()
    }

    @MainActor
    @Test func aReadMarkComesOffWhenTheFileChanges() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.viewMarks(at: directory) }
    }

    @MainActor
    @Test func draftsSurviveRestartAndRejectStaleSnapshots() async throws {
        try await withTempDir { @Sendable directory in try await ReviewValidationScenarios.persistence(at: directory) }
    }

    /// Repository content is quoted for the agent rather than encoded for it.
    /// Only what could be read as this prompt's own markup is substituted, so
    /// an agent searching the prompt for a symbol finds the string the file
    /// holds.
    @Test func quotedCodeReachesTheAgentAsTheFileWroteIt() throws {
        let file = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 1, oldLine: 1, newLine: 1), end: nil,
            code: #"let a: Array<Int> = [] // </code> && <T>"#, body: "Why an array?"
        )
        let prompt = try ReviewPromptBuilder.build(root: URL(fileURLWithPath: "/tmp/x"), comments: [comment]).text
        #expect(prompt.contains("Array<Int>"))
        #expect(prompt.contains("&&"))
        #expect(prompt.contains("<T>"))
        // What could end the quote early is the one thing that cannot go
        // through as it stands.
        #expect(!prompt.contains("// </code>"))
        #expect(prompt.contains("// &lt;/code>"))
    }

    /// A scalar that draws as nothing does not make a closing tag any less of
    /// one. The agent reads the prompt as it is rendered, and a joiner between
    /// `<` and `/` puts an identical mark on screen — so the escape has to read
    /// past what it cannot see, not match a literal pair.
    @Test func aClosingTagCannotBeHiddenBehindAZeroWidthScalar() throws {
        let file = ReviewFile(path: "a.html", layer: .unstaged, status: .modified)
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 1, oldLine: 1, newLine: 1), end: nil,
            code: "x <\u{200D}/code> y <\u{200D}!\u{200D}-- z",
            body: "Check the markup."
        )
        let prompt = try ReviewPromptBuilder.build(root: URL(fileURLWithPath: "/tmp/x"), comments: [comment]).text
        #expect(!prompt.contains("x <\u{200D}/code>"))
        #expect(prompt.contains("x &lt;\u{200D}/code>"))
        #expect(prompt.contains("y &lt;\u{200D}!\u{200D}--"))
        // The one closing tag in the block is the one the builder wrote.
        #expect(prompt.components(separatedBy: "</code>").count == 2)
    }

    /// A comment names a span of line numbers, and a span is only true of a run
    /// that is contiguous in the file. Two hunks sit one row apart on screen
    /// and hundreds of lines apart in the file, so a run that crossed the `@@`
    /// between them would tell the agent to read everything in between.
    @Test func aRunCannotReachFromOneHunkIntoTheNext() throws {
        let patch = """
        @@ -10,1 +10,2 @@
        -oldA
        +newA
        +newA2
        @@ -500,1 +500,1 @@
        -oldB
        +newB
        """
        let lines = try ReviewDiffParser.parse(patch)
        let hunks = lines.filter(\.isCommentable).map(\.hunkIndex)
        #expect(hunks == [0, 0, 0, 1, 1])
        let first = try #require(lines.first { $0.isCommentable && $0.hunkIndex == 0 })
        let last = try #require(lines.last { $0.isCommentable && $0.hunkIndex == 0 })
        let across = try #require(lines.first { $0.isCommentable && $0.hunkIndex == 1 })
        #expect(ReviewRunBounds.canExtend(lines, from: first.id, to: last.id))
        #expect(!ReviewRunBounds.canExtend(lines, from: first.id, to: across.id))
        // Backwards is the same run seen from the other end.
        #expect(!ReviewRunBounds.canExtend(lines, from: across.id, to: first.id))
        // A run that has not started anywhere has nothing to be held inside.
        #expect(ReviewRunBounds.canExtend(lines, from: nil, to: across.id))
        // The split layout draws the same lines in two columns, and the rule
        // has to answer for both of them.
        let split = ReviewRowBuilder.rows(
            expanded: ReviewDiff(
                file: ReviewFile(path: "a.swift", layer: .unstaged, status: .modified),
                fingerprint: "f",
                lines: lines
            ),
            comments: [],
            composerLineID: nil,
            layout: .sideBySide
        )
        let pairs = split.compactMap { row -> ReviewSplitPair? in
            if case let .splitCode(pair) = row.kind {
                return pair
            }
            return nil
        }
        #expect(!pairs.isEmpty)
        for pair in pairs where pair.old != nil && pair.new != nil {
            #expect(pair.old?.hunkIndex == pair.new?.hunkIndex)
        }
        let newLines = pairs.compactMap(\.new)
        let firstNew = try #require(newLines.first { $0.hunkIndex == 0 })
        let lastNew = try #require(newLines.last { $0.hunkIndex == 0 })
        #expect(firstNew.id != lastNew.id)
        #expect(ReviewRunBounds.canExtend(newLines, from: firstNew.id, to: lastNew.id))
        let acrossNew = try #require(newLines.first { $0.hunkIndex == 1 })
        #expect(!ReviewRunBounds.canExtend(newLines, from: firstNew.id, to: acrossNew.id))
    }

    /// The names a stored draft is read by, written out rather than derived
    /// from the type.
    ///
    /// `ReviewComment` and `ReviewDraft` code themselves through synthesized
    /// keys, so every property name is part of the file format: renaming one
    /// compiles, passes every test that saves and reloads through the store,
    /// and orphans the drafts already on disk. This decodes a draft written by
    /// hand in the shape the store claims to read, so a rename fails here
    /// instead.
    @MainActor
    @Test func aDraftIsReadByTheNamesItWasWrittenWith() throws {
        try withTempDir { directory in
            let root = URL(fileURLWithPath: "/tmp/limpid-review-schema")
            let drafts = FileReviewDraftStore(directory: directory)
            let json = """
            {
              "version": 1,
              "comments": [
                {
                  "id": "8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21",
                  "file": {
                    "path": "Limpid/App/LimpidApp.swift",
                    "layer": "unstaged",
                    "status": "M"
                  },
                  "fingerprint": "abc123",
                  "anchor": { "lineID": 7, "newLine": 12 },
                  "code": "let x = 1",
                  "body": "Why 1?"
                }
              ]
            }
            """
            try Data(json.utf8).write(to: FileReviewDraftStore.url(root: root, directory: directory))

            let draft = try #require(try drafts.load(root: root))
            let comment = try #require(draft.comments.first)
            #expect(comment.file.path == "Limpid/App/LimpidApp.swift")
            #expect(comment.file.layer == .unstaged)
            #expect(comment.file.status == .modified)
            #expect(comment.fingerprint == "abc123")
            #expect(comment.lineID == 7)
            #expect(comment.anchor.newLine == 12)
            #expect(comment.anchor.oldLine == nil)
            #expect(comment.code == "let x = 1")
            #expect(comment.body == "Why 1?")
            // A single-line comment, a comment in the unified layout and a
            // comment nobody has acted on all read as absent keys rather than
            // as a file the store has to refuse.
            #expect(comment.end == nil)
            #expect(comment.side == nil)
            #expect(comment.codeMarkers == nil)
            #expect(comment.insertedAt == nil)
            #expect(comment.resolvedAt == nil)
            #expect(draft.viewed == nil)
            // A draft written before review remembered where the reader was
            // has no key for it, and reading it must not be how that draft
            // stops loading.
            #expect(draft.lastFileID == nil)
        }
    }

    /// A draft this build cannot read is refused rather than read partly.
    ///
    /// Two ways that happens, and both have to fail. A draft in the shape that
    /// was stored earlier in development — a comment's position spread across
    /// `rowID` and `endOldLine` rather than gathered into an anchor — is
    /// missing keys the current shape requires. A draft naming a version this
    /// build does not know cannot be trusted at all, whatever its keys say.
    /// Either way the reader is told, and the file is kept.
    @MainActor
    @Test func aDraftThisBuildCannotReadIsRefused() throws {
        try withTempDir { directory in
            let drafts = FileReviewDraftStore(directory: directory)

            let oldShape = URL(fileURLWithPath: "/tmp/limpid-review-old-shape")
            try Data("""
            {
              "version": 1,
              "comments": [
                {
                  "id": "DF807E9F-D560-41FB-9F4F-5AD0374FC076",
                  "file": { "path": "a.swift", "layer": "unstaged", "status": "M" },
                  "fingerprint": "abc123",
                  "rowID": 8,
                  "endRowID": 10,
                  "oldLine": 194,
                  "endOldLine": 196,
                  "code": "let x = 1",
                  "body": "Explain this."
                }
              ]
            }
            """.utf8).write(to: FileReviewDraftStore.url(root: oldShape, directory: directory))
            #expect(throws: ReviewError.self) { try drafts.load(root: oldShape) }

            let futureVersion = URL(fileURLWithPath: "/tmp/limpid-review-future")
            try Data("""
            { "version": 99, "comments": [] }
            """.utf8).write(to: FileReviewDraftStore.url(root: futureVersion, directory: directory))
            #expect(throws: ReviewError.self) { try drafts.load(root: futureVersion) }
        }
    }

    /// What the store does when the repository answers badly.
    ///
    /// A real repository cannot be made to fail one file's diff and not
    /// another's, or to lose a file between two reads, which is why none of
    /// this could be written down before the store took its reads as a port.
    @MainActor
    @Test func aFileThatFailsToLoadLeavesTheRestOfTheReviewAlone() async throws {
        let repository = FakeReviewRepository()
        let good = ReviewFile(path: "good.swift", layer: .unstaged, status: .modified)
        let bad = ReviewFile(path: "bad.swift", layer: .unstaged, status: .modified)
        repository.files = [good, bad]
        repository.diffs[good.id] = try ReviewDiff(
            file: good,
            fingerprint: "g1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        repository.failingDiffs = [bad.id]
        let store = withTempStore(git: repository)
        await store.refresh()
        #expect(store.files.count == 2)
        // Opened once so there is a completed snapshot to preserve while the
        // next file is being read.
        await store.load(good)
        #expect(store.diff?.fingerprint == "g1")
        await store.load(bad)
        // The failure is reported and the completed snapshot stays
        // authoritative: the rail still points at `good`, so replacing its
        // code with an empty intermediate state would be misleading.
        #expect(store.diff?.fingerprint == "g1")
        #expect(store.errorMessage != nil)
        #expect(store.files.count == 2)
        await store.load(good)
        #expect(store.diff?.fingerprint == "g1")
        #expect(store.errorMessage == nil)
        // A file that leaves the change list between two reads takes its
        // comments' anchor with it, and the store must not go on offering it.
        repository.files = [good]
        await store.refresh()
        #expect(store.files == [good])
    }

    /// What review hands over, and what it does when the pane will not take it.
    ///
    /// This path had no test at all: it ran through a `SurfaceView` and
    /// libghostty, so the only way to reach it was by hand. It is also the
    /// path that decides whether comments are recorded as inserted, which is
    /// the one mistake a reader cannot see.
    @MainActor
    @Test func aRefusedDeliveryLeavesNothingRecorded() throws {
        let registry = RecordingSurfaceRegistry()
        let paneID = UUID()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[paneID] = deliverer
        let destination = ReviewDestination(paneID: paneID, title: "zsh", foreground: "zsh")
        let receipt = ReviewPasteReceipt(root: URL(fileURLWithPath: "/tmp/x"), commentIDs: [UUID()])
        let prompt = try ReviewPrompt(validating: "<review></review>")
        try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        #expect(deliverer.delivered == ["<review></review>"])
        // The receipt travels with the text: it is what a later refusal uses
        // to find the comments again.
        #expect(deliverer.receipts.first??.commentIDs == receipt.commentIDs)
        // A pane that refuses reports it rather than swallowing it.
        deliverer.failure = ReviewError.targetUnavailable
        #expect(throws: ReviewError.self) {
            try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        }
        // A pane that is gone has no destination at all.
        registry.deliverers[paneID] = nil
        #expect(throws: ReviewError.self) {
            try ReviewAgents.insert(prompt, into: destination, registry: registry, receipt: receipt)
        }
    }

    /// The order an insert happens in, which is what keeps a comment from
    /// being recorded as delivered when it was not.
    @MainActor
    @Test func commentsAreRecordedOnlyAfterThePaneTookTheText() async throws {
        let fixture = WindowSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[fixture.paneID] = deliverer
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        repository.files = [file]
        repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "f1", lines: lines)
        let store = withTempStore(git: repository)
        await store.refresh()
        await store.load(file)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        store.add(line: line, body: "Explain this.")
        #expect(store.comments.count == 1)

        // A pane that refuses leaves the comment unmarked: the reader has to
        // be able to try again, and a mark would say the agent had been asked.
        deliverer.failure = ReviewError.targetUnavailable
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                store: store,
                to: ReviewInsertion.Target(
                    session: fixture.session,
                    registry: registry,
                    originPaneID: { fixture.paneID },
                    instructions: "",
                    isSameReview: { true }
                )
            )
        }
        #expect(store.comments.first?.insertedAt == nil)
        #expect(deliverer.delivered.isEmpty)

        deliverer.failure = nil
        let outcome = try await ReviewInsertion.run(
            store: store,
            to: ReviewInsertion.Target(
                session: fixture.session,
                registry: registry,
                originPaneID: { fixture.paneID },
                instructions: "",
                isSameReview: { true }
            )
        )
        #expect(outcome.paneID == fixture.paneID)
        #expect(outcome.held == 0)
        #expect(outcome.wasRecorded)
        #expect(store.comments.first?.insertedAt != nil)
        // The receipt names what this insert marked, so a refusal that arrives
        // later can take exactly those marks back.
        #expect(deliverer.receipts.first??.commentIDs == store.comments.map(\.id))

        // Review closing under the insert is a refusal, not a delivery: the
        // text must not reach the terminal and nothing may be recorded.
        // Asked as "is this the same review" rather than "is a review up":
        // closing and opening again on the same pane answered yes to the
        // second, which is the case the test below covers.
        let deliveredBefore = deliverer.delivered.count
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                store: store,
                to: ReviewInsertion.Target(
                    session: fixture.session,
                    registry: registry,
                    originPaneID: { fixture.paneID },
                    instructions: "",
                    isSameReview: { false }
                )
            )
        }
        #expect(deliverer.delivered.count == deliveredBefore)

        // The reader switching pane inside the wait is the same refusal. The
        // pane is read again on the far side of it, so a value captured before
        // the wait cannot be what the check compares.
        let elsewhere = UUID()
        registry.deliverers[elsewhere] = RecordingReviewDeliverer()
        var origin = fixture.paneID
        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                store: store,
                to: ReviewInsertion.Target(
                    session: fixture.session,
                    registry: registry,
                    originPaneID: {
                        defer { origin = elsewhere }
                        return origin
                    },
                    instructions: "",
                    isSameReview: { true }
                )
            )
        }
        #expect(deliverer.delivered.count == deliveredBefore)
    }

    /// A line whose content starts with a combining mark is still a line.
    ///
    /// The marker Git writes is one scalar; the mark that follows it joins to
    /// it into a single grapheme. Reading the first `Character` therefore
    /// matched neither `+` nor `-`, and one such line refused the whole file
    /// with `invalidDiff` — a file the reader could see in the list and never
    /// open.
    @Test func aLineStartingWithACombiningMarkIsParsed() throws {
        let lines = try ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-\u{0301}old\n+\u{0301}new")
        #expect(lines.count == 3)
        let removed = try #require(lines.first { $0.kind == .removed })
        let added = try #require(lines.first { $0.kind == .added })
        // The mark belongs to the content, not to the marker: dropping the
        // first `Character` would have taken it with the marker.
        #expect(removed.text == "\u{0301}old")
        #expect(added.text == "\u{0301}new")
        #expect(removed.oldLine == 1)
        #expect(added.newLine == 1)
    }

    /// Closing review and opening it again inside the insert's wait is a
    /// refusal.
    ///
    /// The presentation is what tells them apart: the pane is the same, and a
    /// review is on screen again by the time Git answers, so both of the other
    /// checks pass. Written against `ReviewPresentation` rather than a bare
    /// closure because what has to hold is that `open` makes a new opening —
    /// something a closure written here could not fail.
    @MainActor
    @Test func aReviewClosedAndOpenedAgainDoesNotTakeTheInsertItStarted() async throws {
        let fixture = WindowSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        let deliverer = RecordingReviewDeliverer()
        registry.deliverers[fixture.paneID] = deliverer
        let repository = FakeReviewRepository()
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [file]
        repository.diffs[file.id] = try ReviewDiff(
            file: file,
            fingerprint: "f1",
            lines: ReviewDiffParser.parse("@@ -1,1 +1,1 @@\n-old\n+new")
        )
        let store = withTempStore(git: repository)
        await store.refresh()
        await store.load(file)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        store.add(line: line, body: "Explain this.")

        let presentation = ReviewPresentation()
        let directory = URL(fileURLWithPath: "/tmp/limpid-review-root")
        presentation.open(directory, originPaneID: fixture.paneID)
        let opening = presentation.opening
        // What the reader does inside the wait.
        presentation.close()
        presentation.open(directory, originPaneID: fixture.paneID)

        await #expect(throws: ReviewError.self) {
            try await ReviewInsertion.run(
                store: store,
                to: ReviewInsertion.Target(
                    session: fixture.session,
                    registry: registry,
                    originPaneID: { fixture.paneID },
                    instructions: "",
                    isSameReview: { presentation.opening == opening }
                )
            )
        }
        #expect(deliverer.delivered.isEmpty)
        #expect(store.comments.first?.insertedAt == nil)
        // Retargeting is not that: the same opening looking at another
        // worktree still belongs to the reader who pressed Insert.
        let liveOpening = presentation.opening
        presentation.retarget(URL(fileURLWithPath: "/tmp/limpid-review-other"), originPaneID: fixture.paneID)
        #expect(presentation.opening == liveOpening)
        let retargeted = presentation.opening
        presentation.retarget(directory, originPaneID: fixture.paneID)
        #expect(presentation.opening == retargeted)
    }

    /// A paste that nobody claims reports itself as refused.
    ///
    /// The clipboard path answers across two main-queue hops, and every early
    /// return inside them used to have to remember to report a delivery that
    /// never happened. Reporting is the default now, and this is what says so:
    /// dropping a delivery is the same as refusing it, claiming it is not, and
    /// neither can happen twice.
    @MainActor
    @Test func aDeliveryNobodyClaimsReportsItselfAsRefused() {
        let root = URL(fileURLWithPath: "/tmp/x")
        let receipt = ReviewPasteReceipt(root: root, commentIDs: [UUID()])
        var refusals: [ReviewPasteReceipt] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .limpidReviewPasteDenied,
            object: nil,
            queue: .main
        ) { note in
            guard let refused = note.object as? ReviewPasteReceipt else { return }
            MainActor.assumeIsolated { refusals.append(refused) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Dropped: the pane died before anything could take it.
        ReviewPasteDelivery(receipt: receipt).failIfUnsettled()
        #expect(refusals.count == 1)
        #expect(refusals.first?.commentIDs == receipt.commentIDs)

        // Landed: the terminal took the text, so there is nothing to take back.
        let landed = ReviewPasteDelivery(receipt: receipt)
        landed.landed()
        landed.failIfUnsettled()
        #expect(refusals.count == 1)

        // Handed on: the sheet owns the answer now, and reports its own.
        let handed = ReviewPasteDelivery(receipt: receipt)
        #expect(handed.handedOn()?.commentIDs == receipt.commentIDs)
        handed.failIfUnsettled()
        #expect(refusals.count == 1)

        // Reported once however many ways out run.
        let dropped = ReviewPasteDelivery(receipt: receipt)
        dropped.failIfUnsettled()
        dropped.failIfUnsettled()
        #expect(refusals.count == 2)

        // A paste with no receipt is not a review paste and answers for
        // nothing.
        ReviewPasteDelivery(receipt: nil).failIfUnsettled()
        #expect(refusals.count == 2)
    }

    /// A file name is repository content, and Git hands paths through as bytes.
    /// A quote in one used to close the attribute it was written into, because
    /// the escape walked grapheme clusters and a quote joined to the next
    /// scalar is one cluster.
    @Test func aFileNameCannotCloseTheAttributeItIsWrittenInto() throws {
        let file = ReviewFile(path: "ok.swift\u{200D}\" lines=\u{200D}\"9-9", layer: .unstaged, status: .modified)
        let comment = ReviewComment(
            file: file, fingerprint: "f",
            anchor: ReviewAnchor(lineID: 1, oldLine: 1, newLine: 1), end: nil,
            code: "let a = 1", body: "Why?"
        )
        let prompt = try ReviewPromptBuilder.build(root: URL(fileURLWithPath: "/tmp/x"), comments: [comment]).text
        // Three attributes on the comment element, so three quoted values plus
        // the element's own two: any raw quote from the path would add more.
        #expect(prompt.contains("&quot;"))
        #expect(!prompt.contains("lines=\u{200D}\""))
    }

    /// A file can hold what must never reach a terminal. Refusing it would
    /// leave a comment the reader could write and never send, on code they do
    /// not own, so it is replaced instead — in the diff and in the prompt
    /// alike, because the two disagreeing about what the code says is the
    /// whole risk. The prompt is checked from a draft that never went through
    /// the parser, which is what a draft saved before this existed looks like.
    @Test func textThatCannotReachATerminalIsReplacedRatherThanRefused() throws {
        let patch = "@@ -1,1 +1,1 @@\n-old\n+let s = \"a\u{202E}b\"\n"
        let added = try #require(try ReviewDiffParser.parse(patch).first { $0.kind == .added })
        #expect(!added.text.unicodeScalars.contains("\u{202E}"))
        #expect(added.text.contains("\u{FFFD}"))
        let comment = ReviewComment(
            file: ReviewFile(path: "a.swift", layer: .unstaged, status: .modified),
            fingerprint: "f",
            anchor: ReviewAnchor(lineID: added.id, oldLine: nil, newLine: 1), end: nil,
            code: "let s = \"a\u{202E}b\"", body: "Check this string."
        )
        let prompt = try ReviewPromptBuilder.build(root: URL(fileURLWithPath: "/tmp/x"), comments: [comment]).text
        #expect(!prompt.unicodeScalars.contains("\u{202E}"))
        #expect(prompt.contains("\u{FFFD}"))
    }

    // The terminal probe — which process is in front of the pane review writes
    // to — is `ReviewProbeScenarios.foreground()`, and it runs in
    // `scripts/validate-review-core.sh` rather than here. It spawns processes,
    // and this suite runs in parallel: the pipes it opens reuse the file
    // descriptor number `SettingsFileWatcherTests` asserts is closed, failing
    // an unrelated test that is correct about its own subject. It is the only
    // scenario that script runs; everything else the review core promises is
    // asserted in this target.
}

@MainActor
struct ReviewKeyboardRoutingTests {
    @Test func findRoutesToReviewWithoutStartingTerminalSearch() {
        let fixture = WindowSessionFixture.withLooseTab()
        let session = fixture.session
        let presentation = ReviewPresentation()
        let registry = RecordingSurfaceRegistry()
        presentation.open(URL(fileURLWithPath: "/tmp/review-find"), originPaneID: fixture.paneID)
        var actions: [LimpidShortcutAction] = []
        let observer = NotificationCenter.default.addObserver(forName: .limpidReviewFind, object: nil, queue: .main) { note in
            guard let owner = note.object as? WindowSession,
                  let action = note.userInfo?["action"] as? LimpidShortcutAction else { return }
            MainActor.assumeIsolated {
                if owner === session {
                    actions.append(action)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for action in [LimpidShortcutAction.find, .findNext, .findPrevious] {
            ReviewPresentationCommand.find(action, session: session, presentation: presentation, registry: registry)
        }
        #expect(actions == [.find, .findNext, .findPrevious])
        #expect(session.paneSearchStates.isEmpty)
        presentation.close()
        ReviewPresentationCommand.find(.find, session: session, presentation: presentation, registry: registry)
        #expect(session.paneSearchStates[fixture.paneID] != nil)
    }

    @Test func reviewInsertShortcutRequiresCommandReturn() throws {
        let combinations: [NSEvent.ModifierFlags] = [.command, [.command, .shift], [.command, .option], [], .option]
        for modifiers in combinations {
            let candidate = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
            let event = try #require(candidate)
            #expect((ReviewTableKey(event: event) == .insert) == (modifiers == .command))
            let table = ReviewTableView()
            var handled = false
            table.onKey = { _ in handled = true
                return true
            }
            _ = table.performKeyEquivalent(with: event)
            #expect(!handled)
        }
    }

}
