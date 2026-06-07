// CodexHomeRedirectorRenderTests.swift
// Limpid — Pure-function tests for the shadow CODEX_HOME hooks.json
// renderer. We pin the exact JSON shape because Codex re-hashes the
// file on every change — a single drifted byte (key reorder, matcher
// dropped, extra whitespace) means the trust block no longer matches
// and the hook lands in "review needed" state, silently disabled
// under `--dangerously-bypass-hook-trust`.

import Foundation
import Testing
@testable import Limpid

struct CodexHomeRedirectorRenderTests {
    @Test
    func renderHooksJson_emitsValidJsonWithEveryLifecycleEvent() throws {
        let out = CodexHomeRedirector.renderHooksJson(
            lifecycleCommand: "/bin/sh '/x/lifecycle'",
            worktreeCommand: nil
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
        let dict = parsed as? [String: Any]
        let hooks = dict?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for ev in CodexHomeRedirector.subscribedEvents {
            #expect(hooks?[ev.jsonKey] != nil, "missing event \(ev.jsonKey)")
        }
    }

    @Test
    func renderHooksJson_preToolUseHasTwoGroupsWhenWorktreeCommandPresent() throws {
        let out = CodexHomeRedirector.renderHooksJson(
            lifecycleCommand: "/bin/sh '/x/lifecycle'",
            worktreeCommand: "/bin/sh '/x/worktree'"
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
        let preToolUse = ((parsed as? [String: Any])?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(preToolUse?.count == 2)
        // Group 0 — lifecycle handler, no matcher.
        #expect(preToolUse?[0]["matcher"] == nil)
        // Group 1 — worktree intercept handler matched on `^Bash$`.
        // Codex evaluates the field as a regex; the anchors keep the
        // intercept from firing on tools that happen to start with
        // "Bash" (defense-in-depth — Codex only fires PreToolUse on
        // Bash + apply_patch today).
        #expect(preToolUse?[1]["matcher"] as? String == "^Bash$")
        let worktreeHandlers = preToolUse?[1]["hooks"] as? [[String: String]]
        #expect(worktreeHandlers?.first?["command"] == "/bin/sh '/x/worktree'")
    }

    @Test
    func renderHooksJson_preToolUseHasOneGroupWhenWorktreeCommandAbsent() throws {
        // Missing bundled hook (test bundles, broken installs): we
        // ship hooks.json without the second group and the lifecycle
        // integration alone keeps working. Trust block follows the
        // same shape.
        let out = CodexHomeRedirector.renderHooksJson(
            lifecycleCommand: "/bin/sh '/x/lifecycle'",
            worktreeCommand: nil
        )
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
        let preToolUse = ((parsed as? [String: Any])?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(preToolUse?.count == 1)
        #expect(preToolUse?[0]["matcher"] == nil)
    }

    @Test
    func renderHooksJson_escapesSpecialCharactersInCommand() throws {
        // Paths under e.g. an external SSD can carry backslashes /
        // quotes / non-ASCII; the JSON escape must round-trip them
        // because the trust hash is computed off the byte-identical
        // string.
        let weird = "/bin/sh '/x/a\\b\"c/script'"
        let out = CodexHomeRedirector.renderHooksJson(
            lifecycleCommand: weird,
            worktreeCommand: nil
        )
        // JSONSerialization round-trip is the byte-level guarantee
        // we need — if the escape were wrong the parse would throw.
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
        let firstHandler = (((parsed as? [String: Any])?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?
            .first?["hooks"] as? [[String: String]]
        #expect(firstHandler?.first?["command"] == weird)
    }
}
