// CommitAndPRText.swift
// Limpid — the changes panel's "Commit & PR" in words.

import Foundation

enum CommitAndPRText {
    /// One line of where the branch stands. Git's own wording ("ahead of
    /// origin by n commits") is not used.
    static func line(_ line: CommitAndPRModel.Line, locale: Locale) -> String {
        let resource = switch line {
        case let .notOnBase(base, commits):
            LocalizedStringResource(
                "\(commits) commits not in \(base)",
                comment: "Changes panel, Commit & PR: commits on the branch that the default branch (named) does not have"
            )
        case let .unpushed(commits):
            LocalizedStringResource(
                "\(commits) unpushed commits",
                comment: "Changes panel, Commit & PR: commits on the branch that no remote has"
            )
        case let .uncommitted(files):
            LocalizedStringResource(
                "\(files) uncommitted files",
                comment: "Changes panel, Commit & PR: files changed and not committed"
            )
        case let .noDifference(base):
            LocalizedStringResource(
                "No changes from \(base)",
                comment: "Changes panel, Commit & PR: nothing committed, pushed, or changed apart from the default branch (named)"
            )
        }
        return resource.resolved(in: locale)
    }

    static func blocker(_ blocker: CommitAndPRModel.Blocker, locale: Locale) -> String {
        let resource = switch blocker {
        case .defaultBranch:
            LocalizedStringResource("You can’t create a PR from the default branch.")
        case .detachedHead:
            LocalizedStringResource("Switch to a branch before creating a PR.")
        case .uncommittedOnly:
            LocalizedStringResource("Commit your changes before creating a PR.")
        case .nothingToPropose:
            LocalizedStringResource("There are no commits for a PR.")
        case .waiting:
            LocalizedStringResource(
                "An agent is waiting for approval, an answer, or a response, or has stopped.",
                comment: "Changes panel, Commit & PR: why Create PR is disabled"
            )
        case .running:
            LocalizedStringResource("You can’t create a PR while an agent is running.")
        case let .unviewedTurns(count):
            LocalizedStringResource(
                "\(count) turns are unviewed. View them before creating a PR.",
                comment: "Changes panel, Commit & PR: why Create PR is disabled"
            )
        }
        return resource.resolved(in: locale)
    }

    static func note(_ note: CommitAndPRModel.Note, locale: Locale) -> String {
        let resource = switch note {
        case .unpushedWillBePushed:
            LocalizedStringResource("gh asks before pushing unpushed commits.")
        case .uncommittedNotIncluded:
            LocalizedStringResource("Uncommitted changes aren’t included in the PR.")
        }
        return resource.resolved(in: locale)
    }

    /// The branch's request as the sidebar row states it, with its checks:
    /// "PR #128 · Open · Checks passed (4/4)".
    static func pullRequest(_ request: PRInfo, locale: Locale) -> String {
        let fact = SessionRowFactText.make(
            .pullRequest(number: request.number, state: request.state, isDraft: request.isDraft),
            locale: locale
        )
        let checks = request.checks.map { PRChecksText.make($0, forge: request.forge, locale: locale) }
        return AgentStatusText.joined([fact] + (checks.map { [$0] } ?? []), locale: locale)
    }

    /// `pullRequest` as VoiceOver reads it, "PR #128, Open, Checks passed,
    /// 4 of 4": the checks' "4/4" would be read as a date in Japanese.
    static func spokenPullRequest(_ request: PRInfo, locale: Locale) -> String {
        let fact = SessionRowFactText.make(
            .pullRequest(number: request.number, state: request.state, isDraft: request.isDraft),
            locale: locale
        )
        let checks = request.checks.map { PRChecksText.spoken($0, forge: request.forge, locale: locale) }
        return AgentStatusText.spokenList([AgentStatusText.spoken(fact, locale: locale), checks ?? ""], locale: locale)
    }

    /// The notice over "Show Current Diff".
    static func outsideTurns(_ files: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "\(files) files changed outside turns (unviewed). Check the current diff before creating a PR.",
            comment: "Changes panel, Commit & PR: files changed while no turn ran, not viewed yet"
        ).resolved(in: locale)
    }

    /// Why "Clean Up Worktree…" stopped: Git no longer reads the folder as
    /// a work tree. The changes panel's own words for it.
    static func notWorkTree(locale: Locale) -> String {
        LocalizedStringResource(
            "This folder isn’t a Git repository, so changes can’t be tracked.",
            comment: "Changes panel: the worktree is not a Git repository"
        ).resolved(in: locale)
    }

    /// Why "Clean Up Worktree…" stopped without deciding.
    static func gitDidNotAnswer(locale: Locale) -> String {
        LocalizedStringResource(
            "Git didn’t answer in time, so nothing was checked. Try again.",
            comment: "Changes panel, Clean Up Worktree: reading the worktree's commits timed out"
        ).resolved(in: locale)
    }

    /// Why "Clean Up Worktree…" stopped: what the worktree holds that is
    /// not on the remote.
    static func cleanUpBlocked(unpushed: Int, uncommitted: Int, locale: Locale) -> String {
        var parts: [String] = []
        if unpushed > 0 {
            parts.append(line(.unpushed(commits: unpushed), locale: locale))
        }
        if uncommitted > 0 {
            parts.append(line(.uncommitted(files: uncommitted), locale: locale))
        }
        // One count a line, as the panel states them.
        let list = parts.joined(separator: "\n")
        return LocalizedStringResource(
            "This worktree has work that isn’t on a remote:\n\(list)\nCommit and push it first, or use Delete Worktree… in the sidebar.",
            comment: "Changes panel, Clean Up Worktree: what keeps the worktree from being cleaned up, one count a line"
        ).resolved(in: locale)
    }
}
