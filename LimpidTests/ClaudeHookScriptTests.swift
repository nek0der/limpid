// ClaudeHookScriptTests.swift
// Limpid — runs `claude-shim/limpid-hook` against captured Claude Code
// payloads. It is the larger of the two receivers and had no coverage of
// its own until layer 2 forced the pid handling open; this suite starts
// from the harness `CodexHookScriptTests` uses and covers the pid
// resolution plus the event mapping. The rest of the receiver — prompt
// carry-over, the OSC 2 title fallback, the cwd events — is still
// uncovered.

import Foundation
import Testing
@testable import Limpid

@Suite("Claude hook receiver", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct ClaudeHookScriptTests {
    /// Replay `payloads` through the receiver against one pane, in order,
    /// and return the lifecycle record left behind — or `nil` when the
    /// receiver declined to write one. Runs against a temp state dir so
    /// the developer's real records are never touched.
    private func runHooks(
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: Any]? {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let script = root.appendingPathComponent(
                "Limpid/Resources/claude-shim/limpid-hook"
            )
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString

            for payload in payloads {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [script.path]
                // `HOME` is redirected too: the receiver falls back to
                // `$HOME/Library/...` when the state dir is unset, and a typo
                // in the env below must not send writes at the real one.
                process.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": dir.path,
                    "LIMPID_PANE_ID": paneID,
                    "LIMPID_AGENT_STATES_DIR": states.path,
                    "LIMPID_SESSIONS_DIR": dir.appendingPathComponent("sessions").path,
                    "LIMPID_CWD_EVENTS_DIR": dir.appendingPathComponent("cwd").path
                ]
                process.environment?.merge(extraEnvironment) { _, new in new }
                let stdin = Pipe()
                process.standardInput = stdin
                try process.run()
                try stdin.fileHandleForWriting.write(
                    contentsOf: JSONSerialization.data(withJSONObject: payload)
                )
                try stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                // The receiver's stated failure policy is to exit 0 no matter
                // what, so that a broken hook never blocks Claude from running.
                #expect(process.terminationStatus == 0)
            }

            let record = states.appendingPathComponent("\(paneID).state.json")
            guard let data = try? Data(contentsOf: record) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// A turn in flight: the receiver has stamped `runStartedAt` and is
    /// waiting for whatever ends the turn.
    private func midTurn() -> [[String: Any]] {
        [
            payload("SessionStart"),
            payload("UserPromptSubmit", extra: ["prompt": "count to 200"])
        ]
    }

    /// Shape mirrors what Claude Code sends on the wire; `extra` carries
    /// the per-event fields.
    private func payload(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "session_id": "6f1d6a1e-0e34-4a1a-9a8e-2f2b6c1d7f10",
            "cwd": "/tmp",
            "hook_event_name": event
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    /// The shim exports its own pid and then `exec`s claude, so outside
    /// tmux the value already is the process the Swift-side liveness
    /// sweep watches.
    @Test("prefers the pid the shim exported")
    func exportedPid_isRecorded() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": "424242"])
        #expect(record?["pid"] as? String == "424242")
    }

    /// The value reaches the record's JSON verbatim, and an inherited
    /// variable is not numeric by construction the way a value read out
    /// of `ps` is. A malformed record is dropped whole by
    /// `PaneStore.allRecords`, taking the pane's badge with it — the
    /// failure #19 fixed on the Codex side and left standing here.
    @Test("refuses an exported pid that is not a number")
    func nonNumericExportedPid_isRefused() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": "\" ,\"x\":1"])
        #expect(record?["pid"] == nil)
    }

    /// Layer 2 runs the agent inside tmux, which turns the exported pid
    /// into a liability: the shim publishes its own pid and then `exec`s
    /// tmux, so the value names the client rather than the agent, and the
    /// client is gone on the first detach. Measured 2026-09-06 — a shim
    /// exporting 50626 produced an agent running as 50629. The walk is
    /// the only source that finds the agent wherever tmux placed it, so
    /// inside tmux the inherited value is dropped rather than preferred.
    @Test("ignores the exported pid inside tmux, where it names the client")
    func exportedPid_isIgnoredInsideTmux() throws {
        let record = try runHooks(
            midTurn(),
            extraEnvironment: [
                "LIMPID_CLAUDE_PID": "424242",
                "TMUX": "/tmp/tmux-501/default,4242,0"
            ]
        )
        #expect(record?["pid"] == nil)
    }

    @Test("records no pid when the shim exported none")
    func noExportedPid_leavesThePidFieldOff() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": ""])
        #expect(record?["pid"] == nil)
    }

    /// Every assertion above is also satisfied by a walk that never
    /// matches anything, because nothing in the test host's ancestry is
    /// named `claude`. Layer 2 makes the walk the only source of the pid,
    /// so it needs one test that proves it finds something.
    @Test("walks up to an ancestor named claude when no pid was exported")
    func walk_findsTheAncestorNamedClaude() throws {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let hook = root.appendingPathComponent(
                "Limpid/Resources/claude-shim/limpid-hook"
            )
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString
            // `ps` reports the path a process was exec'd as rather than
            // the resolved one, so a symlink is enough to hand the walk
            // an ancestor with the name it looks for — and it exercises
            // the basename stripping at the same time. A copy of `sh`
            // would not work: macOS kills a relocated system binary on
            // launch (measured: exit 137).
            let fakeClaude = dir.appendingPathComponent("claude")
            try FileManager.default.createSymbolicLink(
                at: fakeClaude,
                withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )

            let process = Process()
            process.executableURL = fakeClaude
            // The trailing `true` keeps the shell from exec'ing the hook
            // in place, which would drop the `claude`-named process out
            // of the very chain the walk has to climb.
            process.arguments = ["-c", "/bin/sh '\(hook.path)'; true"]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "LIMPID_PANE_ID": paneID,
                "LIMPID_AGENT_STATES_DIR": states.path,
                "LIMPID_SESSIONS_DIR": dir.appendingPathComponent("sessions").path,
                "LIMPID_CWD_EVENTS_DIR": dir.appendingPathComponent("cwd").path
            ]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(
                contentsOf: JSONSerialization.data(withJSONObject: payload("SessionStart"))
            )
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let data = try Data(
                contentsOf: states.appendingPathComponent("\(paneID).state.json")
            )
            let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(record?["pid"] as? String == String(process.processIdentifier))
        }
    }

    /// The tab column marks a hosted pane from this flag, and the record
    /// is what clears it: `SessionEnd` and the pid sweep drop the whole
    /// record, so nothing has to notice the tmux session went away.
    @Test("records that the agent is hosted in tmux")
    func insideTmux_recordsTheHostedFlag() throws {
        let record = try runHooks(
            midTurn(),
            extraEnvironment: ["TMUX": "/tmp/tmux-501/limpid,4242,0"]
        )
        #expect(record?["isTmuxHosted"] as? Bool == true)
    }

    @Test("leaves the hosted flag off outside tmux")
    func outsideTmux_omitsTheHostedFlag() throws {
        #expect(try runHooks(midTurn())?["isTmuxHosted"] == nil)
    }

    /// The template is what Claude is actually told to call us on, so it
    /// is the list the receiver has to keep up with. An event subscribed
    /// but never mapped leaves the pane frozen on its last state, and
    /// nothing else notices. `CwdChanged` is excluded because it writes a
    /// cwd event rather than a lifecycle state; it is asserted below.
    @Test("every subscribed event maps to a lifecycle state")
    func subscribedEvents_allReachABranch() throws {
        for event in try Self.subscribedEvents() where event != "CwdChanged" {
            let record = try runHooks(midTurn() + [payload(event, extra: Self.extras(for: event))])
            #expect(
                record?["lastHookEvent"] as? String == event,
                "claude-shim/limpid-hook has no branch for \(event)"
            )
        }
    }

    /// Reads the event names out of `settings.template.json`, which the
    /// shim hands to `claude --settings` after substituting hook paths.
    private static func subscribedEvents() throws -> [String] {
        let root = try #require(RepoFixture.limpidRoot)
        let template = root.appendingPathComponent(
            "Limpid/Resources/claude-shim/settings.template.json"
        )
        let filled = try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "@@HOOK@@", with: "/hook")
            .replacingOccurrences(of: "@@WORKTREE_PRETOOL_HOOK@@", with: "/pretool")
        let json = try JSONSerialization.jsonObject(with: Data(filled.utf8))
        let hooks = try #require((json as? [String: Any])?["hooks"] as? [String: Any])
        #expect(!hooks.isEmpty)
        return hooks.keys.sorted()
    }

    /// The fields an event needs before it reaches a state at all: a
    /// `Notification` that is not a permission prompt is deliberately
    /// ignored, and `PreToolUse` keys off the tool name.
    private static func extras(for event: String) -> [String: Any] {
        switch event {
        case "Notification": ["notification_type": "permission_prompt", "message": "needs permission"]
        case "PreToolUse": ["tool_name": "Bash"]
        case "StopFailure": ["error_type": "overloaded"]
        case "SessionEnd": ["reason": "other"]
        default: [:]
        }
    }
}
