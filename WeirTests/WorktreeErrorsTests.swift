// WorktreeErrorsTests.swift
// Weir — pin the user-visible error messages for both worktree CRUD pipelines.
// The sidebar surfaces these strings verbatim; changing them is a
// user-facing change that should be intentional.

import Foundation
import Testing
@testable import Weir

@Suite("Worktree errors")
struct WorktreeErrorsTests {

    @Test("an error with no words of git's still has a message", arguments: [
        CreateWorktreeError.projectNotFound,
        CreateWorktreeError.missingBranchName,
        CreateWorktreeError.gitFailed(stderr: ""),
        DeleteWorktreeError.projectNotFound,
        DeleteWorktreeError.worktreeNotFound,
        DeleteWorktreeError.gitFailed(stderr: "")
    ] as [any LocalizedError & Sendable])
    func anErrorWithoutGitsWords_hasAMessage(_ error: any LocalizedError & Sendable) {
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("git's own words follow our sentence", arguments: [
        (CreateWorktreeError.gitFailed(stderr: "fatal: bad ref"), "fatal: bad ref"),
        (DeleteWorktreeError.gitFailed(stderr: "fatal: locked"), "fatal: locked")
    ] as [(any LocalizedError & Sendable, String)])
    func gitFailed_withStderr_endsWithThatStderr(_ error: any LocalizedError & Sendable, stderr: String) {
        let said = error.errorDescription ?? ""
        #expect(said.hasSuffix(stderr) && said != stderr, "\(said)")
    }

    // MARK: - Create

    @Test("create: pathAlreadyExists embeds the offending path")
    func create_pathAlreadyExists_includesPath() throws {
        let url = URL(fileURLWithPath: "/tmp/weir-already-there")
        let err: CreateWorktreeError = .pathAlreadyExists(url)
        let description = try #require(err.errorDescription)
        #expect(description.contains(url.path))
    }

    /// A `git worktree add` past its deadline says so, and that the hooks
    /// are what to look at, rather than reading as git's own failure; a
    /// half-made folder that could not be removed is named for the person
    /// to remove.
    @Test func create_timedOut_pointsAtTheHooks_andNamesAFolderLeftBehind() {
        let error = CreateWorktreeError.timedOut(seconds: 600, branch: "feature-t", leftover: nil)
        #expect(error.stage == .creatingWorktree)
        #expect(error.message.resolved(in: Locale(identifier: "ja"))
            == "git worktree add が 10 分以内に完了しなかったため、Weir が停止し、作成途中のワークツリーを削除しました。post-checkout などのリポジトリのフックを確認してください。")
        let stuck = CreateWorktreeError.timedOut(seconds: 600, branch: nil, leftover: URL(fileURLWithPath: "/tmp/wt"))
        #expect(stuck.message.resolved(in: Locale(identifier: "en"))
            .contains("The partially created worktree at /tmp/wt couldn’t be removed"))
    }

    // MARK: - Delete

    /// The alert's button is "Force Delete" (「強制削除」), so the message
    /// names that button by its whole name in both languages, and the
    /// Japanese has no English in it.
    @Test("delete: the force errors name the Force Delete button", arguments: [
        DeleteWorktreeError.dirtyNeedsForce, .submodulesNeedForce
    ])
    func delete_forceErrors_nameTheForceDeleteButton(_ err: DeleteWorktreeError) {
        let english = err.message.resolved(in: Locale(identifier: "en"))
        let japanese = err.message.resolved(in: Locale(identifier: "ja"))
        #expect(english.hasSuffix("To delete it anyway, choose Force Delete."))
        #expect(japanese.hasSuffix("それでも削除する場合は「強制削除」を選択してください。"))
        #expect(!japanese.contains("Force"))
    }
}
