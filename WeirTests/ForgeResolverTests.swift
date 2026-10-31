// ForgeResolverTests.swift
// Weir — host extraction and forge classification.
//
// Everything here sits on the path that decides whether we shell out
// to a CLI at all: a wrong answer either spawns processes for a host
// we cannot serve, or silently disables the feature for one we can.
//
// Host extraction and the heuristic are pure, and carry no tag. The
// remote-priority tests run `git` in a temp repository, so they are
// tagged `.smoke` individually.

import Foundation
import Testing
@testable import Weir

@Suite("ForgeResolver")
struct ForgeResolverTests {

    // MARK: - Host extraction

    @Test(
        "extracts host from the URL forms git accepts",
        arguments: [
            ("https://github.com/nek0der/weir.git", "github.com"),
            ("https://gitlab.com/acme/app.git", "gitlab.com"),
            // scp-like syntax has no scheme, so URLComponents reports
            // no host and the fallback parser has to take over.
            ("git@github.com:nek0der/weir.git", "github.com"),
            ("git@gitlab.example.com:acme/app.git", "gitlab.example.com"),
            // No user component.
            ("github.com:nek0der/weir.git", "github.com"),
            ("ssh://git@github.com:22/nek0der/weir.git", "github.com"),
            // Host casing is normalized so cache keys collapse.
            ("https://GitHub.com/nek0der/weir.git", "github.com")
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
            // This parses as a URL, but its authority is empty. The scp
            // parser would read the scheme as the hostname and report a
            // forge host of "file", costing two probe spawns to rule out.
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
        .tags(.smoke)
    )
    func forge_prefersUpstreamOverOrigin() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await GitProcess.run(
            ["remote", "add", "origin", "https://gitlab.com/me/weir.git"],
            cwd: repo.url
        )
        let resolver = ForgeResolver(locator: ToolLocator())
        // Only `origin` so far, and the heuristic answers for it
        // without spawning a CLI.
        #expect(await resolver.forge(for: repo.url) == .gitLab)

        _ = try await GitProcess.run(
            ["remote", "add", "upstream", "https://github.com/nek0der/weir.git"],
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
        .tags(.smoke)
    )
    func forge_noRemote_isNil() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let resolver = ForgeResolver(locator: ToolLocator())
        #expect(await resolver.forge(for: repo.url) == nil)
    }
}
