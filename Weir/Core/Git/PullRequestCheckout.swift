// PullRequestCheckout.swift
// Weir — reads a pull request's branch through gh or glab, for a worktree made from it.
//
// Beside `PRStatusFetcher` rather than in it: that one asks about the
// branch a worktree has checked out, on a cadence, and turns every failure
// into "show nothing". This one asks about a number the person typed, once,
// and each failure is something the sheet says: the request is not there,
// the CLI is not installed, or it is not signed in.
//
// The head is fetched from the base repository by the forge's own ref
// (`refs/pull/<n>/head`, `refs/merge-requests/<n>/head`), which both forges
// keep for a request from a fork too. So a fork needs no remote of its own,
// and nothing is added to the person's remotes.

import Foundation
import OSLog

private let log = Logger.weir("git.pr.checkout")

/// The repository a worktree is made from a pull request of: the forge,
/// the remote its head is fetched from, and that remote's repository
/// (`host/owner/repo`), which the CLI is told to read the request from, so
/// the request read and the head fetched are one repository's.
struct PullRequestRepository: Equatable, Sendable {
    let forge: ForgeKind
    let remote: String
    /// `nil` when the remote's URL names no `owner/repo` (a local path);
    /// the CLI then reads its own default.
    let repository: String?
}

/// Whether the sheet can make a worktree from a pull request, and why not
/// when it cannot.
enum PullRequestAvailability: Equatable, Sendable {
    /// Not asked yet: the sheet asks after it opens, as `glab` answers over
    /// the network.
    case checking
    case available(PullRequestRepository)
    /// No remote on a host `gh` or `glab` serves.
    case noForge
    case toolMissing(ForgeKind)
    case notSignedIn(ForgeKind)
}

/// What the forge said of one pull request number.
enum PullRequestLookup: Equatable, Sendable {
    case found(PullRequestHead)
    case notFound(Int)
    /// The CLI did not answer, or answered in a way we cannot read; its
    /// own words when it gave any.
    case failed(String)
}

/// The forge side of a worktree made from a pull request: what the sheet
/// can offer, one request by number, and the open ones to pick from. A
/// protocol so a test gives its own answers without a CLI.
protocol PullRequestReading: Sendable {
    func availability(repoRoot: URL) async -> PullRequestAvailability
    func pullRequest(_ number: Int, in repository: PullRequestRepository, repoRoot: URL) async -> PullRequestLookup
    func openPullRequests(in repository: PullRequestRepository, repoRoot: URL) async -> [PullRequestHead]
}

extension ForgeKind {
    /// The ref the forge keeps a request's head under in the base
    /// repository, a fork's included.
    func headRef(of number: Int) -> String {
        switch self {
        case .gitHub: "refs/pull/\(number)/head"
        case .gitLab: "refs/merge-requests/\(number)/head"
        }
    }
}

/// `gh` and `glab`, found and classified as the pull request marks find
/// them (`ForgeResolver`, `ToolLocator`), so the sheet and the marks agree
/// on which forge a folder is on.
struct ForgePullRequests: PullRequestReading {
    let resolver: ForgeResolver
    let locator: ToolLocator

    /// Longer than the marks' lookup: the person waits on this one, and a
    /// cold `gh` on a slow link can take a few seconds.
    private static let timeout: Duration = .seconds(15)
    /// How many open requests the menu lists, newest first.
    static let listLimit = 30

    func availability(repoRoot: URL) async -> PullRequestAvailability {
        guard let remote = await resolver.pullRequestRemote(for: repoRoot),
              let forge = await resolver.forge(for: repoRoot)
        else { return .noForge }
        guard await locator.locate(forge.executableName) != nil else { return .toolMissing(forge) }
        // A host the heuristic named (`github.com`) was classified without
        // asking the CLI; a probe that did not answer reads as signed in,
        // and the lookup then says what went wrong in the CLI's own words.
        guard await resolver.isAuthenticated(kind: forge, host: remote.host) != false else { return .notSignedIn(forge) }
        return .available(PullRequestRepository(
            forge: forge,
            remote: remote.name,
            repository: ForgeResolver.repository(fromRemoteURL: remote.url)
        ))
    }

    func pullRequest(_ number: Int, in repository: PullRequestRepository, repoRoot: URL) async -> PullRequestLookup {
        let forge = repository.forge
        guard let executable = await locator.locate(forge.executableName) else { return .failed("") }
        let arguments: [String] = switch forge {
        case .gitHub: ["pr", "view", String(number), "--json", Self.gitHubFields]
        case .gitLab: ["mr", "view", String(number), "--output", "json"]
        }
        let result = await runTool(
            executable: executable,
            arguments: arguments + Self.repositoryArguments(repository),
            workingDirectory: repoRoot,
            environment: Self.quietEnvironment(for: forge),
            timeout: Self.timeout
        )
        return Self.lookup(result, number: number, forge: forge)
    }

    func openPullRequests(in repository: PullRequestRepository, repoRoot: URL) async -> [PullRequestHead] {
        let forge = repository.forge
        guard let executable = await locator.locate(forge.executableName) else { return [] }
        let arguments: [String] = switch forge {
        case .gitHub: ["pr", "list", "--limit", String(Self.listLimit), "--json", Self.gitHubFields]
        case .gitLab: ["mr", "list", "--per-page", String(Self.listLimit), "--output", "json"]
        }
        let result = await runTool(
            executable: executable,
            arguments: arguments + Self.repositoryArguments(repository),
            workingDirectory: repoRoot,
            environment: Self.quietEnvironment(for: forge),
            timeout: Self.timeout
        )
        guard let result, result.isSuccess else {
            log.debug("\(forge.executableName, privacy: .public) could not list requests: \(result?.stderr ?? "", privacy: .private)")
            return []
        }
        return Self.decodeList(stdout: result.stdout, forge: forge)
    }

    // MARK: - Reading the answers

    static let gitHubFields = "number,title,state,headRefName,headRefOid,isCrossRepository,headRepositoryOwner"

    /// The repository named to the CLI: without it, `gh` reads its own
    /// default (`gh repo set-default`), which may be another remote than
    /// the one the head is fetched from, and a request of the same number
    /// there would be checked out in its place. Both CLIs take `--repo`.
    static func repositoryArguments(_ repository: PullRequestRepository) -> [String] {
        repository.repository.map { ["--repo", $0] } ?? []
    }

    /// The same as the marks' lookup sets (`PRStatusFetcher`): no prompt,
    /// no update notice, no telemetry.
    static func quietEnvironment(for forge: ForgeKind) -> [String: String] {
        switch forge {
        case .gitHub: ["GH_PROMPT_DISABLED": "true", "GH_NO_UPDATE_NOTIFIER": "1"]
        case .gitLab: ["GLAB_CHECK_UPDATE": "0", "GLAB_SEND_TELEMETRY": "0"]
        }
    }

    /// What one `view` said: `nil` is a CLI that did not finish.
    static func lookup(_ result: ToolResult?, number: Int, forge: ForgeKind) -> PullRequestLookup {
        guard let result else { return .failed("") }
        guard result.isSuccess else {
            let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return saysNotFound(said) ? .notFound(number) : .failed(said)
        }
        guard let head = decode(stdout: result.stdout, forge: forge) else { return .failed("") }
        return .found(head)
    }

    /// Whether the CLI's failure says there is no such request, rather than
    /// that it could not ask: `gh` says "Could not resolve to a
    /// PullRequest", `glab` answers the API's 404.
    static func saysNotFound(_ stderr: String) -> Bool {
        ["could not resolve to a pullrequest", "no pull requests found", "404"].contains {
            stderr.localizedCaseInsensitiveContains($0)
        }
    }

    static func decode(stdout: String, forge: ForgeKind) -> PullRequestHead? {
        guard let data = PRStatusFetcher.firstJSONObject(in: stdout) else { return nil }
        let decoder = JSONDecoder()
        switch forge {
        case .gitHub: return (try? decoder.decode(GhHead.self, from: data))?.head
        case .gitLab: return (try? decoder.decode(GlabHead.self, from: data))?.head
        }
    }

    /// A list is a JSON array of what `view` gives one of.
    static func decodeList(stdout: String, forge: ForgeKind) -> [PullRequestHead] {
        guard let start = stdout.firstIndex(of: "["), let data = String(stdout[start...]).data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        switch forge {
        case .gitHub: return ((try? decoder.decode([GhHead].self, from: data)) ?? []).map(\.head)
        case .gitLab: return ((try? decoder.decode([GlabHead].self, from: data)) ?? []).map(\.head)
        }
    }
}

// MARK: - Payloads

/// The fields of `gh pr view --json` the sheet asks for (`gitHubFields`).
private struct GhHead: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let number: Int
    let title: String
    let state: String
    let headRefName: String
    let headRefOid: String?
    let isCrossRepository: Bool?
    let headRepositoryOwner: Owner?

    var head: PullRequestHead {
        PullRequestHead(
            number: number,
            title: title,
            state: PRState(forgeState: state),
            headBranch: headRefName,
            headCommit: headRefOid,
            forkOwner: isCrossRepository == true ? (headRepositoryOwner?.login ?? "") : nil
        )
    }
}

/// The part of GitLab's merge request object the sheet reads. A request
/// from a fork has a source project other than its target.
private struct GlabHead: Decodable {
    struct Author: Decodable {
        let username: String
    }

    let iid: Int
    let title: String
    let state: String
    let sourceBranch: String
    let sha: String?
    let sourceProjectID: Int?
    let targetProjectID: Int?
    let author: Author?

    enum CodingKeys: String, CodingKey {
        case iid, title, state, sha, author
        case sourceBranch = "source_branch"
        case sourceProjectID = "source_project_id"
        case targetProjectID = "target_project_id"
    }

    var head: PullRequestHead {
        let isFromFork = sourceProjectID != nil && sourceProjectID != targetProjectID
        return PullRequestHead(
            number: iid,
            title: title,
            state: PRState(forgeState: state),
            headBranch: sourceBranch,
            headCommit: sha,
            // GitLab names the fork by its project, which the request does
            // not carry; its author is who the person knows it by.
            forkOwner: isFromFork ? (author?.username ?? "") : nil
        )
    }
}

extension PRState {
    /// Either forge's word for a request's state: GitHub's `OPEN`, `CLOSED`,
    /// `MERGED`, GitLab's `opened`, `closed`, `merged`, `locked`. Anything
    /// else reads as open, as a locked discussion does.
    init(forgeState raw: String) {
        switch raw.lowercased() {
        case "merged": self = .merged
        case "closed": self = .closed
        default: self = .open
        }
    }
}
