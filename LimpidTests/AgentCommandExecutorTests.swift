// AgentCommandExecutorTests.swift
// Limpid — the executor is the only place that removes agent state, so these
// pin what it does when the file has moved on since the rules read it.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentCommandExecutor")
struct AgentCommandExecutorTests {
    private static let pane = "11111111-1111-4111-8111-111111111111"
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"

    private struct Fixture {
        let executor: AgentCommandExecutor
        let state: URL
        let sessions: URL
        let intents: URL
    }

    private func fixture(in root: URL) throws -> Fixture {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let intents = root.appendingPathComponent("resume-intents", isDirectory: true)
        for directory in [state, sessions, intents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return Fixture(
            executor: AgentCommandExecutor(
                directories: ["claude": AgentDirectories(state: state, sessions: sessions, cwdEvents: nil)],
                resumeIntents: AgentResumeIntentStore(directory: intents)
            ),
            state: state,
            sessions: sessions,
            intents: intents
        )
    }

    private func writeRecord(_ fixture: Fixture, revision: Int = 4, pid: String = "4242") throws {
        let record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": Self.pane,
            "runId": Self.run,
            "revision": revision,
            "state": "finished",
            "updatedAt": "2026-09-14T12:00:00Z",
            "pid": pid
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: fixture.state.appendingPathComponent("\(Self.run).state.json"))
    }

    private func writeHint(_ fixture: Fixture, runID: String) throws {
        let hint: [String: Any] = ["schemaVersion": 1, "paneId": Self.pane, "runId": runID, "sessionId": "S"]
        try JSONSerialization.data(withJSONObject: hint)
            .write(to: fixture.sessions.appendingPathComponent("\(Self.pane).json"))
    }

    private func commands(_ json: String) throws -> [AgentProjectionCommand] {
        try JSONDecoder().decode([AgentProjectionCommand].self, from: Data(json.utf8))
    }

    /// The retirement chain the projection emits for a dead run: drop the hint
    /// best-effort, then move the record aside only if nothing rewrote it.
    private func retirementChain(revision: Int = 4, pid: String = "4242", hintRunID: String) -> String {
        """
        [{
          "op": {"op": "delete"},
          "target": {"target": "sessionHint", "provider": "claude", "pane": "\(Self.pane)"},
          "expect": {"expect": "hintOwner", "runId": "\(hintRunID)"},
          "onMismatch": "continue",
          "then": [{
            "op": {"op": "retire"},
            "target": {"target": "record", "provider": "claude", "storageId": "\(Self.run)"},
            "expect": {"expect": "recordUnchanged", "storageId": "\(Self.run)",
                       "revision": \(revision), "pid": "\(pid)", "updatedAt": "2026-09-14T12:00:00Z"},
            "onMismatch": "abort"
          }]
        }]
        """
    }

    @Test("a matching chain drops the hint and moves the record aside")
    func retirementChain_appliesBoth() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            try writeHint(fixture, runID: Self.run)

            let outcomes = try fixture.executor.run(commands(retirementChain(hintRunID: Self.run)))
            #expect(outcomes.count == 2)

            #expect(!FileManager.default.fileExists(atPath: fixture.sessions.appendingPathComponent("\(Self.pane).json").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))

            // Retiring is a move, not a delete: a record that turns out to
            // have been live is still there to be read.
            let retired = try FileManager.default.contentsOfDirectory(
                atPath: fixture.state.appendingPathComponent("retired").path
            )
            #expect(retired.count == 1)
            #expect(retired[0].hasPrefix(Self.run))
        }
    }

    @Test("a hint that belongs to a newer run is left alone but the record still goes")
    func hintOwnerMismatch_continuesToRetire() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            try writeHint(fixture, runID: "SOMEONE-ELSE")

            let outcomes = try fixture.executor.run(commands(retirementChain(hintRunID: Self.run)))
            #expect(outcomes.count == 2)

            // The pane has moved on, so the hint stays where it is. The dead
            // record still has to go or it would be re-examined forever.
            #expect(FileManager.default.fileExists(atPath: fixture.sessions.appendingPathComponent("\(Self.pane).json").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))
        }
    }

    @Test("a record a hook rewrote is not retired")
    func recordChanged_abortsTheChain() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            // The projection read revision 4; a hook has written 5 since.
            try writeRecord(fixture, revision: 5)
            try writeHint(fixture, runID: Self.run)

            try fixture.executor.run(commands(retirementChain(hintRunID: Self.run)))
            #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))
        }
    }

    @Test("an update sets and clears exactly the fields it names")
    func update_appliesThePatch() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            let json = """
            [{
              "op": {"op": "update", "state": {"set": "unknown"}, "pid": "clear",
                     "resumeAttemptedAt": {"set": "2026-09-15T12:00:00Z"}},
              "target": {"target": "record", "provider": "claude", "storageId": "\(Self.run)"},
              "expect": {"expect": "pidAndRevision", "pid": "4242", "revision": 4},
              "onMismatch": "continue"
            }]
            """
            try fixture.executor.run(commands(json))

            let data = try Data(contentsOf: fixture.state.appendingPathComponent("\(Self.run).state.json"))
            let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(record["state"] as? String == "unknown")
            // Clearing the pid is what keeps the liveness sweep from retiring
            // the record moments after this restore protected it.
            #expect(record["pid"] == nil)
            #expect(record["resumeAttemptedAt"] as? String == "2026-09-15T12:00:00Z")
            // Fields the patch did not name are untouched.
            #expect(record["revision"] as? Int == 4)
            #expect(record["updatedAt"] as? String == "2026-09-14T12:00:00Z")
        }
    }

    @Test("a busy file stops the chain whatever it asked for")
    func busyLock_stopsTheChain() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            try writeHint(fixture, runID: Self.run)

            // Somebody is mid-write, so the snapshot this was decided from is
            // already stale even though the command said to continue.
            let lockPath = fixture.sessions.appendingPathComponent("\(Self.pane).json.flock").path
            let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
            #expect(descriptor >= 0)
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            defer { close(descriptor) }

            let outcomes = try fixture.executor.run(commands(retirementChain(hintRunID: Self.run)))
            #expect(outcomes.count == 1)
            #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))
        }
    }

    @Test("pruning bounds the retired directory without touching live records")
    func pruneRetired_boundsTheDirectory() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            let retired = fixture.state.appendingPathComponent("retired", isDirectory: true)
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            // Recent stamps, so the count cap is what decides rather than the
            // age cap; the age rule has its own reach in the rules.
            let stamp = Int(Date().timeIntervalSince1970)
            for index in 0..<5 {
                let name = "\(UUID().uuidString).\(stamp - index).\(UUID().uuidString).state.json"
                try Data("{}".utf8).write(to: retired.appendingPathComponent(name))
            }
            // A name that does not parse says nothing about when it was
            // retired, so it is left where it is.
            try Data("{}".utf8).write(to: retired.appendingPathComponent("stray.json"))

            let json = """
            [{
              "op": {"op": "pruneRetired", "max": 2, "lifetimeSecs": 604800},
              "target": {"target": "retiredRecords", "provider": "claude"},
              "expect": {"expect": "none"},
              "onMismatch": "continue"
            }]
            """
            try fixture.executor.run(commands(json))

            let remaining = try FileManager.default.contentsOfDirectory(atPath: retired.path)
            #expect(remaining.filter { $0 != "stray.json" }.count == 2)
            #expect(remaining.contains("stray.json"))
            #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))
        }
    }

    @Test("a pane store keeps the panes that are still open")
    func cleanupPaneStore_keepsLivePanes() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            let closed = UUID().uuidString
            try writeHint(fixture, runID: Self.run)
            try Data("{}".utf8).write(to: fixture.sessions.appendingPathComponent("\(closed).json"))

            let json = """
            [{
              "op": {"op": "cleanupPaneStore", "keep": ["\(Self.pane)"], "max": 200},
              "target": {"target": "paneStore", "provider": "claude", "store": "sessions"},
              "expect": {"expect": "none"},
              "onMismatch": "continue"
            }]
            """
            try fixture.executor.run(commands(json))

            #expect(FileManager.default.fileExists(atPath: fixture.sessions.appendingPathComponent("\(Self.pane).json").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.sessions.appendingPathComponent("\(closed).json").path))
        }
    }

    /// The hint of a run Limpid hosts in tmux is kept in a subdirectory an
    /// older build does not list, and it is the same store: one sweep, one
    /// keep set. Without this the hosted hints would be the only files
    /// nothing ever removed.
    @Test("a pane store sweeps the hosted hints with the plain ones")
    func cleanupPaneStore_reachesTheHostedHints() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            let hosted = fixture.sessions.appendingPathComponent("tmux-hosted", isDirectory: true)
            try FileManager.default.createDirectory(at: hosted, withIntermediateDirectories: true)
            let closed = UUID().uuidString
            for pane in [Self.pane, closed] {
                try Data("{}".utf8).write(to: hosted.appendingPathComponent("\(pane).json"))
            }

            let json = """
            [{
              "op": {"op": "cleanupPaneStore", "keep": ["\(Self.pane)"], "max": 200},
              "target": {"target": "paneStore", "provider": "claude", "store": "sessions"},
              "expect": {"expect": "none"},
              "onMismatch": "continue"
            }]
            """
            try fixture.executor.run(commands(json))

            #expect(FileManager.default.fileExists(atPath: hosted.appendingPathComponent("\(Self.pane).json").path))
            #expect(!FileManager.default.fileExists(atPath: hosted.appendingPathComponent("\(closed).json").path))
        }
    }

    /// A run that has both — a conversation that ran natively before it was
    /// reopened in tmux — is addressed at the hosted hint, which it wrote
    /// last.
    @Test("a hint command addresses the hosted file when there is one")
    func sessionHint_prefersTheHostedFile() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            let hosted = fixture.sessions.appendingPathComponent("tmux-hosted", isDirectory: true)
            try FileManager.default.createDirectory(at: hosted, withIntermediateDirectories: true)
            try writeHint(fixture, runID: Self.run)
            let hostedFile = hosted.appendingPathComponent("\(Self.pane).json")
            try JSONSerialization
                .data(withJSONObject: ["schemaVersion": 1, "paneId": Self.pane, "runId": Self.run, "sessionId": "S"])
                .write(to: hostedFile)

            let json = """
            [{
              "op": {"op": "delete"},
              "target": {"target": "sessionHint", "provider": "claude", "pane": "\(Self.pane)"},
              "expect": {"expect": "none"},
              "onMismatch": "continue"
            }]
            """
            try fixture.executor.run(commands(json))

            #expect(!FileManager.default.fileExists(atPath: hostedFile.path))
            #expect(FileManager.default.fileExists(atPath: fixture.sessions.appendingPathComponent("\(Self.pane).json").path))
        }
    }

    @Test("an operation this build does not know is skipped, not guessed at")
    func unknownOperation_isSkipped() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            try writeRecord(fixture)
            let json = """
            [{
              "op": {"op": "somethingNewerRulesEmit"},
              "target": {"target": "record", "provider": "claude", "storageId": "\(Self.run)"},
              "expect": {"expect": "none"},
              "onMismatch": "continue"
            }]
            """
            // A newer rule set must not be able to stall an older host, and
            // must not have its unknown command guessed at either.
            try fixture.executor.run(commands(json))
            #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("\(Self.run).state.json").path))
        }
    }

    @Test("consuming a worktree event leaves nothing behind in its directory")
    func worktreeEvent_deleteLeavesNoLockFile() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            let events = fixture.state.appendingPathComponent("worktree-events", isDirectory: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            let name = "1757000000-4242-abcdef-create.json"
            try Data("{}".utf8).write(to: events.appendingPathComponent(name))
            let json = """
            [{
              "op": {"op": "delete"},
              "target": {"target": "worktreeEvent", "provider": "claude", "fileName": "\(name)"},
              "expect": {"expect": "none"},
              "onMismatch": "abort"
            }]
            """

            try fixture.executor.run(commands(json))

            // A lock file here would be read as an event on the next pass, and
            // consuming it would leave another one: the writer renames its
            // temporary into place instead of locking, so there is no holder
            // to wait for.
            let left = try FileManager.default.contentsOfDirectory(atPath: events.path)
            #expect(left.isEmpty, "left behind: \(left)")
        }
    }

    @Test("a target that is not a plain name inside its directory is refused")
    func targetOutsideItsDirectory_isRefused() throws {
        try withTempDir { root in
            let fixture = try fixture(in: root)
            let neighbor = root.appendingPathComponent("neighbor.state.json")
            try Data(#"{"schemaVersion":3}"#.utf8).write(to: neighbor)
            let json = """
            [{
              "op": {"op": "delete"},
              "target": {"target": "record", "provider": "claude", "storageId": "../neighbor"},
              "expect": {"expect": "none"},
              "onMismatch": "abort"
            },
            {
              "op": {"op": "delete"},
              "target": {"target": "worktreeEvent", "provider": "claude", "fileName": "../../neighbor.state.json"},
              "expect": {"expect": "none"},
              "onMismatch": "abort"
            }]
            """

            try fixture.executor.run(commands(json))

            // Nothing the rules can name today reaches outside its directory,
            // because every name came from a directory entry. The refusal is
            // what keeps that true if a rule ever names something else.
            #expect(FileManager.default.fileExists(atPath: neighbor.path))
        }
    }
}
