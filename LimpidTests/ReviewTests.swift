// ReviewTests.swift
// Limpid — the review core's scenarios (all but the terminal probe, which only `make review-core` runs), the row
// list, and the keys review takes from the terminal.

import AppKit
import Foundation
import Testing
@testable import Limpid

struct ReviewTests {
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

    @Test func commentCoversARunOfLinesEndToEnd() throws {
        try ReviewValidationScenarios.ranges()
    }

    @Test func sideBySidePairsTheSameLinesTheUnifiedLayoutShows() throws {
        try ReviewValidationScenarios.sideBySide()
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

    @Test func conflictsAndSizeLimitsAreSaidOutright() async throws {
        try await withTempDir { directory in
            try await ReviewValidationScenarios.conflictAndLimits(at: directory)
        }
    }

    @Test func diagnosticsDoNotConsumeThePayloadBudget() async throws {
        try await withTempDir { directory in
            try await ReviewValidationScenarios.noisyDiagnostics(at: directory)
        }
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
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let session = fixture.session
        let presentation = ReviewPresentation()
        let registry = RecordingSurfaceRegistry()
        presentation.open(URL(fileURLWithPath: "/tmp/review-find"), originPaneID: fixture.paneID)
        let commands = RecordingWindowCommands()
        for action in [LimpidShortcutAction.find, .findNext, .findPrevious] {
            ReviewPresentationCommand.find(
                action,
                session: session,
                isReviewShown: presentation.isPresented,
                registry: registry,
                commands: commands,
                window: session.primaryWindowID
            )
        }
        #expect(commands.commands(in: session.primaryWindowID) == [.reviewFind(.find), .reviewFind(.findNext), .reviewFind(.findPrevious)])
        #expect(session.paneSearchStates.isEmpty)
        presentation.close()
        ReviewPresentationCommand.find(
            .find,
            session: session,
            isReviewShown: presentation.isPresented,
            registry: registry,
            commands: commands,
            window: session.primaryWindowID
        )
        #expect(commands.performed.count == 3, "the terminal's own search, not the review's")
        #expect(session.paneSearchStates[fixture.paneID] != nil)
    }

    @Test func reviewInsertShortcutRequiresCommandReturn() throws {
        let combinations: [NSEvent.ModifierFlags] = [.command, [.command, .shift], [.command, .option], [], .option]
        for modifiers in combinations {
            let event = try NSEvent.testKeyDown(keyCode: 36, modifiers: modifiers, characters: "\r")
            #expect((ReviewTableKey(event: event) == .insert) == (modifiers == .command))
            let table = ReviewTableView(frame: .zero, menuLocale: Locale(identifier: "en"))
            var handled = false
            table.onKey = { _ in handled = true
                return true
            }
            _ = table.performKeyEquivalent(with: event)
            #expect(!handled)
        }
    }
}
