// CodexHookScriptTests.swift
// Limpid — runs `codex-shim/limpid-codex-hook` against captured Codex
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
    private func runHooks(_ payloads: [[String: Any]]) throws -> [String: Any]? {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let script = root.appendingPathComponent(
                "Limpid/Resources/codex-shim/limpid-codex-hook"
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

            let record = states.appendingPathComponent("\(paneID).state.json")
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

    /// Shape mirrors what Codex 0.153.4 actually sends; `extra` carries the
    /// per-event fields observed on the wire.
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
        for event in CodexHomeRedirector.subscribedEvents {
            let record = try runHook(payload(event.jsonKey))
            #expect(
                record?["lastHookEvent"] as? String == event.jsonKey,
                "limpid-codex-hook has no branch for \(event.jsonKey)"
            )
        }
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
