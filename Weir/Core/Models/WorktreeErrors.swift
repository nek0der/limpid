// WorktreeErrors.swift
// Weir — typed errors raised by the worktree CRUD pipelines in
// `WorkspaceSession+Worktree.swift`. Kept in its own file so the
// async-pipeline code can stay focused on the happy path; UI alert
// surfaces (`worktreeOperationError` state in the sidebar) keep the
// error and draw its `message` in the window's locale.

import Foundation

// Each error's catalog text comes from a plain, non-optional `switch` over
// literals: the string catalog's extraction reads those, and misses a
// literal handed to `.localized(...)` inside a conditional expression.

enum CreateWorktreeError: WeirLocalizedError {
    case projectNotFound
    case missingBranchName
    case pathAlreadyExists(URL)
    /// A new branch name git would read as an option (`-D`, `-f`).
    case invalidBranchName(String)
    case gitFailed(stderr: String)
    /// The new branch was made, then the worktree could not be added on
    /// it. The branch stays, and a retry uses it as an existing branch
    /// rather than making it again, which would fail on the name.
    case gitFailedLeavingBranch(stderr: String, branch: String)
    /// `git worktree add` ran past its deadline (`GitProcess.worktreeTimeout`)
    /// and was ended: a `post-checkout` hook that waits, most likely. The
    /// branch made for it, if any, stays, as with `gitFailedLeavingBranch`.
    /// What it had made of the worktree is removed; `leftover` is the folder
    /// when that failed, or when something git started outlived it and may
    /// still write there, which the person is told to remove.
    case timedOut(seconds: Int, branch: String?, leftover: URL?)
    /// The worktree was made and attached, and a setup step failed. The
    /// row stays, so a retry runs the setup again (`runSetup(from:)`)
    /// rather than making a second worktree.
    case setupFailed(worktreeID: UUID, stepIndex: Int, command: String, logTail: String)
    /// A setup step's folder leads out of the worktree; it was not run.
    case setupDirectoryOutsideWorktree(worktreeID: UUID, stepIndex: Int, cwd: String)

    /// Where the creation stopped.
    var stage: NewSessionStage {
        switch self {
        case let .setupFailed(_, stepIndex, _, _), let .setupDirectoryOutsideWorktree(_, stepIndex, _):
            .setup(stepIndex: stepIndex)
        case .projectNotFound, .missingBranchName, .pathAlreadyExists, .invalidBranchName, .gitFailed, .gitFailedLeavingBranch,
             .timedOut:
            .creatingWorktree
        }
    }

    /// Whether the worktree and its row were made before this failure:
    /// the stages after the worktree's.
    var leavesWorktree: Bool {
        stage != .creatingWorktree
    }

    /// What the failed stage printed last: git's or the setup step's own
    /// words, for the decision bar.
    var logTail: String {
        switch self {
        case let .gitFailed(stderr), let .gitFailedLeavingBranch(stderr, _): stderr
        case let .setupFailed(_, _, _, logTail): logTail
        case .projectNotFound, .missingBranchName, .pathAlreadyExists, .invalidBranchName, .setupDirectoryOutsideWorktree, .timedOut: ""
        }
    }

    /// The end of git's words, as much as a setup step's log keeps
    /// (`WorktreeSetup.logTailBytes`): a hook git runs can print at length.
    static func tail(_ stderr: String) -> String {
        WorktreeSetup.tail(of: Data(stderr.utf8))
    }

    /// Our sentence, with git's own stderr after it when git said
    /// something: the stderr is English whatever the display language, so
    /// the sentence says first, in the reader's language, what failed.
    var message: DisplayText {
        switch self {
        case let .gitFailed(stderr) where !stderr.isEmpty, let .gitFailedLeavingBranch(stderr, _) where !stderr.isEmpty:
            .localized(LocalizedStringResource(
                "git worktree add failed: \(stderr)",
                comment: "New worktree: git worktree add failed; the argument is Git’s own message, in English"
            ))
        default:
            .localized(text)
        }
    }

    private var text: LocalizedStringResource {
        switch self {
        case .projectNotFound: "Project not found."
        case .missingBranchName: "Enter a branch name for the new worktree."
        case let .pathAlreadyExists(url): "A folder already exists at \(url.path)."
        case let .invalidBranchName(name): "“\(name)” can’t be a branch name."
        case .gitFailed, .gitFailedLeavingBranch: "git worktree add failed."
        case let .timedOut(seconds, _, nil):
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "git worktree add didn’t finish within \(seconds / 60) minutes, so Weir stopped it and removed the partially created worktree. Check the repository’s hooks, such as post-checkout.",
                // swiftlint:disable:next line_length
                comment: "New session, the worktree stage: git worktree add ran past its deadline and was stopped, and what it had made was removed; the number is minutes"
            )
        case let .timedOut(seconds, _, leftover?):
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "git worktree add didn’t finish within \(seconds / 60) minutes, so Weir stopped it. The partially created worktree at \(leftover.path) couldn’t be removed; remove it with git worktree remove --force. Check the repository’s hooks, such as post-checkout.",
                // swiftlint:disable:next line_length
                comment: "New session, the worktree stage: git worktree add ran past its deadline and was stopped, and the folder it left could not be removed; the number is minutes, then the folder"
            )
        case let .setupFailed(_, stepIndex, command, _): "Setup command \(stepIndex + 1) failed: \(command)"
        case let .setupDirectoryOutsideWorktree(_, stepIndex, cwd):
            "Setup command \(stepIndex + 1) wasn’t run: its folder \(cwd) is outside the worktree."
        }
    }
}

enum DeleteWorktreeError: WeirLocalizedError {
    case projectNotFound
    case worktreeNotFound
    case dirtyNeedsForce
    case submodulesNeedForce
    case gitFailed(stderr: String)

    /// Our sentence, with git's own stderr after it when git said
    /// something, as `CreateWorktreeError.message` puts it.
    var message: DisplayText {
        if case let .gitFailed(stderr) = self, !stderr.isEmpty {
            return .localized(LocalizedStringResource(
                "git worktree remove failed: \(stderr)",
                comment: "Delete worktree: git worktree remove failed; the argument is Git’s own message, in English"
            ))
        }
        return .localized(text)
    }

    private var text: LocalizedStringResource {
        switch self {
        case .projectNotFound: "Project not found."
        case .worktreeNotFound: "Worktree not found."
        case .dirtyNeedsForce: "This worktree has uncommitted changes. To delete it anyway, choose Force Delete."
        case .submodulesNeedForce: "This worktree contains initialized submodules. To delete it anyway, choose Force Delete."
        case .gitFailed: "git worktree remove failed."
        }
    }
}
