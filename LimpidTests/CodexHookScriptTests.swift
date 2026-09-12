// CodexHookScriptTests.swift
// Limpid — runs `codex-shim/limpid-hook` against captured Codex
// payloads. The receiver carries the whole lifecycle mapping, so a wrong or
// missing branch stays invisible until a badge sticks in the sidebar. Its
// Claude counterpart is the larger of the two and still has no coverage of
// its own; the same harness shape would cover it.

import Foundation
import Testing
@testable import Limpid

@Suite("Codex hook receiver", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct CodexHookScriptTests {
    /// Replay `payloads` through the receiver against one pane, in order,
    /// and return the lifecycle record left behind — or `nil` when the
    /// receiver declined to write one. A sequence rather than a single
    /// event because the fields that carry across turns (`runStartedAt`,
    /// `firstPrompt`) only misbehave once there is a previous record to
    /// carry them from. Runs against a temp state dir so the developer's
    /// real records are never touched.
    private func runHooks(
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: Any]? {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let script = root.appendingPathComponent(
                "Limpid/Resources/codex-shim/limpid-hook"
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
                    "LIMPID_CODEX_AGENT_STATES_DIR": states.path,
                    "LIMPID_CODEX_SESSIONS_DIR": dir.appendingPathComponent("sessions").path
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
                // what, so that a broken hook never blocks Codex from running.
                #expect(process.terminationStatus == 0)
            }

            let recordID = extraEnvironment["LIMPID_AGENT_RUN_ID"] ?? paneID
            let record = states.appendingPathComponent("\(recordID).state.json")
            guard let data = try? Data(contentsOf: record) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func runHook(_ payload: [String: Any]) throws -> [String: Any]? {
        try runHooks([payload])
    }

    /// A turn in flight: the receiver has stamped `runStartedAt` and is
    /// waiting for whatever ends the turn.
    private func midTurn() -> [[String: Any]] {
        [
            payload("SessionStart"),
            payload("UserPromptSubmit", extra: ["prompt": "count to 200"])
        ]
    }

    /// Shape mirrors what Codex sent on the wire when this was measured
    /// (2026-09); `extra` carries the per-event fields.
    private func payload(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "session_id": "01a072a0-05a3-7d73-8f0e-045219d01e4f",
            "cwd": "/tmp",
            "hook_event_name": event
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    /// The receiver's header states that it needs a branch for every name
    /// `subscribedEvents` carries. Enforcing that here is what stops the bug
    /// this suite was written for from coming back in a new shape: a hook
    /// subscribed but never mapped leaves the pane frozen on its last state,
    /// and nothing else notices.
    @Test("every subscribed event maps to a lifecycle state")
    func subscribedEvents_allReachABranch() throws {
        for event in CodexHookInstaller.subscribedEvents {
            let record = try runHook(payload(event.jsonKey))
            #expect(
                record?["lastHookEvent"] as? String == event.jsonKey,
                "codex-shim/limpid-hook has no branch for \(event.jsonKey)"
            )
        }
    }

    /// The shim exports its own pid and then `exec`s codex, so the value
    /// already is the process the Swift-side liveness sweep watches. The
    /// receiver's parent walk stays as the fallback for a codex started
    /// outside the shim, but guessing by `comm` cannot distinguish two
    /// codex processes in the same tree — the exported value can.
    @Test("prefers the pid the shim exported over walking the process tree")
    func exportedPid_isRecordedVerbatim() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CODEX_PID": "424242"])
        #expect(record?["pid"] as? String == "424242")
    }

    /// The walk read its pid out of `ps`, so it was numeric by
    /// construction. An inherited variable is not, and the value goes
    /// into the record's JSON verbatim.
    @Test("falls back to the walk when the exported pid is not a number")
    func nonNumericExportedPid_isRefused() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CODEX_PID": "\" ,\"x\":1"])
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
                "LIMPID_CODEX_PID": "424242",
                "TMUX": "/tmp/tmux-501/default,4242,0"
            ]
        )
        #expect(record?["pid"] == nil)
    }

    @Test("records no pid when the shim exported none")
    func noExportedPid_leavesThePidFieldOff() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CODEX_PID": ""])
        #expect(record?["pid"] == nil)
    }

    /// The tmux test above is satisfied by a walk that never matches
    /// anything, because nothing in the test host's ancestry is named
    /// `codex`. Hosting the agent in tmux makes the walk the only source
    /// of the pid, so it needs one test that proves it finds something.
    @Test("walks up to an ancestor named codex when no pid was exported")
    func walk_findsTheAncestorNamedCodex() throws {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let hook = root.appendingPathComponent(
                "Limpid/Resources/codex-shim/limpid-hook"
            )
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString
            // `ps` reports the path a process was exec'd as rather than
            // the resolved one, so a symlink hands the walk an ancestor
            // with the name it looks for, and exercises the basename
            // stripping at the same time. A copy of `sh` would not work:
            // macOS kills a relocated system binary on launch.
            let fakeCodex = dir.appendingPathComponent("codex")
            try FileManager.default.createSymbolicLink(
                at: fakeCodex,
                withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )

            let process = Process()
            process.executableURL = fakeCodex
            // The trailing `true` keeps the shell from exec'ing the hook
            // in place, which would drop the `codex`-named process out
            // of the very chain the walk has to climb.
            process.arguments = ["-c", "/bin/sh '\(hook.path)'; true"]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "LIMPID_PANE_ID": paneID,
                "LIMPID_CODEX_AGENT_STATES_DIR": states.path,
                "LIMPID_CODEX_SESSIONS_DIR": dir.appendingPathComponent("sessions").path
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

    @Test("keys one invocation by run id and increments its revision")
    func runIdentity_multipleEvents_shareOneOrderedRecord() throws {
        let runID = UUID().uuidString
        let record = try runHooks(
            midTurn(),
            extraEnvironment: ["LIMPID_AGENT_RUN_ID": runID]
        )
        #expect(record?["runId"] as? String == runID)
        #expect(record?["revision"] as? Int == 2)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    @Test("keeps one episode token across repeated waiting writes")
    func waitingEpisode_repeatedState_keepsToken() throws {
        let record = try runHooks([
            payload("UserPromptSubmit"),
            payload("PermissionRequest"),
            payload("PermissionRequest")
        ])
        #expect(record?["state"] as? String == "needsInput")
        #expect(record?["revision"] as? Int == 3)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    @Test("Stop maps to finished")
    func stop_mapsToFinished() throws {
        let record = try runHook(payload("Stop"))
        #expect(record?["state"] as? String == "finished")
    }

    @Test("Interrupt maps to finished — Codex sends no Stop for an interrupted turn")
    func interrupt_mapsToFinished() throws {
        let record = try runHook(
            payload("Interrupt", extra: ["turn_id": "01a072a0-4bb0-7020-959e-40c97c391d17"])
        )
        #expect(record?["state"] as? String == "finished")
        #expect(record?["lastHookEvent"] as? String == "Interrupt")
    }

    @Test("SessionEnd clears the lifecycle back to unknown")
    func sessionEnd_mapsToUnknown() throws {
        let record = try runHook(payload("SessionEnd", extra: ["reason": "other"]))
        #expect(record?["state"] as? String == "unknown")
        #expect(record?["lastHookEvent"] as? String == "SessionEnd")
    }

    @Test("Stop stops the elapsed timer")
    func stop_clearsRunStartedAt() throws {
        let record = try runHooks(midTurn() + [payload("Stop")])
        #expect(record?["runStartedAt"] as? String == "")
    }

    @Test("Interrupt stops the elapsed timer — the turn ended, it just ended early")
    func interrupt_clearsRunStartedAt() throws {
        let record = try runHooks(midTurn() + [payload("Interrupt")])
        #expect(record?["runStartedAt"] as? String == "")
    }

    @Test("SessionEnd stops the elapsed timer")
    func sessionEnd_clearsRunStartedAt() throws {
        let record = try runHooks(
            midTurn() + [payload("SessionEnd", extra: ["reason": "other"])]
        )
        #expect(record?["runStartedAt"] as? String == "")
    }
}
