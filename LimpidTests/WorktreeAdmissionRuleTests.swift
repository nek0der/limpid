// WorktreeAdmissionRuleTests.swift
// Limpid — a worktree an older state.json holds with no admission is admitted by its use, then its path.

import Foundation
import Testing
@testable import Limpid

struct WorktreeAdmissionRuleTests {
    private static let home = "/Users/someone"

    private static func facts(
        path: String,
        hasTabs: Bool = false,
        hasLastActiveTab: Bool = false,
        isSelected: Bool = false,
        isDetached: Bool = false
    ) -> WorktreeAdmissionRule.Facts {
        WorktreeAdmissionRule.Facts(
            hasTabs: hasTabs,
            hasLastActiveTab: hasLastActiveTab,
            isSelected: isSelected,
            path: path,
            isDetached: isDetached,
            homePath: home
        )
    }

    /// One the person used is theirs wherever an agent put it: a row of
    /// Claude's `.claude/worktrees/` with a tab, a last tab, or a selection
    /// stays a working row.
    @Test(arguments: [
        facts(path: "/repo/.claude/worktrees/x", hasTabs: true),
        facts(path: "/repo/.claude/worktrees/x", hasLastActiveTab: true),
        facts(path: "/repo/.claude/worktrees/x", isSelected: true),
        facts(path: "/work/agent-x", hasTabs: true, isDetached: true),
    ])
    func aUsedWorktree_isOpened_wherever_itSits(facts: WorktreeAdmissionRule.Facts) {
        #expect(WorktreeAdmissionRule.classify(facts) == .opened)
    }

    /// Unused, a worktree where agents put theirs is one Git only reported.
    @Test(arguments: [
        facts(path: "/repo/.claude/worktrees/x"),
        facts(path: "/repo/.claude/worktrees/x/"),
        facts(path: "/work/agent-x"),
        facts(path: "\(home)/.codex/worktrees/abcd/limpid"),
        facts(path: "/work/repo-detached", isDetached: true),
    ])
    func anUnusedWorktree_whereAgentsPutTheirs_isDiscovered(facts: WorktreeAdmissionRule.Facts) {
        #expect(WorktreeAdmissionRule.classify(facts) == .discovered)
    }

    /// Unused, a worktree anywhere else (Limpid's own placements, a folder
    /// the person made by hand) stays a working row, as it was before
    /// admissions were kept.
    @Test(arguments: [
        facts(path: "/work/repo-feat-x"),
        facts(path: "/repo/.worktrees/feat-x"),
        // Only a folder whose name starts so, not one that holds the word.
        facts(path: "/work/my-agent-x"),
        // Only under Codex's own folder, not one named like it elsewhere.
        facts(path: "/other/.codex/worktrees/abcd/limpid"),
        // Codex's folder itself is no worktree of an agent's.
        facts(path: "\(home)/.codex/worktrees"),
    ])
    func anUnusedWorktree_elsewhere_isOpened(facts: WorktreeAdmissionRule.Facts) {
        #expect(WorktreeAdmissionRule.classify(facts) == .opened)
    }
}
