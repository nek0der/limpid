// TmuxServerGenerationTests.swift
// Limpid — how a binding's recorded server is compared with the server now on its socket.

import Foundation
import Testing
@testable import Limpid

struct TmuxServerGenerationTests {
    private let recorded = TmuxServerGeneration.Recorded(pid: "4242", startedAt: "1789000000")

    /// Read from the one listing both questions about a socket are asked
    /// with (`TmuxServerSessions`). For a listing that was answered:
    /// nothing may connect.
    private func classify(_ result: TmuxCommandResult, sessionID: String) -> TmuxServerGeneration.Verdict {
        let sessions = TmuxServerSessions.classify(result) {
            Issue.record("an answered listing must not connect")
            return nil
        }
        return TmuxServerGeneration.verdict(for: sessions, recorded: recorded, sessionID: sessionID)
    }

    @Test("a listing from the recorded server matches, with or without the session", arguments: [
        ("4242\t1789000000\t$0\tone\n4242\t1789000000\t$3\ttwo\n", "$3", TmuxServerGeneration.Verdict.matches(hasSession: true)),
        ("4242\t1789000000\t$0\tone\n", "$3", .matches(hasSession: false)),
        ("4242\t1789000000\t$30\tone\n", "$3", .matches(hasSession: false))
    ])
    func classify_sameServer(output: String, sessionID: String, expected: TmuxServerGeneration.Verdict) {
        #expect(classify(.success(output), sessionID: sessionID) == expected)
    }

    @Test("a listing from another server is replaced, even when it names the session", arguments: [
        "4243\t1789000000\t$0\tone\n",
        "4242\t1789000001\t$0\tone\n",
        "1\t2\t$0\tone\n",
    ])
    func classify_otherServer(output: String) {
        #expect(classify(.success(output), sessionID: "$0") == .replaced)
    }

    @Test("a server with no sessions states no generation and is taken as replaced")
    func classify_emptyListing() {
        #expect(classify(.success(""), sessionID: "$0") == .replaced)
    }

    @Test("a listing that cannot be read is unreachable", arguments: [
        "4242 1789000000 $0 one\n",
        "4242\t1789000000\t$0\n",
        "4242\t1789000000\t$0\tone\textra\n",
    ])
    func classify_unreadableListing(output: String) {
        #expect(classify(.success(output), sessionID: "$0") == .unreachable)
    }

    @Test("a client without an answer is unreachable without connecting", arguments: [
        TmuxCommandResult.timedOut, .launchFailed, .cancelled, .invalidOutput, .outputLimit,
    ])
    func classify_noAnswer(_ result: TmuxCommandResult) {
        let sessions = TmuxServerSessions.classify(result) {
            Issue.record("a client that gave no answer must not connect")
            return ENOENT
        }
        #expect(TmuxServerGeneration.verdict(for: sessions, recorded: recorded, sessionID: "$0") == .unreachable)
    }

    @Test("a failed client means no server when the socket is missing or refuses, and unreachable otherwise", arguments: [
        (Int32?.some(ENOENT), TmuxServerGeneration.Verdict.serverGone),
        (Int32?.some(ECONNREFUSED), .serverGone),
        (Int32?.some(EACCES), .unreachable),
        (Int32?.none, .unreachable),
    ])
    func classify_failedClient(connectError: Int32?, expected: TmuxServerGeneration.Verdict) {
        let sessions = TmuxServerSessions.classify(.failed(1)) { connectError }
        #expect(TmuxServerGeneration.verdict(for: sessions, recorded: recorded, sessionID: "$0") == expected)
    }

    @Test("a binding records a generation only with both values present and non-empty", arguments: [
        (String?.none, String?.none, false),
        ("4242", nil, false),
        (nil, "1789000000", false),
        ("", "", false),
        ("4242", "", false),
        ("4242", "1789000000", true),
    ])
    func recorded_needsBothValues(pid: String?, startedAt: String?, isRecorded: Bool) {
        let binding = TmuxBinding(
            socketPath: "/nonexistent/sock",
            sessionID: "$0",
            sessionName: "t",
            serverPID: pid,
            serverStartedAt: startedAt
        )
        #expect((TmuxServerGeneration.recorded(in: binding) != nil) == isRecorded)
    }

    @Test("a binding without a generation is unrecorded without running tmux")
    func verdict_unrecordedBinding_runsNothing() {
        let binding = TmuxBinding(socketPath: "/nonexistent/sock", sessionID: "$0", sessionName: "t")
        // An executable that cannot be launched would answer unreachable.
        #expect(TmuxServerGeneration.verdict(tmuxPath: "/nonexistent/tmux", binding: binding) == .unrecorded)
    }
}

@Suite(
    "tmux server generation",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
struct TmuxServerGenerationSmokeTests {
    private func binding(_ server: TmuxServerFixture, sessionID: String, generation: TmuxServerGeneration.Recorded) -> TmuxBinding {
        TmuxBinding(
            socketPath: server.socketPath,
            sessionID: sessionID,
            sessionName: "t",
            serverPID: generation.pid,
            serverStartedAt: generation.startedAt
        )
    }

    @Test("the recorded server matches, and says whether it still has the session")
    func check_sameServer() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let sessionID = try server.format("#{session_id}")

        let present = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: sessionID, generation: generation)
        )
        let missing = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: "$99", generation: generation)
        )

        #expect(present == .matches(hasSession: true))
        #expect(missing == .matches(hasSession: false))
    }

    /// The new server has session `t` under the same id, which is exactly
    /// what a check by session id alone would take for the old one.
    @Test("a server restarted on the same socket is replaced, though it has a session under the same id")
    func check_restartedServer() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let sessionID = try server.format("#{session_id}")

        try await server.restartServer()

        try #require(server.format("#{session_id}") == sessionID)
        #expect(try server.generation() != generation)
        let verdict = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: sessionID, generation: generation)
        )
        #expect(verdict == .replaced)
    }

    @Test("a server whose socket file was removed is gone")
    func check_missingSocket() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let sessionID = try server.format("#{session_id}")
        let pid = try #require(Int32(generation.pid))
        // `tearDown` can no longer reach the server once its socket is gone.
        defer { kill(pid, SIGTERM) }

        try FileManager.default.removeItem(atPath: server.socketPath)

        let verdict = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: sessionID, generation: generation)
        )
        #expect(verdict == .serverGone)
    }

    @Test("a socket nobody listens on is gone")
    func check_killedServer() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let sessionID = try server.format("#{session_id}")

        try await server.killServer()

        #expect(FileManager.default.fileExists(atPath: server.socketPath))
        let verdict = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: sessionID, generation: generation)
        )
        #expect(verdict == .serverGone)
    }

    @Test("a server that does not answer is unreachable")
    func check_hungServer() async throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let generation = try server.generation()
        let sessionID = try server.format("#{session_id}")
        let pid = try server.suspendServer()
        defer { server.resumeServer(pid) }

        let verdict = await TmuxServerGeneration.check(
            tmuxPath: server.executable,
            binding: binding(server, sessionID: sessionID, generation: generation)
        )
        #expect(verdict == .unreachable)
    }
}
