// CommitAndPRModel.swift
// Weir — the changes panel's foot: where the branch stands, "Create PR" and why not, and what comes after.

import Foundation
import WeirDomain

/// "Commit & PR" at the foot of the changes panel. There is no
/// commit button: committing is asked of the agent in its TUI, like any
/// other instruction. What is here is where the branch stands against the
/// default branch, "Create PR" or the one reason it cannot be pressed,
/// the changes outside turns to look at first, cleaning up a worktree
/// whose pull request was merged, and the person's own Git tool.
struct CommitAndPRModel: Equatable {
    /// One line of where the branch stands.
    enum Line: Hashable {
        case notOnBase(base: String, commits: Int)
        case unpushed(commits: Int)
        case uncommitted(files: Int)
        /// Nothing differs: one line in place of three zeros.
        case noDifference(base: String)
    }

    /// Why "Create PR" cannot be pressed; one shows at a time, the first
    /// that holds.
    enum Blocker: Equatable {
        case defaultBranch
        /// HEAD is no branch: gh has nothing to open a request from.
        case detachedHead
        case uncommittedOnly
        case nothingToPropose
        /// An agent waits on an approval or an answer, or has stopped.
        case waiting
        case running
        case unviewedTurns(Int)
    }

    /// What pressing "Create PR" will and will not do, said beside it.
    enum Note: Hashable {
        /// gh offers to push what is not pushed before it opens the
        /// request.
        case unpushedWillBePushed
        case uncommittedNotIncluded
    }

    enum Create: Equatable {
        case available([Note])
        case blocked(Blocker)

        var isAvailable: Bool {
            if case .available = self {
                true
            } else {
                false
            }
        }
    }

    /// The person's own tool for the diff (`review.externalDiffCommand`):
    /// its name for the button, and the command typed in the new tab.
    struct ExternalTool: Equatable {
        let name: String
        let command: String
    }

    struct Input {
        var facts: GitFacts?
        var pullRequest: PRInfo?
        /// Whether the folder's remote is on GitHub with gh installed: the
        /// one CLI "Create PR" runs.
        var hasGitHubCLI = false
        /// The project's own folder has no worktree to clean up.
        var isWorktree = false
        var unviewedTurns = 0
        var isWaiting = false
        var isRunning = false
        /// Files changed outside turns that no one has viewed as they are.
        var unviewedOutsideTurns = 0
        var externalCommand = ""
    }

    let lines: [Line]
    /// `nil` when "Create PR" is not offered: no gh, a request open or
    /// merged, or the branch not read yet.
    let create: Create?
    /// The branch's request, which takes the button's place while it is
    /// open.
    let pullRequest: PRInfo?
    /// More than 0: the notice and "Show Current Diff". It does not stop
    /// "Create PR".
    let unviewedOutsideTurns: Int
    /// The request was merged and this is a worktree. Not offered when the
    /// request's state cannot be read (no gh or glab, not signed in).
    let offersCleanUp: Bool
    let externalTool: ExternalTool?

    /// The one move the panel's foot bar holds, on the line the sidebar's
    /// and the decision bar's rules are on. The rest stay with the
    /// section's words above it.
    enum FootAction: Equatable {
        /// "Show Current Diff": changes outside turns come first, since
        /// they are what a pull request would carry unread.
        case showCurrentDiff
        /// "Create PR", disabled while blocked; its reason or its notes
        /// show above the bar.
        case createPullRequest(Create)
        /// "Open on {forge}" for the branch's request, where "Create PR" is
        /// not offered: the request is open or merged, or gh does not
        /// speak for the forge, or the branch's base is not read.
        case openPullRequest(PRInfo)
        /// "Open in {tool}": the person's own Git tool, where no request
        /// can be made or read (no gh, no base, nothing read yet).
        case openExternalTool(ExternalTool)

        /// Which move this is, whatever it carries: what the bar's guard
        /// against a press meant for the move before compares
        /// (`CommitAndPRFootGate`).
        var kind: FootActionKind {
            switch self {
            case .showCurrentDiff: .showCurrentDiff
            case .createPullRequest: .createPullRequest
            case .openPullRequest: .openPullRequest
            case .openExternalTool: .openExternalTool
            }
        }
    }

    /// A `FootAction` without what it carries.
    enum FootActionKind: Equatable, Sendable {
        case showCurrentDiff
        case createPullRequest
        case openPullRequest
        case openExternalTool
    }

    /// What the foot bar holds, the first that applies: the changes outside
    /// turns, then "Create PR", then the request already there, then the
    /// person's own tool. `nil` when none does, and there is no bar
    /// (`CommitAndPRFootBar`).
    var footAction: FootAction? {
        if unviewedOutsideTurns > 0 {
            return .showCurrentDiff
        }
        if let create {
            return .createPullRequest(create)
        }
        if let pullRequest {
            return .openPullRequest(pullRequest)
        }
        if let externalTool {
            return .openExternalTool(externalTool)
        }
        return nil
    }

    /// "Create PR" among the buttons above the bar: offered, and not the
    /// one the bar holds.
    var offersCreateAboveFoot: Bool {
        guard let create else { return false }
        return footAction != .createPullRequest(create)
    }

    /// "Open on {forge}" among the buttons above the bar.
    var offersOpenAboveFoot: Bool {
        guard let pullRequest else { return false }
        return footAction != .openPullRequest(pullRequest)
    }

    /// "Open in {tool}" among the buttons above the bar.
    var offersExternalToolAboveFoot: Bool {
        guard let externalTool else { return false }
        return footAction != .openExternalTool(externalTool)
    }

    static func make(_ input: Input) -> Self {
        Self(
            lines: lines(input.facts, isMerged: input.pullRequest?.state == .merged),
            create: create(input),
            pullRequest: input.pullRequest,
            unviewedOutsideTurns: input.unviewedOutsideTurns,
            offersCleanUp: input.isWorktree && input.pullRequest?.state == .merged,
            externalTool: externalTool(input.externalCommand)
        )
    }

    /// Once the request is merged, its commits are in, however the merge
    /// left them off the default branch (`GitFactsText.chips`).
    private static func lines(_ facts: GitFacts?, isMerged: Bool) -> [Line] {
        guard let facts else { return [] }
        var lines: [Line] = []
        // `proposedCommits`: on the default branch itself, commits ahead of
        // origin are not "not in main".
        if !isMerged, let base = facts.base, facts.proposedCommits > 0 {
            lines.append(.notOnBase(base: base.name, commits: facts.proposedCommits))
        }
        if let commits = facts.unpushedCommits, commits > 0 {
            lines.append(.unpushed(commits: commits))
        }
        if facts.uncommittedFiles > 0 {
            lines.append(.uncommitted(files: facts.uncommittedFiles))
        }
        if lines.isEmpty, let base = facts.base {
            lines.append(.noDifference(base: base.name))
        }
        return lines
    }

    private static func create(_ input: Input) -> Create? {
        // An open request takes the button's place; a merged one, "Clean Up
        // Worktree…", since a squash merge leaves the branch's commits off
        // the default branch and they would read as work to propose. A
        // closed one may be proposed again.
        guard input.hasGitHubCLI, let facts = input.facts, facts.base != nil,
              input.pullRequest?.state != .open, input.pullRequest?.state != .merged
        else { return nil }
        // What the branch holds first: an agent finishing cannot give a
        // branch with no commits something to propose.
        if facts.isOnBase {
            return .blocked(.defaultBranch)
        }
        if facts.branch == nil {
            return .blocked(.detachedHead)
        }
        if facts.proposedCommits == 0 {
            return .blocked(facts.uncommittedFiles > 0 ? .uncommittedOnly : .nothingToPropose)
        }
        // Then the agents, in the order the person would get to them: one
        // waiting on them now, one still at work (whose turn will be
        // unviewed next), and last the turns to read.
        if input.isWaiting {
            return .blocked(.waiting)
        }
        if input.isRunning {
            return .blocked(.running)
        }
        if input.unviewedTurns > 0 {
            return .blocked(.unviewedTurns(input.unviewedTurns))
        }
        var notes: [Note] = []
        if (facts.unpushedCommits ?? 0) > 0 {
            notes.append(.unpushedWillBePushed)
        }
        if facts.uncommittedFiles > 0 {
            notes.append(.uncommittedNotIncluded)
        }
        return .available(notes)
    }

    /// Whether one of the session's attention items is an agent waiting on
    /// the person, an approval or an answer, or stopped: what keeps "Create
    /// PR" from being pressed. An unread turn is counted apart.
    static func isWaiting(_ items: [AttentionItem]) -> Bool {
        items.contains { item in
            switch item.kind {
            case .approval, .question, .prompt, .stop: true
            case .unread: false
            }
        }
    }

    /// What keeps "Clean Up Worktree…" from going on: commits known
    /// to be on no remote, and uncommitted files. `nil` when neither holds.
    /// An unknown count does not stop it: the upstream is gone as the
    /// request merged in most clean-ups, and the branch, which keeps every
    /// commit, is not deleted.
    static func cleanUpBlocker(_ facts: GitFacts?) -> (unpushed: Int, uncommitted: Int)? {
        let unpushed = facts?.unpushedCommits ?? 0
        let uncommitted = facts?.uncommittedFiles ?? 0
        return unpushed > 0 || uncommitted > 0 ? (unpushed, uncommitted) : nil
    }

    /// The tool's name is the program its command runs, without its folder
    /// ("tig" for "PAGER=less /opt/homebrew/bin/tig --all"): past the
    /// variables set before it, and past `env` and its options. A program
    /// whose path holds a space reads by its first word, which only names
    /// the button.
    static func externalTool(_ command: String) -> ExternalTool? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let program = words.first { word in
            word != "env" && !word.contains("=") && !word.hasPrefix("-")
        } ?? words.first
        guard let program else { return nil }
        return ExternalTool(name: (program as NSString).lastPathComponent, command: trimmed)
    }
}
