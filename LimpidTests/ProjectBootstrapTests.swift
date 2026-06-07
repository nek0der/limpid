// ProjectBootstrapTests.swift
// Limpid — Covers the on-disk Codable shape of `Project.bootstrap` and `BootstrapItem`.

import Foundation
import Testing
@testable import Limpid

struct ProjectBootstrapTests {

    // MARK: - Project Codable forward-compat

    @Test
    func projectDecodes_legacyStateJsonWithoutBootstrap() throws {
        // Snapshot of how a Project was serialized before the bootstrap
        // field existed. The loader must not fail here — a
        // `keyNotFound("bootstrap")` would lose every existing user
        // project on first launch with the new build.
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
        let project = try JSONDecoder().decode(
            Project.self, from: Data(legacy.utf8)
        )
        #expect(project.bootstrap.isEmpty)
        #expect(project.name == "Test")
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
    func bootstrapItem_defaultTimeoutMatchesClaudeCodeHookDefault() {
        // The 600s default lines up with Claude Code's own PreToolUse
        // hook timeout so a long bootstrap step won't get killed by
        // the upstream hook before our wrapper would have.
        #expect(BootstrapDetail.defaultTimeoutSeconds == 600)
    }

    // MARK: - Smart-punctuation normalisation

    @Test
    func sanitiseSmartPunctuation_normalisesCurlyDoubleQuotes() {
        // macOS' default `NSTextView` rewrites a typed `"` into
        // U+201C / U+201D. PlainTextEditor disables that at the input
        // layer; sanitiseSmartPunctuation is the belt-and-braces pass
        // for state.json hand-edits or older snapshots.
        let input = "echo \u{201C}hi\u{201D}"
        let output = ContainerSettingsSheet.sanitiseSmartPunctuation(input)
        #expect(output == "echo \"hi\"")
    }

    @Test
    func sanitiseSmartPunctuation_normalisesCurlySingleQuotes() {
        let input = "git commit -m \u{2018}fix\u{2019}"
        let output = ContainerSettingsSheet.sanitiseSmartPunctuation(input)
        #expect(output == "git commit -m 'fix'")
    }

    @Test
    func sanitiseSmartPunctuation_isNoopOnAscii() {
        let input = "echo \"hi\" && rm -f /tmp/x"
        #expect(ContainerSettingsSheet.sanitiseSmartPunctuation(input) == input)
    }

    // MARK: - routeClaudeWorktrees forward-compat

    @Test
    func projectDecodes_legacyStateJsonWithoutRouteClaude_defaultsToTrue() throws {
        // Older state.json predates the per-project Claude-routing
        // toggle. The loader must default to `true` so existing users
        // stay on the wedge ("Limpid governs Claude's git worktree
        // add") after upgrading.
        let legacy = #"""
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "Test",
          "rootURL": "file:///tmp/test",
          "worktrees": [],
          "isExpanded": true,
          "worktreePlacement": { "siblingPrefixed": {} }
        }
        """#
        let project = try JSONDecoder().decode(
            Project.self, from: Data(legacy.utf8)
        )
        #expect(project.routeClaudeWorktrees)
    }

    @Test
    func projectRoundtrips_routeClaudeWorktrees() throws {
        let project = Project(
            name: "Test",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            routeClaudeWorktrees: false
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.routeClaudeWorktrees == false)
    }

    // MARK: - routeCodexWorktrees forward-compat

    @Test
    func projectDecodes_legacyStateJsonWithoutRouteCodex_defaultsToTrue() throws {
        // State.json predating the per-agent Codex toggle must still
        // load — and default to `true` so the wedge stays active
        // after upgrade, same opinionation as routeClaudeWorktrees.
        let legacy = #"""
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "Test",
          "rootURL": "file:///tmp/test",
          "worktrees": [],
          "isExpanded": true,
          "worktreePlacement": { "siblingPrefixed": {} }
        }
        """#
        let project = try JSONDecoder().decode(
            Project.self, from: Data(legacy.utf8)
        )
        #expect(project.routeCodexWorktrees)
    }

    @Test
    func projectRoundtrips_routeCodexWorktrees() throws {
        let project = Project(
            name: "Test",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            routeCodexWorktrees: false
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.routeCodexWorktrees == false)
    }

    @Test
    func projectToggles_areIndependent() throws {
        // Two per-agent flags must round-trip independently — e.g. a
        // user who trusts Claude with bootstrap but wants Codex on
        // its defaults flips one without touching the other.
        let project = Project(
            name: "Test",
            rootURL: URL(fileURLWithPath: "/tmp/test"),
            routeClaudeWorktrees: false,
            routeCodexWorktrees: true
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded.routeClaudeWorktrees == false)
        #expect(decoded.routeCodexWorktrees == true)
    }
}
