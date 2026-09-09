// AgentRuntimeHookRegressionTests.swift
// Limpid — regressions at the real shell and filesystem boundaries.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent runtime hook regressions", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo))
struct AgentRuntimeHookRegressionTests {
    @Test func legacyClaudeQuit_removesOnlyMatchingResumeHint() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let paneID = UUID().uuidString
            let sessionID = UUID().uuidString
            let sessions = directory.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let hint = sessions.appendingPathComponent(paneID + ".json")
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "paneId": paneID, "sessionId": sessionID,
                "cwd": directory.path, "updatedAt": "2026-09-09T00:00:00Z"
            ]).write(to: hint)
            _ = try shell("""
            printf '{"hook_event_name":"SessionEnd","reason":"quit","session_id":"%s","cwd":"/tmp"}' "$SESSION" | /bin/sh "$HOOK"
            """, directory: directory, environment: [
                "SESSION": sessionID, "HOOK": root.appendingPathComponent("Limpid/Resources/claude-shim/limpid-hook").path,
                "LIMPID_PANE_ID": paneID, "LIMPID_CLAUDE_PID": "2147483646",
                "LIMPID_SESSIONS_DIR": sessions.path,
                "LIMPID_AGENT_STATES_DIR": directory.appendingPathComponent("states").path,
                "LIMPID_CWD_EVENTS_DIR": directory.appendingPathComponent("cwd").path
            ])
            #expect(!FileManager.default.fileExists(atPath: hint.path))
        }
    }

    private func shell(_ command: String, directory: URL, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.path]
        process.environment?.merge(environment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func eachInvocation_replacesInheritedRunID() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let output = try shell("""
            . "$HELPER"
            limpid_ensure_run_id
            printf '%s\\n' "$LIMPID_AGENT_RUN_ID"
            limpid_ensure_run_id
            printf '%s\\n' "$LIMPID_AGENT_RUN_ID"
            """, directory: directory, environment: [
                "HELPER": root.appendingPathComponent("Limpid/Resources/agent-shim/runtime-common.sh").path,
                "LIMPID_AGENT_RUN_ID": "11111111-1111-1111-1111-111111111111"
            ])
            let ids = output.split(separator: "\n").map(String.init)
            #expect(ids.count == 2)
            #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
            #expect(Set(ids).count == 2)
            #expect(!ids.contains("11111111-1111-1111-1111-111111111111"))
        }
    }

    @Test func symlinkedClaudeHook_preservesRunIdentityAndRevision() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let link = directory.appendingPathComponent("limpid-hook")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: root.appendingPathComponent("Limpid/Resources/claude-shim/limpid-hook")
            )
            let runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            _ = try shell("""
            for event in SessionStart UserPromptSubmit; do
              printf '{"hook_event_name":"%s","session_id":"33333333-3333-3333-3333-333333333333","cwd":"/tmp"}' "$event" | /bin/sh "$HOOK"
            done
            """, directory: directory, environment: [
                "HOOK": link.path, "LIMPID_PANE_ID": UUID().uuidString,
                "LIMPID_AGENT_RUN_ID": runID, "LIMPID_CLAUDE_PID": "424242",
                "LIMPID_AGENT_STATES_DIR": states.path,
                "LIMPID_SESSIONS_DIR": directory.appendingPathComponent("sessions").path,
                "LIMPID_CWD_EVENTS_DIR": directory.appendingPathComponent("cwd").path
            ])
            let store = ClaudeAgentStateStore(directory: states)
            let record = try #require(store.allRecords().first)
            #expect(record.runId == runID)
            #expect(record.revision == 2)
        }
    }

    @Test func kernelLock_excludesAnotherWriterAndRecoversAfterKill() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let output = try shell("""
            (
              . "$HELPER"
              limpid_acquire_record_lock "$TARGET" || exit 1
              : > "$READY"
              exec /bin/sleep 10
            ) &
            owner=$!
            trap 'kill -KILL "$owner" 2>/dev/null || true' EXIT
            attempts=0
            while [ ! -f "$READY" ]; do
              attempts=$((attempts + 1))
              [ "$attempts" -lt 200 ] || exit 1
              sleep 0.01
            done
            . "$HELPER"
            if limpid_acquire_record_lock "$TARGET"; then printf 'unsafe\\n'; else printf 'blocked\\n'; fi
            kill -KILL "$owner"
            wait "$owner" 2>/dev/null || true
            trap - EXIT
            if limpid_acquire_record_lock "$TARGET"; then printf 'recovered\\n'; fi
            """, directory: directory, environment: [
                "HELPER": root.appendingPathComponent("Limpid/Resources/agent-shim/runtime-common.sh").path,
                "TARGET": directory.appendingPathComponent("record").path,
                "READY": directory.appendingPathComponent("ready").path
            ])
            #expect(output == "blocked\nrecovered\n")
        }
    }

    @Test func newRuntime_doesNotRemoveConcurrentLegacyRecord() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let paneID = UUID().uuidString
            let runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
            let legacy = states.appendingPathComponent("\(paneID).state.json")
            let sentinel = Data("legacy writer owns this file".utf8)
            try sentinel.write(to: legacy)
            _ = try shell("""
            printf '{"hook_event_name":"SessionStart","session_id":"33333333-3333-3333-3333-333333333333","cwd":"/tmp"}' | /bin/sh "$HOOK"
            """, directory: directory, environment: [
                "HOOK": root.appendingPathComponent("Limpid/Resources/codex-shim/limpid-hook").path,
                "LIMPID_PANE_ID": paneID, "LIMPID_AGENT_RUN_ID": runID,
                "LIMPID_CODEX_PID": "424242", "LIMPID_CODEX_AGENT_STATES_DIR": states.path,
                "LIMPID_CODEX_SESSIONS_DIR": directory.appendingPathComponent("sessions").path
            ])
            #expect(try Data(contentsOf: legacy) == sentinel)
            #expect(FileManager.default.fileExists(atPath: states.appendingPathComponent("\(runID).state.json").path))
        }
    }

    @Test func tmuxEndpoint_usesEnvironmentWithoutContactingServer() throws {
        try withTempDir { directory in
            let root = try #require(RepoFixture.limpidRoot)
            let output = try shell("""
            . "$HELPER"
            limpid_capture_tmux_endpoint
            printf '%s\\n%s\\n' "$LIMPID_RUNTIME_TMUX_SOCKET" "$LIMPID_RUNTIME_TMUX_PANE"
            """, directory: directory, environment: [
                "HELPER": root.appendingPathComponent("Limpid/Resources/agent-shim/runtime-common.sh").path,
                "TMUX": "/private/tmp/custom,socket,2147483646,7", "TMUX_PANE": "%8",
                "LIMPID_AGENT_TMUX": "/usr/bin/false"
            ])
            #expect(output == "/private/tmp/custom,socket\n%8\n")
        }
    }
}
