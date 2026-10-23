// LiveLocaleTests.swift
// Limpid — in-app text follows the language picked in Settings, not the
// one the process launched with.
//
// Every assertion resolves in an explicit locale, so the suite means the
// same thing whatever language the test host runs in. "Differs between en
// and ja" catches a model that froze its text into a `String`, and a key
// that lost its Japanese translation.

import AppKit
import Foundation
import Testing
@testable import Limpid

@Suite("Live display language")
@MainActor
struct LiveLocaleTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    /// The same resource in both languages: present, and translated.
    private func expectTranslated(
        _ resource: LocalizedStringResource,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let english = resource.resolved(in: en)
        let japanese = resource.resolved(in: ja)
        #expect(!english.isEmpty, sourceLocation: sourceLocation)
        #expect(english != japanese, "\(english) has no Japanese", sourceLocation: sourceLocation)
    }

    // MARK: - Model text

    @Test func settingsPickers_switchWithTheLanguage() {
        #expect(ConfirmPolicy.onlyWhenAgent.localizedTitle.resolved(in: ja) == "エージェントの実行中のみ確認する")
        #expect(ConfirmPolicy.onlyWhenAgent.localizedTitle.resolved(in: en) == "Only while an agent is running")
        // The three choices share one shape: what Limpid does.
        #expect(ConfirmPolicy.always.localizedTitle.resolved(in: ja) == "常に確認する")
        #expect(ConfirmPolicy.never.localizedTitle.resolved(in: ja) == "確認しない")
        for policy in ConfirmPolicy.allCases {
            expectTranslated(policy.localizedTitle)
        }
        expectTranslated(AppLanguage.system.localizedTitle)
        // Endonyms read the same in every language.
        #expect(AppLanguage.english.localizedTitle.resolved(in: ja) == "English")
        #expect(AppLanguage.japanese.localizedTitle.resolved(in: en) == "日本語")
    }

    @Test func reviewLayers_switchWithTheLanguage() {
        #expect(ReviewLayer.untracked.title.resolved(in: ja) == "未追跡")
        #expect(ReviewLayer.untracked.title.resolved(in: en) == "Untracked")
        for layer in ReviewLayer.allCases {
            expectTranslated(layer.title)
        }
    }

    @Test func stateGlyphNames_switchWithTheLanguage() {
        let kinds: [StateGlyph.Kind] = [.needsApproval, .needsAnswer, .needsResponse, .stopped, .unread, .running, .idle, .unknown]
        for kind in kinds {
            expectTranslated(kind.name)
        }
    }

    @Test func reviewErrors_switchWithTheLanguage() {
        let errors: [ReviewError] = [
            .invalidDiff, .unsupported, .tooLarge, .gitFailed, .changed, .targetUnavailable, .invalidText,
            .storageFailed, .resolvedBacklogTooLarge, .baseUnavailable, .draftUnreadable, .checkInterrupted,
            .commentLimitReached, .commentTooLong, .nothingToInsert, .promptTooLong, .timedOut,
            .instructionsInvalid, .instructionsTooLong, .unsavedComment
        ]
        for error in errors {
            guard case let .localized(message) = DisplayText(error: error) else {
                Issue.record("\(error) is not a catalog string")
                continue
            }
            expectTranslated(message)
        }
    }

    @Test func displayText_keepsSystemErrorsVerbatim() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        #expect(DisplayText(error: error) == .verbatim("disk full"))
        #expect(DisplayText(error: error).resolved(in: ja) == "disk full")
        // Git's own words stay English after our sentence in each language.
        let gitError = DisplayText(error: CreateWorktreeError.gitFailed(stderr: "fatal: bad ref"))
        #expect(gitError.resolved(in: en) == "git worktree add failed: fatal: bad ref")
        #expect(gitError.resolved(in: ja) == "git worktree add に失敗しました：fatal: bad ref")
        let removeError = DisplayText(error: DeleteWorktreeError.gitFailed(stderr: "fatal: locked"))
        #expect(removeError.resolved(in: ja) == "git worktree remove に失敗しました：fatal: locked")
        let missingBranch = DisplayText(error: CreateWorktreeError.missingBranchName)
        #expect(missingBranch.resolved(in: en) != missingBranch.resolved(in: ja))
    }

    @Test func linkRejections_switchWithTheLanguage() {
        let rejections: [TerminalLinkRejection] = [
            .malformed, .unsafeCharacters, .invalidWebURL, .remoteFile, .missingFile, .specialFile
        ]
        for rejection in rejections {
            expectTranslated(rejection.message)
        }
    }

    @Test func promptCachePanel_switchesWithTheLanguage() throws {
        let window = AgentCacheWindow(observedAt: Date(), ttlSeconds: 3600, rewriteTokens: 573_000, precision: .estimated)
        let content = try #require(PromptCacheRules.panelContent(
            status: .expired,
            window: window,
            isAnswered: false,
            commandBlock: .notAtPrompt
        ))
        expectTranslated(content.title)
        try expectTranslated(#require(content.costLine))
        let now = window.expiresAt.addingTimeInterval(120)
        let english = content.timeLine(now: now, locale: en).resolved(in: en)
        let japanese = content.timeLine(now: now, locale: ja).resolved(in: ja)
        #expect(english.contains(PromptCacheFormatting.duration(120, locale: en)))
        #expect(japanese.contains(PromptCacheFormatting.duration(120, locale: ja)))
        #expect(english != japanese)
        for block in [PromptCacheCommandBlock.notAtPrompt, .notInFront, .unsubmittedInput] {
            expectTranslated(block.reason)
        }
    }

    @Test func notificationTitles_resolveInTheLocaleTheyAreSentIn() {
        expectTranslated(AgentKind.claude.finishedTitle)
        expectTranslated(AgentKind.codex.waitTitle(for: .approval(PromptApproval(recorded: nil, tool: "Bash"))))
        expectTranslated(AgentKind.codex.waitTitle(for: .question(detail: nil)))
        expectTranslated(AgentKind.codex.waitTitle(for: nil))
        expectTranslated(AgentKind.claude.stoppedTitle)
        #expect(AgentKind.claude.waitTitle(for: .approval(PromptApproval(recorded: nil, tool: "Bash"))).resolved(in: ja)
            == "Claude Code が承認を待っています")
        #expect(AgentKind.claude.waitTitle(for: .question(detail: nil)).resolved(in: ja) == "Claude Code が質問しています")
        #expect(AgentKind.claude.waitTitle(for: .question(detail: nil)).resolved(in: en) == "Claude Code is asking a question")
        #expect(AgentKind.claude.waitTitle(for: .unclassified(detail: nil)).resolved(in: ja) == "Claude Code が応答を待っています")
        #expect(AgentKind.claude.waitTitle(for: nil).resolved(in: en) == "Claude Code is waiting for a response")
        #expect(AgentKind.claude.finishedTitle.resolved(in: ja) == "Claude Code がターンを完了しました")
        #expect(AgentKind.claude.finishedTitle.resolved(in: en) == "Claude Code finished a turn")
        #expect(AgentKind.claude.stoppedTitle.resolved(in: ja) == "Claude Code が停止しました")
        #expect(AgentKind.claude.stoppedTitle.resolved(in: en) == "Claude Code stopped")
        let session = WorkspaceSession()
        #expect(session.containerLabel(for: .loose, locale: ja) == "スクラッチ")
        #expect(session.containerLabel(for: .loose, locale: en) == "Scratch")
    }

    @Test func confirmations_switchWithTheLanguage() throws {
        let quit = DestructiveAlertText.quit(hasAgent: true)
        #expect(quit.title.resolved(in: ja) == "Limpid を終了しますか？")
        try expectTranslated(#require(quit.message))
        expectTranslated(quit.confirmLabel)
        expectTranslated(quit.cancelLabel)
        #expect(DestructiveAlertText.quit(hasAgent: false).message == nil)
        for kind in [CloseConfirmer.Kind.tab, .allTabs, .pane] {
            let close = DestructiveAlertText.close(kind, hasAgent: true)
            expectTranslated(close.title)
            try expectTranslated(#require(close.message))
            #expect(DestructiveAlertText.close(kind, hasAgent: false).message == nil)
        }
    }

    @Test func fileActionTitles_switchWithTheLanguage() {
        expectTranslated(FileApplicationResolution.macOSDefault.openActionTitle)
        expectTranslated(FileApplicationResolution.macOSDefault.openLineActionTitle(line: 4))
        #expect(FileApplicationResolution.macOSDefault.openLineActionTitle(line: 4).resolved(in: ja).contains("4"))
    }

    @Test func sessionRestoreIssue_switchesWithTheLanguage() {
        let issue = SessionLoadIssue.versionMismatch(found: 3, expected: 4)
        expectTranslated(issue.title)
        guard case let .localized(detail) = issue.detail else {
            Issue.record("a schema mismatch is described by Limpid")
            return
        }
        expectTranslated(detail)
        #expect(SessionLoadIssue.decodeFailed(message: .verbatim("line 2")).detail == .verbatim("line 2"))
    }

    @Test func migrationErrors_areDescribedInBothLanguages() {
        let errors: [any LimpidLocalizedError] = [
            MigrationBackup.BackupError.noFreeBackupName,
            MigrationBackup.BackupError.copyFailed,
            VersionedDocumentMigrator.MigrationError.stepProducedWrongVersion(from: 4, found: nil)
        ]
        for error in errors {
            guard case let .localized(message) = DisplayText(error: error) else {
                Issue.record("\(error) is described by Limpid")
                continue
            }
            expectTranslated(message)
        }
    }

    @Test func sessionRepair_isDescribedInBothLanguages() {
        let repairs: [SessionLoadIssue] = [
            .recovered(droppedTabCount: 0, didResetActiveContainer: true),
            .recovered(droppedTabCount: 2, didResetActiveContainer: false),
            .recovered(droppedTabCount: 2, didResetActiveContainer: true)
        ]
        for repair in repairs {
            expectTranslated(repair.title)
            guard case let .localized(detail) = repair.detail else {
                Issue.record("a repair is described by Limpid")
                continue
            }
            expectTranslated(detail)
        }
        let single = SessionLoadIssue.recovered(droppedTabCount: 1, didResetActiveContainer: false)
        #expect(single.detail.resolved(in: en) == "Removed 1 tab with duplicate pane IDs.")
    }

    // MARK: - Builders that need a String

    @Test func commandPalette_titlesFollowTheLocaleWithAnEnglishAlias() throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let items = CommandPaletteCatalog.buildItems(
                session: WorkspaceSession(),
                settings: settings,
                attention: AttentionState(),
                locale: ja
            )
            let settingsItem = try #require(items.first { $0.id == "settings.open" })
            #expect(settingsItem.title == "設定を開く")
            #expect(settingsItem.searchAlias == "Open Settings")
            let split = try #require(items.first { $0.id == "shortcut.\(LimpidShortcutAction.splitRight.rawValue)" })
            #expect(split.title == LimpidShortcutAction.splitRight.localizedTitle.resolved(in: ja))
            #expect(split.searchAlias == LimpidShortcutAction.splitRight.localizedTitle.resolved(in: en))

            let english = CommandPaletteCatalog.buildItems(
                session: WorkspaceSession(),
                settings: settings,
                attention: AttentionState(),
                locale: en
            )
            let englishSettings = try #require(english.first { $0.id == "settings.open" })
            #expect(englishSettings.title == "Open Settings")
            #expect(englishSettings.searchAlias == nil)
        }
    }

    @Test func commandPaletteHelp_subtitlesFollowThePalettesLocale() {
        let state = CommandPaletteState(locale: ja, windowID: WindowID())
        state.applyFilter(query: "?", frecencyStore: nil)
        let english = CommandPaletteState(locale: en, windowID: WindowID())
        english.applyFilter(query: "?", frecencyStore: nil)
        #expect(!state.results.isEmpty)
        #expect(state.results.map(\.item.subtitle) != english.results.map(\.item.subtitle))
    }

    @Test func keyboardSheet_titlesFollowTheLocaleAndStillMatchEnglish() throws {
        let sections = KeyboardShortcutCatalog.sections(
            keyboard: KeyboardSettings(),
            quickTerminalHotKey: StoredShortcut(key: "t", modifiers: [.control, .option]),
            locale: ja
        )
        let entries = sections.flatMap(\.entries)
        let split = try #require(entries.first { $0.id == "action.\(LimpidShortcutAction.splitRight.rawValue)" })
        #expect(split.title == LimpidShortcutAction.splitRight.localizedTitle.resolved(in: ja))
        #expect(split.searchAliases.contains(LimpidShortcutAction.splitRight.localizedTitle.resolved(in: en)))
        let systemWide = try #require(sections.first { $0.id == "fixed.systemWide" })
        #expect(systemWide.title == LocalizedStringResource("System-wide").resolved(in: ja))
        #expect(systemWide.title != "System-wide")
        #expect(!KeyboardShortcutCatalog.filter(sections, query: "split right").isEmpty)
    }

    @Test func reviewPrompt_defaultOpeningIsWrittenInTheGivenLocale() throws {
        let comment = ReviewComment(
            file: ReviewFile(path: "a.swift", layer: .unstaged, status: .modified),
            fingerprint: "snapshot",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 2),
            code: "+x",
            codeMarkers: "+",
            body: "Fix this."
        )
        let root = URL(fileURLWithPath: "/tmp/review")
        let japanese = try ReviewPromptBuilder.build(root: root, comments: [comment], locale: ja).text
        let english = try ReviewPromptBuilder.build(root: root, comments: [comment], locale: en).text
        #expect(japanese.contains(ReviewPromptBuilder.defaultInstructions.resolved(in: ja)))
        #expect(english.contains(ReviewPromptBuilder.defaultInstructions.resolved(in: en)))
        #expect(japanese != english)
    }

    /// What a rail row says besides its name, for a reader who cannot see
    /// it, in the rail's language whatever the process launched in.
    @Test func reviewRailSummary_namesTheLayerCountsAndFeedbackInTheGivenLocale() {
        let summary = ReviewFileTree.summary(
            layer: .unstaged,
            stat: ReviewFileStat(added: 3, removed: 1),
            comments: 2,
            locale: en
        )
        #expect(summary == "Unstaged, +3 −1, 2 comments")
        #expect(ReviewFileTree.summary(layer: .staged, stat: ReviewFileStat(added: -1, removed: -1), comments: 0, locale: en)
            == "Staged, binary")
        #expect(ReviewFileTree.summary(layer: .untracked, stat: nil, comments: 0, locale: en) == "Untracked")
        #expect(ReviewFileTree.summary(layer: .untracked, stat: nil, comments: 0, locale: ja) == "未追跡")
        #expect(ReviewFileTree.summary(layer: .untracked, stat: nil, comments: 0, isViewed: true, locale: en)
            == "Untracked, Viewed")
        #expect(ReviewFileTree.summary(layer: .untracked, stat: nil, comments: 0, isViewed: true, locale: ja)
            == "未追跡、確認済み")
    }

    // MARK: - Agent status text

    @Test func agentStatus_tooltipsAreOneFormatPerPhrase() {
        #expect(AgentStatusText.joined(["Running", "", "editing a file"], locale: en) == "Running · editing a file")
        #expect(AgentStatusText.pane(name: "Needs approval", detail: "", locale: en) == "Needs approval")
        #expect(AgentStatusText.pane(name: "Needs approval", detail: "Bash: ls", locale: en)
            == "Needs approval · Bash: ls")
        #expect(AgentStatusText.spokenList(["server", "Claude", ""], locale: en) == "server, Claude")
    }

    @Test func agentStatus_followsTheGivenLocale() {
        let running = StateGlyph.Kind.running.name.resolved(in: ja)
        #expect(AgentStatusText.pane(name: running, detail: "編集中", locale: ja)
            == AgentStatusText.joined([running, "編集中"], locale: ja))
        #expect(AgentStatusText.spokenList(["a", "b"], locale: ja) == "a、b")
    }

    @Test func settingsMessages_comeFromTheModel() throws {
        #expect(ShortcutValidation.ok.message == nil)
        #expect(QuickTerminalHotKeyValidation.ok.message == nil)
        let reserved = try #require(ShortcutValidation.reserved.message)
        expectTranslated(reserved)
        let conflict = try #require(ShortcutValidation.conflict(.splitRight).message)
        #expect(conflict.resolved(in: ja).contains(LimpidShortcutAction.splitRight.localizedTitle.resolved(in: ja)))
        try expectTranslated(#require(QuickTerminalHotKeyValidation.takenBySystem.message))
        expectTranslated(QuickTerminalHotKeyProblem.keyNotOnLayout.message)
        expectTranslated(QuickTerminalSettings.appCommandOverlapWarning)
    }

    @Test func gitExitCode_findsItsTranslation() {
        let error = GitProcessError.nonZeroExit(GitResult(exitCode: 128, stdout: "", stderr: ""))
        let message = DisplayText(error: error)
        #expect(message.resolved(in: en) == "git exited with code 128.")
        #expect(message.resolved(in: ja) != message.resolved(in: en))
        let said = DisplayText(error: GitProcessError.nonZeroExit(GitResult(exitCode: 1, stdout: "", stderr: "fatal: nope")))
        #expect(said.resolved(in: en) == "git exited with code 1: fatal: nope")
        #expect(said.resolved(in: ja) == "git が終了コード 1 で終了しました：fatal: nope")
    }

    /// A setup that the system stopped says which command, in the reader's
    /// language, before the system's own reason.
    @Test func aSetupThatCouldNotStart_saysWhichCommandFirst() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No such file"])
        let message = SessionLaunchStore.setupCouldNotStart(1, error)
        #expect(message.resolved(in: en) == "Setup command 2 couldn’t start: No such file")
        #expect(message.resolved(in: ja) == "セットアップコマンド 2 を開始できませんでした：No such file")
    }

    /// Our own reason inside one of these sentences resolves in the same
    /// language as the sentence, whatever language the app launched in.
    @Test func aNestedReason_followsTheSentencesLanguage() {
        let timedOut = GitProcessError.timedOut(seconds: 60)
        let setup = SessionLaunchStore.setupCouldNotStart(0, timedOut)
        #expect(setup.resolved(in: ja) == "セットアップコマンド 1 を開始できませんでした：git が 60 秒以内に完了しませんでした。")
        #expect(setup.resolved(in: en) == "Setup command 1 couldn’t start: git didn’t finish within 60 seconds.")
        let fetch = NewSessionActions.fetchFailure(timedOut)
        #expect(fetch.resolved(in: ja) == "リモートからフェッチできませんでした：git が 60 秒以内に完了しませんでした。")
        #expect(fetch.resolved(in: en) == "Couldn’t fetch from the remote: git didn’t finish within 60 seconds.")
    }
}
