// NewSessionModel+PullRequest.swift
// Limpid — the new worktree sheet's pull request source, and the line under its carry: the field, the lookup, the branch, the plan.

import Foundation

extension NewSessionModel {
    /// The longest a branch is shown in one of the sheet's sentences, in
    /// characters, past which its middle goes: two of them and the words
    /// around them still fit the two lines a line under a control takes at most
    /// (`NewSessionSheetLayoutTests`). The sentence itself is never cut.
    nonisolated static let longestShownName = 40

    /// `name` as a sentence of the sheet shows it (`longestShownName`).
    nonisolated static func shownName(_ name: String) -> String {
        SupervisionTruncation.middle(name, limit: longestShownName)
    }

    /// The line under the carry's checkbox: how many files, and that a
    /// failure leaves the source as it was; else why the box is off.
    func carryLine(locale: Locale) -> String {
        guard let source = context.carrySource else {
            return LocalizedStringResource(
                "To move uncommitted changes, show a worktree of this project.",
                comment: "New worktree sheet: under the carry's checkbox while the window shows another project's row, or none"
            ).resolved(in: locale)
        }
        let name = Self.shownName(source.name)
        guard canCarryChanges else {
            return LocalizedStringResource(
                // The box's title names the worktree already.
                "No uncommitted changes",
                comment: "New worktree sheet: under the carry's checkbox, whose title names the worktree, when it has nothing to carry"
            ).resolved(in: locale)
        }
        let promise = LocalizedStringResource(
            "If anything fails, \(name) is left unchanged.",
            comment: "New worktree sheet: under the carry's checkbox; the argument is the shown worktree's branch"
        ).resolved(in: locale)
        guard let files = source.changedFiles else { return promise }
        return GitFactsText.uncommittedChip(files, locale: locale) + " · " + promise
    }

    /// Every form the carry's line can take for this source before and
    /// after its files are counted (uncounted, none, many), so the sheet can
    /// keep the room of the longest from the moment it opens.
    func carryLineForms(locale: Locale) -> [String] {
        let counts: [Int?] = [nil, 0, 9999]
        let forms = counts.map { count in
            var counted = self
            counted.setCarryCount(count)
            return counted.carryLine(locale: locale)
        }
        return forms.reduce(into: []) { unique, form in
            if !unique.contains(form) {
                unique.append(form)
            }
        }
    }

    /// The number the pull request field reads as, `nil` while it reads as
    /// none.
    var pullRequestNumber: Int? {
        PullRequestNumber.parse(pullRequestText)
    }

    /// The repository a pasted link is to, when it is not the one the
    /// request would be read from and fetched; then nothing is looked up.
    var pullRequestLinkElsewhere: String? {
        guard let linked = PullRequestNumber.repository(in: pullRequestText),
              case let .available(repository) = context.pullRequests,
              let own = repository.repository,
              linked != own.lowercased()
        else { return nil }
        return linked
    }

    /// The lookup's answer for `number`, dropped when the field names
    /// another number by now.
    mutating func setPullRequestLookup(_ lookup: PullRequestLookup, for number: Int) {
        guard pullRequestNumber == number else { return }
        pullRequest = switch lookup {
        case let .found(head): .found(head)
        case let .notFound(number): .notFound(number)
        case let .failed(said): .failed(number, said)
        }
    }

    /// Whether a pull request's number is typed where one can be looked up:
    /// its answer comes over the network, without the person doing
    /// anything, and brings a line under the base and lengthens the one
    /// under the branch. Each keeps its two lines from the moment the
    /// number is typed, so the answer lands in room already there.
    var awaitsPullRequestAnswer: Bool {
        source == .pullRequest && canChoosePullRequest && pullRequestNumber != nil
    }

    /// Whether the source's "Pull Request" segment takes a choice:
    /// not where no CLI can read one, which its tooltip says.
    var canChoosePullRequest: Bool {
        switch context.pullRequests {
        case .checking, .available: true
        case .noForge, .toolMissing, .notSignedIn: false
        }
    }

    /// The request found, while the field names it.
    var foundPullRequest: PullRequestHead? {
        if case let .found(head) = pullRequest {
            return head
        }
        return nil
    }

    /// The branch the found request's worktree checks out, by the forge's
    /// word of its commit; Create decides again from the fetched one.
    var pullRequestChoice: PullRequestBranchChoice? {
        foundPullRequest.map { pullRequestChoice(for: $0, commit: $0.headCommit) }
    }

    func pullRequestChoice(for head: PullRequestHead, commit: String?) -> PullRequestBranchChoice {
        PullRequestBranchChoice.choose(
            for: head,
            commit: commit,
            localTips: context.localBranchTips,
            checkedOut: context.checkedOutBranches
        )
    }

    /// The found pull request under the base: its number and state as the
    /// sidebar's mark says them, the fork it comes from, and its title,
    /// which is the person's to read, so it comes last and is cut first.
    static func pullRequestLineText(_ head: PullRequestHead, locale: Locale) -> String {
        let state: LocalizedStringResource = switch head.state {
        case .open: "PR #\(head.number) · Open"
        case .closed: "PR #\(head.number) · Closed"
        case .merged: "PR #\(head.number) · Merged"
        }
        var parts = [state.resolved(in: locale)]
        if let owner = head.forkOwner, owner.isEmpty {
            parts.append(LocalizedStringResource(
                "from a fork",
                comment: "New worktree sheet: under the base, a pull request whose branch lives in a fork the forge did not name"
            ).resolved(in: locale))
        } else if let owner = head.forkOwner {
            parts.append(LocalizedStringResource(
                "from \(owner)’s fork",
                comment: "New worktree sheet: under the base, a pull request whose branch lives in a fork; the argument is the fork's owner"
            ).resolved(in: locale))
        }
        if !head.title.isEmpty {
            parts.append(head.title)
        }
        return parts.joined(separator: " · ")
    }

    /// The base menu's face for a pull request: the branch it comes from,
    /// after the fork's owner when it is a fork's, as the forge writes it
    /// (`alice:fix-login`).
    var pullRequestHeadName: String? {
        foundPullRequest.map { head in
            guard let owner = head.forkOwner, !owner.isEmpty else { return head.headBranch }
            return "\(owner):\(head.headBranch)"
        }
    }

    /// What stops Create for a pull request before the folder is looked at.
    var pullRequestProblem: Problem? {
        guard case .available = context.pullRequests else {
            return .pullRequestsUnavailable(context.pullRequests)
        }
        if let elsewhere = pullRequestLinkElsewhere {
            return .pullRequestElsewhere(elsewhere)
        }
        switch pullRequest {
        case .none, .lookingUp:
            return .noPullRequestChosen
        case let .notFound(number):
            return .pullRequestNotFound(number)
        case let .failed(number, said):
            return .pullRequestLookupFailed(number, said)
        case .found:
            if case .checkedOut = pullRequestChoice {
                return .branchCheckedOut
            }
            return nil
        }
    }

    /// The plan for a pull request at `commit`: before the fetch, the
    /// forge's word for it; once fetched, the commit the fetch brought,
    /// which is where the worktree starts whatever the forge said a moment
    /// before, so the branch is decided again from it. `nil` when that
    /// branch is checked out elsewhere, or its folder is taken.
    func pullRequestPlan(_ fetch: PullRequestFetch, commit: String?) -> Plan? {
        let choice = pullRequestChoice(for: fetch.head, commit: commit)
        let leaf = BranchNameSuggester.folderLeaf(of: choice.branch)
        guard !leaf.isEmpty else { return nil }
        let path = context.project.resolvedWorktreeURL(branchLeaf: leaf)
        guard !context.folderExists(path) else { return nil }
        switch choice {
        case let .newBranch(name):
            return Plan(
                path: path,
                start: commit ?? "",
                newBranch: name,
                request: launchRequest,
                notes: [],
                pullRequest: fetch,
                carry: carry
            )
        case let .existingBranch(name):
            return Plan(path: path, start: name, newBranch: nil, request: launchRequest, notes: [], pullRequest: fetch, carry: carry)
        case .checkedOut:
            return nil
        }
    }
}
