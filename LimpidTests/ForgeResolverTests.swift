// ForgeResolverTests.swift
// Limpid — host extraction and forge classification.
//
// Everything here sits on the path that decides whether we shell out
// to a CLI at all: a wrong answer either spawns processes for a host
// we cannot serve, or silently disables the feature for one we can.
//
// Host extraction and the heuristic are pure, and carry no tag. The
// remote-priority and probe tests run `git` in a temp repository and
// spawn `gh`, so they are tagged `.smoke` individually and skip rather
// than fail — the same split `GitStatusParserTests` uses.
//
// The suite is `.serialized` because two of its tests set a
// process-wide environment variable. That orders them against each
// other; it cannot order them against other suites, which Swift
// Testing may run concurrently in the same process. Both restore the
// previous value rather than deleting it, which is what keeps the
// window narrow.

import Foundation
import Testing
@testable import Limpid

@Suite("ForgeResolver", .serialized)
struct ForgeResolverTests {

    // MARK: - Host extraction

    @Test(
        "extracts host from the URL forms git accepts",
        arguments: [
            ("https://github.com/nek0der/limpid.git", "github.com"),
            ("https://gitlab.com/acme/app.git", "gitlab.com"),
            // scp-like syntax has no scheme, so URLComponents reports
            // no host and the fallback parser has to take over.
            ("git@github.com:nek0der/limpid.git", "github.com"),
            ("git@gitlab.example.com:acme/app.git", "gitlab.example.com"),
            // No user component.
            ("github.com:nek0der/limpid.git", "github.com"),
            ("ssh://git@github.com:22/nek0der/limpid.git", "github.com"),
            // Host casing is normalized so cache keys collapse.
            ("https://GitHub.com/nek0der/limpid.git", "github.com")
        ]
    )
    func host_extractsFromRemoteURL(raw: String, expected: String) {
        #expect(ForgeResolver.host(fromRemoteURL: raw) == expected)
    }

    @Test(
        "returns nil for remotes with no host",
        arguments: [
            "",
            "   ",
            // A local path remote is legitimate and has no forge.
            "/Users/me/repo",
            "../sibling-repo",
            // Regression: this parses as a URL, but its authority is
            // empty. Falling through to the scp parser read the scheme
            // as the hostname and reported a forge host of "file",
            // costing two probe spawns to rule out.
            "file:///srv/repo.git",
        ]
    )
    func host_returnsNilWhenAbsent(raw: String) {
        #expect(ForgeResolver.host(fromRemoteURL: raw) == nil)
    }

    // MARK: - Classification

    @Test(
        "classifies hosts that name themselves",
        arguments: [
            ("github.com", ForgeKind.gitHub),
            ("gitlab.com", ForgeKind.gitLab),
            // The near-universal convention for enterprise installs.
            ("github.acme.com", ForgeKind.gitHub),
            ("gitlab.acme.com", ForgeKind.gitLab),
        ]
    )
    func heuristicKind_matchesNamedHosts(host: String, expected: ForgeKind) {
        #expect(ForgeResolver.heuristicKind(host: host) == expected)
    }

    /// These must fall through to the authentication probe rather than
    /// being guessed. `git.acme.com` is the common shape for both
    /// GitHub Enterprise and self-hosted GitLab, so guessing either way
    /// would be wrong half the time.
    @Test(
        "leaves ambiguous hosts unclassified for the auth probe",
        arguments: [
            "git.acme.com",
            "code.acme.com",
            "bitbucket.org",
            "codeberg.org",
            // Substring matches must not count: a host merely
            // containing the name is not the forge.
            "my-github-mirror.acme.com",
            "notgithub.com",
        ]
    )
    func heuristicKind_returnsNilForAmbiguousHosts(host: String) {
        #expect(ForgeResolver.heuristicKind(host: host) == nil)
    }

    // MARK: - Authentication probe

    /// The probe tests spawn `gh`. A contributor may not have it, so
    /// they skip rather than fail — the posture the git-dependent
    /// suites take with `RepoFixture.hasLocalRepo`.
    ///
    /// This checks only the inherited `PATH`, where `ToolLocator`
    /// falls back to well-known directories and then a login shell.
    /// The gate is therefore stricter than the product, and in
    /// practice it always skips: `xcodebuild` hands the test host a
    /// `PATH` without Homebrew on it, so `make test` and CI never run
    /// these two even on a machine where `gh` is installed and the
    /// feature works.
    ///
    /// Kept that way on purpose. Widening the gate to `ToolLocator`'s
    /// own search would make them run — and would also wake the race
    /// the header describes, because `setenv` rewrites `environ` while
    /// `ToolProcess.spawn` enumerates it from another suite. Running
    /// them would mean serializing the whole bundle, which is a larger
    /// bill than this coverage is worth. What they document is
    /// therefore the shape of the GitHub Enterprise probe for a reader
    /// and for a manual run, not a guarantee CI enforces.
    static let hasGitHubCLI: Bool = ToolLocator.searchPathVariable(
        ProcessInfo.processInfo.environment["PATH"] ?? "", for: "gh"
    ) != nil

    /// The tier that decides whether GitHub Enterprise works. A host
    /// no CLI holds a credential for must resolve to nil so we stop
    /// spawning processes for it, rather than guessing a forge and
    /// failing on every fetch.
    ///
    /// `.invalid` is reserved by RFC 2606, so nothing resolves and no
    /// request reaches a real host. `glab` still has to reach NXDOMAIN
    /// before answering, which is why this carries a time limit.
    ///
    /// It clears `GH_ENTERPRISE_TOKEN` for its duration for the reason
    /// the sibling test below demonstrates: that variable makes `gh`
    /// claim a credential for *any* non-github.com host, so a
    /// contributor who exports one — every real GitHub Enterprise user
    /// — would otherwise fail here.
    @Test(
        "a host no CLI holds a credential for stays unsupported",
        .tags(.smoke),
        .timeLimit(.minutes(1)),
        .disabled(if: !ForgeResolverTests.hasGitHubCLI, "no gh on PATH")
    )
    func classify_unknownHostWithNoCredential_isUnsupported() async throws {
        let restore = EnvironmentOverride(name: "GH_ENTERPRISE_TOKEN", value: nil)
        defer { restore.undo() }
        let resolver = ForgeResolver(locator: ToolLocator())
        #expect(try await resolver.classify(host: "git.example.invalid") == nil)
    }

    /// The GitHub Enterprise case, stood up without an enterprise
    /// instance: `gh auth token --hostname` reports whatever token is
    /// configured for a host, and `GH_ENTERPRISE_TOKEN` supplies one
    /// for any non-github.com host. It answers locally, so no request
    /// leaves the machine. This is the mechanism the probe rests on —
    /// if `gh` ever stopped honoring the variable, self-hosted users
    /// would silently lose the feature and nothing else here would
    /// notice.
    @Test(
        "a configured GitHub credential classifies an unknown host",
        .tags(.smoke),
        .timeLimit(.minutes(1)),
        .disabled(if: !ForgeResolverTests.hasGitHubCLI, "no gh on PATH")
    )
    func classify_hostWithGitHubCredential_resolvesToGitHub() async throws {
        let restore = EnvironmentOverride(name: "GH_ENTERPRISE_TOKEN", value: "limpid-test-token")
        defer { restore.undo() }
        // A name the heuristic cannot match, so only the probe can
        // produce an answer.
        let resolver = ForgeResolver(locator: ToolLocator())
        #expect(try await resolver.classify(host: "code.example.invalid") == .gitHub)
    }

    // MARK: - Remote selection

    /// The remote a fork-based checkout resolves to.
    ///
    /// `origin` is the contributor's own fork and `upstream` the
    /// project it was forked from, so reading them in dictionary order
    /// — or in any order that puts `origin` first — would classify by
    /// the wrong host whenever the two live on different forges. We
    /// follow `gh`'s own priority so we agree with the tool we are
    /// about to invoke.
    ///
    /// This also covers the caches on either side of the resolve and
    /// the `git config --get-regexp` line parsing, none of which is
    /// reachable any other way.
    @Test(
        "a fork resolves by its upstream, not its origin",
        .tags(.smoke),
        .disabled(if: !RepoFixture.hasLocalRepo, "no local git")
    )
    func forge_prefersUpstreamOverOrigin() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await GitProcess.run(
            ["remote", "add", "origin", "https://gitlab.com/me/limpid.git"],
            cwd: repo.url
        )
        let resolver = ForgeResolver(locator: ToolLocator())
        // Only `origin` so far, and the heuristic answers for it
        // without spawning a CLI.
        #expect(await resolver.forge(for: repo.url) == .gitLab)

        _ = try await GitProcess.run(
            ["remote", "add", "upstream", "https://github.com/nek0der/limpid.git"],
            cwd: repo.url
        )
        // Still GitLab: the working-directory cache answers, which is
        // what stops every tick from re-reading remotes.
        #expect(await resolver.forge(for: repo.url) == .gitLab)

        await resolver.invalidate()
        #expect(await resolver.forge(for: repo.url) == .gitHub)
    }

    /// A checkout with no remote must resolve to nil so the syncer
    /// stops there instead of spawning a CLI that can only fail.
    @Test(
        "a checkout with no remote resolves to no forge",
        .tags(.smoke),
        .disabled(if: !RepoFixture.hasLocalRepo, "no local git")
    )
    func forge_noRemote_isNil() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let resolver = ForgeResolver(locator: ToolLocator())
        #expect(await resolver.forge(for: repo.url) == nil)
    }

    // MARK: - Forge metadata

    @Test("each forge names the CLI it shells out to")
    func forgeKind_executableNames() {
        #expect(ForgeKind.gitHub.executableName == "gh")
        #expect(ForgeKind.gitLab.executableName == "glab")
    }
}

/// Sets an environment variable for the length of a test and puts the
/// previous value back — including the case where there wasn't one.
///
/// `unsetenv` on teardown would leave a contributor who exports
/// `GH_ENTERPRISE_TOKEN` without it for the rest of the process, which
/// makes the outcome of the two probe tests depend on the order they
/// ran in.
private struct EnvironmentOverride {
    private let name: String
    private let previous: String?

    init(name: String, value: String?) {
        self.name = name
        self.previous = ProcessInfo.processInfo.environment[name]
        Self.apply(name: name, value: value)
    }

    func undo() {
        Self.apply(name: name, value: previous)
    }

    private static func apply(name: String, value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}
