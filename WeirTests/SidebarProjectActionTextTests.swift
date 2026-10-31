// SidebarProjectActionTextTests.swift
// Weir — the project header's operations on all of its worktrees, in English and Japanese.

import Foundation
import Testing
@testable import Weir

struct SidebarProjectActionTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func theWorktreeOperations_nameAllOfTheProjectsWorktrees() {
        #expect(SidebarProjectActionText.syncWorktrees.resolved(in: Self.english) == "Sync Worktrees")
        #expect(SidebarProjectActionText.syncWorktrees.resolved(in: Self.japanese) == "ワークツリーを同期")
        #expect(SidebarProjectActionText.showHiddenWorktrees.resolved(in: Self.english) == "Show Hidden Worktrees")
        #expect(SidebarProjectActionText.showHiddenWorktrees.resolved(in: Self.japanese) == "非表示のワークツリーを表示")
    }

    /// Every missing row goes, so the Japanese says all of them, in the
    /// words of the row's own state ("ワークツリーが見つかりません").
    @Test func removeMissingWorktrees_saysItRemovesEveryMissingOne() {
        #expect(SidebarProjectActionText.removeMissingWorktrees.resolved(in: Self.english) == "Remove Missing Worktrees")
        #expect(SidebarProjectActionText.removeMissingWorktrees.resolved(in: Self.japanese) == "見つからないワークツリーをすべて外す")
    }
}
