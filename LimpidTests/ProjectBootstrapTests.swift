// ProjectBootstrapTests.swift
// Limpid — the on-disk shape of a project's setup (`Project.bootstrap`, `BootstrapItem`) and its worktree routing.

import Foundation
import Testing
@testable import Limpid

struct ProjectBootstrapTests {

    // MARK: - Project Codable forward-compat

    /// A project as a build before the setup and the worktree routing
    /// wrote it still loads: a `keyNotFound` would lose every project on
    /// the first launch of the new build. It has no setup, and Limpid
    /// routes both agents' worktrees, as it did then.
    @Test
    func projectDecodes_aFileWithoutSetupOrRouting_withTheirDefaults() throws {
        let legacy = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Test",
          "rootURL": "file:///tmp/test",
          "worktrees": [],
          "isExpanded": true,
          "worktreePlacement": { "siblingPrefixed": {} }
        }
        """#
        let project = try JSONDecoder().decode(Project.self, from: Data(legacy.utf8))
        #expect(project.name == "Test")
        #expect(project.bootstrap.isEmpty)
        #expect(project.routeClaudeWorktrees)
        #expect(project.routeCodexWorktrees)
    }

    @Test
    func projectRoundtrips_bootstrapShorthandAndDetailed() throws {
        let project = Project(
            name: "Test",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            bootstrap: [
                .shorthand("pnpm install"),
                .detailed(BootstrapDetail(cmd: "make ghostty", timeout: 1800)),
                .detailed(BootstrapDetail(cmd: "prisma migrate dev", cwd: "apps/api"))
            ]
        )
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)

        #expect(decoded.bootstrap.count == 3)
        #expect(decoded.bootstrap[0].cmd == "pnpm install")
        #expect(decoded.bootstrap[0].timeout == BootstrapDetail.defaultTimeoutSeconds)
        #expect(decoded.bootstrap[0].cwd == nil)
        #expect(decoded.bootstrap[1].cmd == "make ghostty")
        #expect(decoded.bootstrap[1].timeout == 1800)
        #expect(decoded.bootstrap[2].cmd == "prisma migrate dev")
        #expect(decoded.bootstrap[2].cwd == "apps/api")
    }

    // MARK: - BootstrapItem oneOf

    @Test
    func bootstrapItem_shorthandDecodesFromBareString() throws {
        let item = try JSONDecoder().decode(
            BootstrapItem.self,
            from: Data(#""pnpm install""#.utf8)
        )
        switch item {
        case let .shorthand(s):
            #expect(s == "pnpm install")
        case .detailed:
            Issue.record("expected shorthand")
        }
    }

    @Test
    func bootstrapItem_detailedDecodesFromObject() throws {
        let item = try JSONDecoder().decode(
            BootstrapItem.self,
            from: Data(#"{"cmd":"pnpm install","timeout":300}"#.utf8)
        )
        switch item {
        case .shorthand:
            Issue.record("expected detailed")
        case let .detailed(d):
            #expect(d.cmd == "pnpm install")
            #expect(d.timeout == 300)
            #expect(d.cwd == nil)
        }
    }

    @Test
    func bootstrapItem_shorthandSerialisesAsBareString() throws {
        let encoded = try JSONEncoder().encode(BootstrapItem.shorthand("pnpm install"))
        let text = String(data: encoded, encoding: .utf8)
        // Bare JSON string, not wrapped in an object — that's the
        // contract `limpid-pretool-worktree-hook` reads via `jq`.
        #expect(text == #""pnpm install""#)
    }

    @Test
    func bootstrapItem_detailedDropsUnsetOptionalFields() throws {
        let encoded = try JSONEncoder().encode(
            BootstrapItem.detailed(BootstrapDetail(cmd: "make"))
        )
        let parsed = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(parsed?["cmd"] as? String == "make")
        // `timeout` / `cwd` stayed nil so they shouldn't appear at all
        // (otherwise the hook script would have to special-case
        // `null` vs absent when reading via jq).
        #expect(parsed?["timeout"] == nil)
        #expect(parsed?["cwd"] == nil)
    }

    @Test
    func bootstrapItem_defaultTimeoutStaysAtTenMinutes() {
        // We chose 600s to line up with Claude Code's own hook timeout, so a
        // long bootstrap step is not killed by the upstream hook before our
        // wrapper would have. This pins our own value against an accidental
        // edit; it cannot tell when Claude Code changes theirs.
        #expect(BootstrapDetail.defaultTimeoutSeconds == 600)
    }

    // MARK: - Worktree routing

    /// Each agent's routing is saved on its own: a person who trusts
    /// Claude's worktrees to Limpid can leave Codex on its defaults.
    @Test(arguments: [(false, true), (true, false), (false, false)])
    func projectRoundtrips_eachAgentsWorktreeRouting(claude: Bool, codex: Bool) throws {
        let project = Project(
            name: "Test",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            routeClaudeWorktrees: claude,
            routeCodexWorktrees: codex
        )
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.routeClaudeWorktrees == claude)
        #expect(decoded.routeCodexWorktrees == codex)
    }
}
