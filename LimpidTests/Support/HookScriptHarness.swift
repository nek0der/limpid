// HookScriptHarness.swift
// Limpid — runs an agent's `limpid-hook` wrapper, and through it the Hook Helper, against one pane.

import Foundation
import Testing

/// The agents whose shim hands hook calls to the Hook Helper. Both wrappers
/// exec the same helper, so what differs between them is data: the
/// variables their shim exports and the payloads their agent sends.
enum HookAgent: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case claude
    case codex

    var testDescription: String {
        rawValue
    }

    /// The variable naming the folder the run records land in.
    var statesVariable: String {
        switch self {
        case .claude: "LIMPID_AGENT_STATES_DIR"
        case .codex: "LIMPID_CODEX_AGENT_STATES_DIR"
        }
    }

    /// The variable naming the folder the resume hints land in.
    var sessionsVariable: String {
        switch self {
        case .claude: "LIMPID_SESSIONS_DIR"
        case .codex: "LIMPID_CODEX_SESSIONS_DIR"
        }
    }

    /// The variable naming the folder working-directory events land in.
    /// Only Claude reports a change of directory, so Codex has none.
    var cwdEventsVariable: String? {
        switch self {
        case .claude: "LIMPID_CWD_EVENTS_DIR"
        case .codex: nil
        }
    }

    /// The pid the shim exports before it execs the agent.
    var pidVariable: String {
        switch self {
        case .claude: "LIMPID_CLAUDE_PID"
        case .codex: "LIMPID_CODEX_PID"
        }
    }

    /// A conversation id of the shape this agent sends.
    var sessionID: String {
        switch self {
        case .claude: "6f1d6a1e-0e34-4a1a-9a8e-2f2b6c1d7f10"
        case .codex: "01a072a0-05a3-7d73-8f0e-045219d01e4f"
        }
    }

    /// The wrapper the agent is told to call, in the source tree.
    func wrapper(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try #require(RepoFixture.limpidRoot, sourceLocation: sourceLocation)
            .appendingPathComponent("Limpid/Resources/\(rawValue)-shim/limpid-hook")
    }

    /// The folders this agent's shim names, all inside `dir`, for `paneID`.
    /// `HOME` is `dir` too: the helper finds the agent's own folder
    /// (`~/.claude`, `~/.codex`) under `$HOME` when its variable is unset,
    /// and a test must not reach the real one.
    func environment(in dir: URL, paneID: String) -> [String: String] {
        var environment = [
            "PATH": ShimHarness.systemPath,
            "HOME": dir.path,
            "LIMPID_PANE_ID": paneID,
            statesVariable: dir.appendingPathComponent("states").path,
            sessionsVariable: dir.appendingPathComponent("sessions").path
        ]
        if let cwdEventsVariable {
            environment[cwdEventsVariable] = dir.appendingPathComponent("cwd").path
        }
        return environment
    }

    /// A payload of the shape this agent sends; `extra` carries the
    /// per-event fields.
    func payload(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = ["session_id": sessionID, "cwd": "/tmp", "hook_event_name": event]
        base.merge(extra) { _, new in new }
        return base
    }

    /// A turn in flight: the helper has stamped `runStartedAt` and waits for
    /// whatever ends the turn.
    func midTurn() -> [[String: Any]] {
        [payload("SessionStart"), payload("UserPromptSubmit", extra: ["prompt": "count to 200"])]
    }
}

/// Runs a `HookAgent`'s wrapper with the bundled helper beside the test host.
enum HookScriptHarness {
    /// Feeds `payload` to `process` on stdin, then waits for it, at most ten
    /// seconds, so a wrapper stuck on input fails its test instead of the run.
    static func feed(
        _ payload: [String: Any],
        to process: Process,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try stdin.fileHandleForWriting.close()
        #expect(process.waitUntilExit(within: 10), "the hook did not exit within ten seconds", sourceLocation: sourceLocation)
    }

    /// Replays `payloads` through `agent`'s wrapper against one pane, in
    /// order, and returns the run record left behind, or nil when none was
    /// written. A sequence rather than one event, because the fields that
    /// carry across turns (`runStartedAt`, `firstPrompt`) only misbehave once
    /// there is a previous record to carry them from. `afterEach` sees the
    /// scratch folder, the states folder, the pane id, and the event's index
    /// after each event; `prepare` sees the first three before the first.
    /// `wrapper` stands in for the agent's own, a link to it for instance.
    static func runHooks(
        _ agent: HookAgent,
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:],
        wrapper: URL? = nil,
        afterEach: ((URL, URL, String, Int) throws -> Void)? = nil,
        prepare: ((URL, URL, String) throws -> Void)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any]? {
        try withTempDir { dir in
            let wrapper = try wrapper ?? agent.wrapper(sourceLocation: sourceLocation)
            let helper = try #require(HookHelperFixture.helperURL, sourceLocation: sourceLocation)
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString
            try prepare?(dir, states, paneID)
            for (eventIndex, payload) in payloads.enumerated() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [wrapper.path]
                // A payload without a `cwd` happened where the hook runs.
                // That is this run's scratch folder, not the test host's
                // own directory, so such an event can never snapshot a
                // repository the test did not make.
                process.currentDirectoryURL = dir
                var environment = agent.environment(in: dir, paneID: paneID)
                environment["LIMPID_HOOK_HELPER"] = helper.path
                environment.merge(extraEnvironment) { _, new in new }
                process.environment = IsolatedProcessEnvironment.make(environment)
                try feed(payload, to: process, sourceLocation: sourceLocation)
                // The helper exits 0 whatever happens, so that a broken hook
                // never blocks the agent from running.
                #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)
                try afterEach?(dir, states, paneID, eventIndex)
            }
            let recordID = extraEnvironment["LIMPID_AGENT_RUN_ID"] ?? paneID
            let record = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(recordID))
            guard let data = try? Data(contentsOf: record) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// The record after each of `payloads`, rather than only the last one,
    /// so one sequence pins the transitions event by event.
    static func replayRecords(_ agent: HookAgent, _ payloads: [[String: Any]]) throws -> [[String: Any]] {
        var records = [[String: Any]]()
        _ = try runHooks(agent, payloads, extraEnvironment: ["LIMPID_TURN_SNAPSHOT": "0"]) { _, states, paneID, _ in
            let url = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
            let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            records.append(record)
        }
        return records
    }

    /// Text a record holds under `key`; nil when it is absent, which a record
    /// may write as null, leave out, or leave empty.
    static func optionalText(_ record: [String: Any], _ key: String) -> String? {
        guard let text = record[key] as? String, !text.isEmpty else { return nil }
        return text
    }
}
