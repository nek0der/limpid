// NewSessionActions+Carry.swift
// Weir — Create carrying the shown worktree's uncommitted changes into the new one, and what it says when they stay.

import Foundation

extension NewSessionActions {

    // MARK: - Carrying the changes

    /// The shown worktree's changes, read and placed on the new worktree's
    /// start before it is made (`UncommittedChangesCarrier`).
    struct PreparedCarry {
        let source: NewSessionModel.CarrySource
        let snapshot: UncommittedChangesCarrier.Snapshot
        let placement: UncommittedChangesCarrier.Placement
        /// What the start is called in a message: the base, the branch, the
        /// pull request.
        let startName: String
    }

    /// Reads the changes and places them on `start`; `nil` when there are
    /// none to carry any more. Writes nothing in the source.
    static func prepareCarry(
        from source: NewSessionModel.CarrySource,
        onto start: String,
        named startName: String,
        repoRoot: URL
    ) async -> Result<PreparedCarry?, CreateFailure> {
        do {
            guard let snapshot = try await UncommittedChangesCarrier.snapshot(of: source.root) else { return .success(nil) }
            let placement = try await UncommittedChangesCarrier.place(snapshot, onto: start, repoRoot: repoRoot)
            return .success(PreparedCarry(source: source, snapshot: snapshot, placement: placement, startName: startName))
        } catch {
            let refusal = error as? UncommittedCarryRefusal ?? .git(String(describing: error))
            return .failure(CreateFailure(message: .localized(carryRefusalText(refusal, source: source.name, start: startName))))
        }
    }

    /// The carry once the worktree is made: the changes read again, as the
    /// source may have changed while Git made it, then moved
    /// (`UncommittedChangesCarrier.move`). What the bar says of it: `nil`
    /// when the changes moved, or there was nothing left to carry. The
    /// bar's notes are what went short and stay until closed; a move
    /// that went as asked is seen in the rows, the new one with the
    /// changes and the source with none.
    static func finishCarry(_ carry: PreparedCarry, into target: URL, repoRoot: URL) async -> SessionLaunch.Note? {
        let name = carry.source.name
        var snapshot = carry.snapshot
        var placement = carry.placement
        do {
            guard let fresh = try await UncommittedChangesCarrier.snapshot(of: carry.source.root) else { return nil }
            if fresh != snapshot {
                placement = try await UncommittedChangesCarrier.place(fresh, onto: placement.start, repoRoot: repoRoot)
                snapshot = fresh
            }
        } catch {
            // Read again, the changes no longer apply (an edit that now
            // conflicts, a merge begun): nothing was done to the source.
            return .carryNotApplied(from: name)
        }
        return switch await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) {
        case .moved: nil
        case .notApplied: .carryNotApplied(from: name)
        case .leftInSource: .carryLeftInSource(from: name)
        case let .partlyCleared(stash): .carryPartlyCleared(from: name, stash: stash)
        }
    }

    /// What the start is called in the carry's messages.
    static func startName(of model: NewSessionModel, plan: NewSessionModel.Plan) -> String {
        switch model.source {
        case .newBranch: model.base?.name ?? plan.start
        case .existingBranch: plan.start
        case .pullRequest: plan.pullRequest.map { "PR #\($0.head.number)" } ?? plan.start
        }
    }

    /// Why the changes did not come along, said on the sheet: each with
    /// what the person can do, and that the source is as it was.
    static func carryRefusalText(_ refusal: UncommittedCarryRefusal, source: String, start: String) -> LocalizedStringResource {
        switch refusal {
        case .noCommit:
            LocalizedStringResource(
                "\(source) has no commits yet, so its changes can’t be moved. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from has no commit; its branch, twice"
            )
        case .operationInProgress:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "\(source) is in the middle of a merge, rebase, cherry-pick, or revert. Finish it first. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from has an operation under way; its branch, twice"
            )
        case .unmergedPaths:
            LocalizedStringResource(
                "\(source) has unresolved conflicts. Resolve them first. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from has unresolved conflicts; its branch, twice"
            )
        case .unsupportedCheckout:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "\(source) uses a sparse checkout or a split index, which Weir can’t move changes from. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from is a sparse checkout or has a split index; its branch, twice"
            )
        case .submodules:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "\(source) has changes in a submodule or in a repository inside it, which Weir can’t move. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from changes a submodule; its branch, twice"
            )
        case .indexOnlyState:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "\(source) has files marked skip-worktree or assume-unchanged, or added with git add -N, which Weir can’t move. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the worktree to carry from has state only its index holds; its branch, twice"
            )
        case let .ignoredFilesInTheWay(path):
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "\(path) is now a folder in \(source) that holds files Git ignores, and moving the changes would remove them. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: a tracked file became a folder holding ignored files; the path, the source's branch, twice"
            )
        case let .conflicts(paths):
            // Joined in the resolving language's list style, as the launch bar's notes are.
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The changes in \(source) conflict with \(start) in \(paths, format: .list(type: .and, width: .narrow)). No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: the changes conflict with the start; the source, the start, the paths, the source again"
            )
        case .unsupportedGit:
            LocalizedStringResource(
                "Moving changes requires Git 2.40 or later. No worktree was created, and \(source) is unchanged.",
                comment: "New worktree sheet: git merge-tree is too old for the carry; the argument is the source's branch"
            )
        case let .git(said):
            LocalizedStringResource(
                "Couldn’t read the changes in \(source). No worktree was created, and \(source) is unchanged. Details: \(said)",
                comment: "New worktree sheet: git failed reading the changes; the source's branch, twice, then Git's own words in English"
            )
        }
    }
}
