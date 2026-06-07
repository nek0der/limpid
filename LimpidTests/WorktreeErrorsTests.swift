// WorktreeErrorsTests.swift
// Limpid — pin the user-visible error messages for both worktree CRUD pipelines.
// The sidebar surfaces these strings verbatim; changing them is a
// user-facing change that should be intentional.

import Foundation
import Testing
@testable import Limpid

@Suite("Worktree errors")
struct WorktreeErrorsTests {

    // MARK: - Create

    @Test("create: projectNotFound has a localized message")
    func create_projectNotFound_hasMessage() {
        let err: CreateWorktreeError = .projectNotFound
        #expect(err.errorDescription?.isEmpty == false)
    }

    @Test("create: missingBranchName prompts the user")
    func create_missingBranchName_hasMessage() {
        let err: CreateWorktreeError = .missingBranchName
        #expect(err.errorDescription?.isEmpty == false)
    }

    @Test("create: pathAlreadyExists embeds the offending path")
    func create_pathAlreadyExists_includesPath() throws {
        let url = URL(fileURLWithPath: "/tmp/limpid-already-there")
        let err: CreateWorktreeError = .pathAlreadyExists(url)
        let description = try #require(err.errorDescription)
        #expect(description.contains(url.path))
    }

    @Test("create: gitFailed with stderr surfaces the stderr text")
    func create_gitFailed_withStderr_returnsStderr() {
        let err: CreateWorktreeError = .gitFailed(stderr: "fatal: bad ref")
        #expect(err.errorDescription == "fatal: bad ref")
    }

    @Test("create: gitFailed with empty stderr falls back to a generic message")
    func create_gitFailed_withoutStderr_usesFallback() throws {
        let err: CreateWorktreeError = .gitFailed(stderr: "")
        let description = try #require(err.errorDescription)
        #expect(!description.isEmpty)
    }

    // MARK: - Delete

    @Test("delete: projectNotFound has a localized message")
    func delete_projectNotFound_hasMessage() {
        let err: DeleteWorktreeError = .projectNotFound
        #expect(err.errorDescription?.isEmpty == false)
    }

    @Test("delete: worktreeNotFound has a localized message")
    func delete_worktreeNotFound_hasMessage() {
        let err: DeleteWorktreeError = .worktreeNotFound
        #expect(err.errorDescription?.isEmpty == false)
    }

    @Test("delete: dirtyNeedsForce mentions the Force option to the user")
    func delete_dirtyNeedsForce_mentionsForce() throws {
        let err: DeleteWorktreeError = .dirtyNeedsForce
        let description = try #require(err.errorDescription)
        // The string is localized; accept either "Force" (en) or "強制" (ja)
        // so the test survives the system locale flip.
        #expect(description.contains("Force") || description.contains("強制"))
    }

    @Test("delete: gitFailed with stderr surfaces the stderr text")
    func delete_gitFailed_withStderr_returnsStderr() {
        let err: DeleteWorktreeError = .gitFailed(stderr: "fatal: locked")
        #expect(err.errorDescription == "fatal: locked")
    }

    @Test("delete: gitFailed with empty stderr falls back to a generic message")
    func delete_gitFailed_withoutStderr_usesFallback() {
        let err: DeleteWorktreeError = .gitFailed(stderr: "")
        #expect(err.errorDescription?.isEmpty == false)
    }
}
