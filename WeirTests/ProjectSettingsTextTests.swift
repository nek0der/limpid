// ProjectSettingsTextTests.swift
// Weir — the project settings sheet names its project, in headings of one case.

import Foundation
import Testing
@testable import Weir

struct ProjectSettingsTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func theTitle_namesTheProject() {
        let title = ProjectSettingsText.title(project: "weir")
        #expect(title.resolved(in: Self.english) == "Project Settings for weir")
        #expect(title.resolved(in: Self.japanese) == "weir のプロジェクト設定")
    }

    @Test func theTitle_withTheProjectGone_namesNoProject() {
        let title = ProjectSettingsText.title(project: nil)
        #expect(title.resolved(in: Self.english) == "Project Settings")
        #expect(title.resolved(in: Self.japanese) == "プロジェクト設定")
    }

    /// The tooltips name their key by the glyph the keyboard shows, in
    /// full-width parentheses in Japanese.
    @Test func theCloseTooltip_namesEsc_inFullWidthParentheses() {
        #expect(LocalizedStringResource("Close (⎋)").resolved(in: Self.english) == "Close (⎋)")
        #expect(LocalizedStringResource("Close (⎋)").resolved(in: Self.japanese) == "閉じる（⎋）")
        #expect(LocalizedStringResource("Done (⌘⏎)").resolved(in: Self.japanese) == "完了（⌘⏎）")
        #expect(LocalizedStringResource("Hidden Worktrees (\(2))").resolved(in: Self.japanese) == "非表示のワークツリー（2）")
    }

    /// Title case in English, as the Settings window's headings are.
    @Test func theHeadings_areInTitleCase() {
        #expect(ProjectSettingsText.agentWorktrees.resolved(in: Self.english) == "Agent Worktrees")
        #expect(ProjectSettingsText.agentWorktrees.resolved(in: Self.japanese) == "エージェントのワークツリー")
        #expect(ProjectSettingsText.setupCommands.resolved(in: Self.english) == "Setup Commands")
        #expect(ProjectSettingsText.setupCommands.resolved(in: Self.japanese) == "セットアップコマンド")
        #expect(ProjectSettingsText.checkCommands.resolved(in: Self.english) == "Test Commands")
        #expect(ProjectSettingsText.checkCommands.resolved(in: Self.japanese) == "テストとして扱うコマンド")
    }

    /// The commands a new worktree runs are "Setup" and 「セットアップ」 in the
    /// sheet, the new workspace's stage, and the errors alike.
    @Test @MainActor func theSetupCommands_haveOneName() {
        let stage = SessionLaunchBar.stageName(.setup(stepIndex: 0))
        #expect(stage.resolved(in: Self.english) == "Setup")
        #expect(stage.resolved(in: Self.japanese) == "セットアップ")
        #expect(LocalizedStringResource("Skip Setup and Open").resolved(in: Self.japanese) == "セットアップをスキップして開く")
        let failed = StopReasonText.launchFailure(.setup(stepIndex: 1))
        #expect(failed.resolved(in: Self.english) == "Setup command 2 failed.")
        #expect(failed.resolved(in: Self.japanese) == "セットアップコマンド 2 が失敗しました。")
        // The other stage a launch stops at, as its stop says it.
        #expect(StopReasonText.make(.launchFailed(.startingCLI, logTail: ""), locale: Self.english)
            == "Stopped: The agent didn’t start.")
    }

    /// One word for where new worktrees go, as the new workspace sheet's
    /// VoiceOver says it.
    @Test func thePlacement_isWhereWorktreesGo() {
        #expect(ProjectSettingsText.placement.resolved(in: Self.english) == "Placement")
        #expect(ProjectSettingsText.placement.resolved(in: Self.japanese) == "場所")
    }

    /// The section of the files Git ignores that new worktrees get, named
    /// as the new worktree sheet's box says it in Japanese (コピー).
    @Test func theFilesToCopy_sayWhatTheyAreFor() {
        #expect(ProjectSettingsText.filesToCopy.resolved(in: Self.english) == "Files to Copy into New Worktrees")
        #expect(ProjectSettingsText.filesToCopy.resolved(in: Self.japanese) == "新しいワークツリーにコピーするファイル")
        #expect(ProjectSettingsText.filesToCopyFooter.resolved(in: Self.japanese).hasPrefix(".env など Git が無視するファイルを"))
    }
}
