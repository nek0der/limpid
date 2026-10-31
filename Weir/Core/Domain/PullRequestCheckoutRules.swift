// PullRequestCheckoutRules.swift
// Weir — a pull request as the new worktree sheet checks it out, and the rule that names its local branch.

import Foundation

/// A pull request as the new worktree sheet makes a worktree of it:
/// its number and title, whether it is still open, and the branch it comes
/// from, which may be a fork's.
struct PullRequestHead: Equatable, Hashable, Sendable {
    let number: Int
    let title: String
    let state: PRState
    /// The branch the request comes from, as the forge names it in the
    /// repository it lives in: a fork's `main` is named `main`.
    let headBranch: String
    /// The commit the forge says the branch is at; `nil` when it did not
    /// say. The fetch is what the worktree starts from either way: the
    /// branch can move between the lookup and the fetch.
    let headCommit: String?
    /// The fork's owner when the branch lives in a fork; `nil` for a
    /// branch of the repository itself.
    let forkOwner: String?

    var isFromFork: Bool {
        forkOwner != nil
    }
}

/// What the typed pull request number reads as: `12`, `#12`, `!12`, or a link to
/// the request (`…/pull/12`, `…/merge_requests/12`), so a number copied
/// from either forge's page or a chat works as it is.
enum PullRequestNumber {
    static func parse(_ text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"/(pull|pulls|merge_requests)/[0-9]+"#, options: .regularExpression) {
            trimmed = String(trimmed[range].split(separator: "/").last ?? "")
        }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
              let number = Int(trimmed), number > 0
        else { return nil }
        return number
    }

    /// The repository a pasted link is to, as `host/owner/repo` in lower
    /// case (`github.com/acme/app` of `https://github.com/acme/app/pull/12`);
    /// `nil` for a number, or text that is no such link. A link to another
    /// repository's request must not be checked out as this one's of the
    /// same number.
    static func repository(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              let range = components.path.range(of: #"(/-)?/(pull|pulls|merge_requests)/[0-9]+"#, options: .regularExpression)
        else { return nil }
        let path = components.path[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.contains("/") else { return nil }
        return "\(host)/\(path)".lowercased()
    }
}

/// The local branch a pull request's worktree checks out.
///
/// The request's own branch name when no local branch has it, so the
/// worktree reads as the branch the person knows from the forge. A local
/// branch of that name is reused only when it is at the request's commit
/// already: anything else may be the person's own work under the same name
/// (a fork's `main` meets the local `main`), which a checkout must never
/// move. Then the branch is `pr/<number>`, and `pr/<number>-2` and on while
/// those are taken by other commits.
enum PullRequestBranchChoice: Equatable, Sendable {
    /// A new branch of this name, made at the fetched commit.
    case newBranch(String)
    /// The local branch of this name is at the request's commit already.
    case existingBranch(String)
    /// The local branch at the request's commit is checked out in another
    /// worktree, where git adds no second one: the person opens that one.
    case checkedOut(String)

    /// The branch's name, whichever it is.
    var branch: String {
        switch self {
        case let .newBranch(name), let .existingBranch(name), let .checkedOut(name):
            name
        }
    }

    /// How many other names to try past `pr/<number>`: a person with more
    /// than this many stale copies of one request has a branch to delete,
    /// and the last name is offered for git to refuse in its own words.
    static let maximumSuffix = 99

    /// `localTips` maps each local branch to its commit; `checkedOut` is
    /// the branches checked out in the project's folder and its worktrees.
    /// `commit` is the request's: the fetched one at Create, the forge's
    /// before it, `nil` when neither is known yet, in which case a branch
    /// of the request's name is never taken to be at it.
    static func choose(
        for head: PullRequestHead,
        commit: String?,
        localTips: [String: String],
        checkedOut: Set<String>
    ) -> Self {
        var candidates = [head.headBranch, "pr/\(head.number)"]
        candidates += (2...maximumSuffix).map { "pr/\(head.number)-\($0)" }
        // Git keeps a branch as a file under its name: `pr/12` cannot be
        // made beside a branch `pr`, nor `pr` beside `pr/12`.
        let local = Array(localTips.keys)
        let isBlocked = { (name: String) in
            local.contains { name.hasPrefix($0 + "/") || $0.hasPrefix(name + "/") }
        }
        for name in candidates where !name.isEmpty && !isBlocked(name) {
            guard let tip = localTips[name] else { return .newBranch(name) }
            if let commit, tip == commit {
                return checkedOut.contains(name) ? .checkedOut(name) : .existingBranch(name)
            }
        }
        return .newBranch("pr/\(head.number)-\(maximumSuffix)")
    }
}
