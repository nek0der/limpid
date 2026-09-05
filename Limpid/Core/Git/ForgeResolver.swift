// ForgeResolver.swift
// Limpid — decides which forge (if any) a checkout's remote belongs to.
//
// Layered after Git Credential Manager's provider autodetection.
// GCM's layers are: exact host match, host-prefix heuristic, network
// probe, explicit user override. We keep the first two, delegate the
// third to the forge CLIs, and defer the fourth until someone reports
// a host we misread.
//
// The probe asks about authentication, not about a pull request.
// `gh pr view` exits non-zero on a GitHub repository whose branch
// simply has no PR yet — the normal state of every new branch — so
// using it to answer "is this GitHub?" would cache a false negative
// and disable the feature for the whole host.
//
// The two CLIs answer very differently, which is why the order below
// matters. `gh auth token --hostname` is a local config lookup: it
// returns whatever token is configured, instantly and offline.
// `glab auth status --hostname` validates the credential against the
// instance, so it needs the host to be reachable and the token to be
// live. We try `gh` first to keep the common case free.
//
// `glab` has no local equivalent: `glab config get token --host` looks
// host-scoped but returns the ambient token for any hostname at all
// (verified against glab 1.116.0), so using it would classify every
// unknown host as GitLab. We accept the network round trip because it
// is the only form of the question that discriminates by host. It is
// paid once per host and bounded by the caller's timeout.

import Foundation
import OSLog

private let log = Logger.limpid("git.forge")

/// Forges we can read pull-request status from. A case here means a
/// CLI integration exists for it, so `allCases` is exactly the set
/// worth probing.
enum ForgeKind: String, CaseIterable {
    case gitHub
    case gitLab

    /// Executable we shell out to for this forge.
    var executableName: String {
        switch self {
        case .gitHub: "gh"
        case .gitLab: "glab"
        }
    }

    /// User-facing forge name, used in the hover card's link label.
    /// Not localized: these are proper nouns.
    var displayName: String {
        switch self {
        case .gitHub: "GitHub"
        case .gitLab: "GitLab"
        }
    }

    /// What this forge calls the thing that runs on a pull request.
    /// GitHub's own UI says "checks" ("All checks have passed") and
    /// GitLab's says "pipeline", so the card echoes whichever word
    /// the user will see after following the link. Using one term for
    /// both would be wrong for one of them.
    var checksNoun: LocalizedStringResource {
        switch self {
        case .gitHub: LocalizedStringResource("pr.checks.noun.github", defaultValue: "Checks")
        case .gitLab: LocalizedStringResource("pr.checks.noun.gitlab", defaultValue: "Pipeline")
        }
    }
}

/// Resolves and caches the forge for a working directory.
///
/// Two caches with different lifetimes and keys:
///   - by working directory, because that is what callers hold
///   - by remote host, because an organization's twelve worktrees
///     usually share one host and should pay the auth probe once
/// An `actor` for the same reason as `ToolLocator`: the callers are
/// already off the main actor, and only the caches need serializing.
actor ForgeResolver {
    private let locator: ToolLocator

    init(locator: ToolLocator) {
        self.locator = locator
    }

    /// A present `nil` means "resolved, and this directory has no
    /// forge we can serve" — either no remote at all or an
    /// unrecognized host. Callers skip those without spawning
    /// anything.
    private var byWorkingDirectory: [URL: ForgeKind?] = [:]
    private var byHost: [String: ForgeKind?] = [:]

    /// Bumped by `invalidate()`, and checked before every cache write.
    ///
    /// Actors are reentrant, so a resolve suspended on a CLI spawn can
    /// resume *after* the caches were emptied and write its
    /// pre-invalidate answer straight back in. That would leave the
    /// manual refresh — the one affordance that says "look again" out
    /// loud — silently holding the classification the user asked us to
    /// discard, and a poisoned `byHost` entry then applies to every
    /// checkout on that host.
    private var generation = 0

    /// Thrown when a tool we needed did not complete — a timeout, a
    /// cancelled task, a binary we could not locate.
    ///
    /// Distinct from "resolved, and there is no forge here", because
    /// the two must not be cached alike: a present `nil` stops us
    /// spawning anything for that directory again, and a question we
    /// never got an answer to would then disable the feature for the
    /// rest of the session on one slow `git config`.
    private struct LookupUnavailable: Error {}

    func forge(for workingDirectory: URL) async -> ForgeKind? {
        if let cached = byWorkingDirectory[workingDirectory] {
            return cached
        }
        let started = generation
        guard let resolved = try? await resolve(workingDirectory: workingDirectory) else {
            return nil
        }
        // Withheld when `invalidate()` landed while we were suspended:
        // the caller still gets this answer, since the fetch it belongs
        // to is about to be made against it either way, but caching it
        // would silently undo the one affordance that says "look
        // again".
        if generation == started {
            byWorkingDirectory[workingDirectory] = resolved
        }
        return resolved
    }

    /// Drop caches so the next tick re-reads remotes. Called when the
    /// user adds a remote or authenticates a CLI mid-session — we
    /// can't observe either, so the sidebar's manual refresh and the
    /// settings toggle both route through here.
    func invalidate() {
        generation &+= 1
        byWorkingDirectory.removeAll()
        byHost.removeAll()
    }

    // MARK: - Resolution

    private func resolve(workingDirectory: URL) async throws -> ForgeKind? {
        let started = generation
        guard let host = try await remoteHost(workingDirectory: workingDirectory) else {
            log.debug("no usable remote in \(workingDirectory.path, privacy: .private)")
            return nil
        }
        if let cached = byHost[host] {
            return cached
        }
        let resolved = try await classify(host: host)
        if generation == started {
            byHost[host] = resolved
        }
        return resolved
    }

    /// Host of the remote we should ask about, or nil when the
    /// checkout has no remote at all.
    private func remoteHost(workingDirectory: URL) async throws -> String? {
        let remotes = try await remoteURLs(workingDirectory: workingDirectory)
        guard !remotes.isEmpty else { return nil }
        // Check the names `gh` itself prefers, in its order, so we
        // agree with the tool we are about to invoke about which
        // remote counts. Anything else is sorted before we pick, since
        // dictionary order is not defined and the host we resolve has
        // to be stable across launches.
        for name in ["upstream", "github", "origin"] {
            if let url = remotes[name], let host = Self.host(fromRemoteURL: url) {
                return host
            }
        }
        return remotes.sorted { $0.key < $1.key }
            .lazy
            .compactMap { Self.host(fromRemoteURL: $0.value) }
            .first
    }

    private func remoteURLs(workingDirectory: URL) async throws -> [String: String] {
        guard let git = await locator.locate("git") else { throw LookupUnavailable() }
        let result = await runTool(
            executable: git,
            arguments: ["config", "--get-regexp", #"^remote\..*\.url$"#],
            workingDirectory: workingDirectory,
            timeout: .seconds(5)
        )
        // A nil result is `git config` never finishing — a timeout or a
        // cancelled task. Reading it as "no remotes" would cache a
        // permanent no for a question we never asked.
        guard let result else { throw LookupUnavailable() }
        // Exit 1 with empty output is `git config`'s way of saying
        // "no keys matched", i.e. no remotes — not an error.
        guard result.isSuccess else { return [:] }
        var remotes: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            // Each line is `remote.<name>.url <value>`.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            guard !name.isEmpty else { continue }
            remotes[name] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return remotes
    }

    /// Extract the host from either form git accepts:
    /// `https://host/owner/repo.git` and the scp-like
    /// `git@host:owner/repo.git`.
    ///
    /// The two are told apart by `://`, not by whether a scheme
    /// parses. `URLComponents` reads `github.com:owner/repo.git` as
    /// scheme `github.com` with no host, so keying off the scheme
    /// would send every user-less scp remote down the wrong branch.
    static func host(fromRemoteURL raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            // A real authority. An empty host means a local URL such
            // as `file:///srv/repo.git`, which has no forge behind it
            // — and must not fall through to the scp parser below,
            // which would otherwise read its scheme as the hostname.
            guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
            return host.lowercased()
        }
        // scp-like shorthand: everything between an optional `user@`
        // and the first `:`.
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        var authority = trimmed[trimmed.startIndex..<colon]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        let host = String(authority).lowercased()
        return host.isEmpty ? nil : host
    }

    /// Internal so tests can drive the probe tier directly. The
    /// heuristic tier is pure and covered separately; this one spawns
    /// a CLI, and it is the tier that decides whether GitHub
    /// Enterprise and self-hosted GitLab work at all.
    func classify(host: String) async throws -> ForgeKind? {
        if let heuristic = Self.heuristicKind(host: host) {
            log.debug("host \(host, privacy: .private) → \(heuristic.rawValue, privacy: .public) (heuristic)")
            return heuristic
        }
        // A probe that could not run leaves the host unclassified
        // rather than unsupported: "unsupported" is cached and stops
        // us asking again, which is the wrong conclusion to draw from
        // a CLI that timed out.
        var inconclusive = false
        for kind in ForgeKind.allCases {
            switch await isAuthenticated(kind: kind, host: host) {
            case true:
                log.debug("host \(host, privacy: .private) → \(kind.rawValue, privacy: .public) (auth probe)")
                return kind
            case false:
                continue
            case nil:
                inconclusive = true
            }
        }
        if inconclusive {
            log.debug("host \(host, privacy: .private) → probe did not complete")
            throw LookupUnavailable()
        }
        log.debug("host \(host, privacy: .private) → unsupported")
        return nil
    }

    /// Zero-cost classification for the hosts that name themselves.
    /// The prefix forms cover the near-universal convention for
    /// enterprise installs (`github.acme.com`, `gitlab.acme.com`).
    static func heuristicKind(host: String) -> ForgeKind? {
        if host == "github.com" || host.hasPrefix("github.") {
            return .gitHub
        }
        if host == "gitlab.com" || host.hasPrefix("gitlab.") {
            return .gitLab
        }
        return nil
    }

    /// Ask the forge's CLI whether it can authenticate to `host`.
    /// Neither command needs repository context, which is what makes
    /// them usable here; see this file's header for how differently
    /// the two answer, and why the timeout below is generous enough
    /// for `glab` to complete a round trip.
    /// `nil` when the probe could not be run at all — see `classify`
    /// for why that is not the same answer as "no".
    private func isAuthenticated(kind: ForgeKind, host: String) async -> Bool? {
        // Not installed is a real no: a CLI we don't have cannot hold a
        // credential, and installing one is not something we could
        // miss and want to re-probe for mid-session.
        guard let executable = await locator.locate(kind.executableName) else { return false }
        let arguments: [String] = switch kind {
        case .gitHub: ["auth", "token", "--hostname", host]
        case .gitLab: ["auth", "status", "--hostname", host]
        }
        let result = await runTool(
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            timeout: .seconds(10)
        )
        guard let result else { return nil }
        return result.isSuccess
    }
}
