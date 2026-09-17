// TmuxSessionProbeTests.swift
// Limpid — how the answer to "does the session still exist" is read from a tmux client's result.

import Darwin
import Foundation
import Testing
@testable import Limpid

struct TmuxSessionProbeTests {
    @Test("a listing that names the session means it exists; one that does not, even an empty one, means it is gone")
    func classify_successfulListing() {
        let noConnect: () -> Int32? = {
            Issue.record("an answered listing must not connect")
            return nil
        }
        #expect(TmuxSessionProbe.classify(.success("$1\n$0\n"), sessionID: "$0", connectError: noConnect) == .exists)
        #expect(TmuxSessionProbe.classify(.success("$10\n$2\n"), sessionID: "$1", connectError: noConnect) == .gone)
        #expect(TmuxSessionProbe.classify(.success(""), sessionID: "$0", connectError: noConnect) == .gone)
    }

    @Test("a failed client means the session is gone only when no server is there: no socket, or nobody listening")
    func classify_failedClient() {
        #expect(TmuxSessionProbe.classify(.failed(1), sessionID: "$0") { ECONNREFUSED } == .gone)
        #expect(TmuxSessionProbe.classify(.failed(1), sessionID: "$0") { ENOENT } == .gone)
        #expect(TmuxSessionProbe.classify(.failed(1), sessionID: "$0") { EACCES } == .unknown)
        #expect(TmuxSessionProbe.classify(.failed(1), sessionID: "$0") { ETIMEDOUT } == .unknown)
        #expect(TmuxSessionProbe.classify(.failed(1), sessionID: "$0") { nil } == .unknown)
    }

    @Test("only a failed client is asked whether a server is there, and only a missing or refusing socket says none is")
    func isServerAbsent_readsOnlyFailedClients() {
        #expect(TmuxSessionProbe.isServerAbsent(after: .failed(1)) { ENOENT })
        #expect(TmuxSessionProbe.isServerAbsent(after: .failed(1)) { ECONNREFUSED })
        #expect(!TmuxSessionProbe.isServerAbsent(after: .failed(1)) { EACCES })
        #expect(!TmuxSessionProbe.isServerAbsent(after: .failed(1)) { nil })
        for result in [TmuxCommandResult.success(""), .timedOut, .launchFailed, .cancelled, .invalidOutput, .outputLimit] {
            #expect(!TmuxSessionProbe.isServerAbsent(after: result) {
                Issue.record("\(result) must not connect")
                return ENOENT
            })
        }
    }

    @Test("no answer at all leaves the session unknown without connecting", arguments: [
        TmuxCommandResult.timedOut, .launchFailed, .cancelled, .invalidOutput, .outputLimit,
    ])
    func classify_noAnswer(_ result: TmuxCommandResult) {
        let answer = TmuxSessionProbe.classify(result, sessionID: "$0") {
            Issue.record("a client that gave no answer must not connect")
            return ECONNREFUSED
        }
        #expect(answer == .unknown)
    }

    @Test("connecting reports a missing socket, a socket nobody listens on, and one that accepts")
    func connectError_distinguishesListeners() throws {
        // Short, like the tmux fixture: `sun_path` holds 104 bytes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path

        #expect(TmuxSessionProbe.connectError(socketPath: path) == ENOENT)
        #expect(TmuxSessionProbe.connectError(socketPath: String(repeating: "x", count: 200)) == ENAMETOOLONG)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        #expect(TmuxSessionProbe.connectError(socketPath: path) == ECONNREFUSED)
        try #require(listen(fd, 1) == 0)
        #expect(TmuxSessionProbe.connectError(socketPath: path) == nil)
    }
}

@Suite(
    "tmux session probe",
    .tags(.smoke, .slow),
    .serialized,
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
struct TmuxSessionProbeSmokeTests {
    @Test("a running server answers for its sessions, and a killed one is gone")
    func presence_followsTheServer() throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")
        let probe = { (id: String) in
            TmuxSessionProbe.presence(tmuxPath: server.executable, socketPath: server.socketPath, sessionID: id)
        }

        #expect(probe(sessionID) == .exists)
        #expect(probe("$99") == .gone)
        server.run(["kill-server"])
        // tmux leaves the socket file behind; a connect to it is refused.
        #expect(FileManager.default.fileExists(atPath: server.socketPath))
        #expect(probe(sessionID) == .gone)
    }

    /// Nobody can reach a server whose socket file was removed, so its
    /// sessions count as gone with it (stage 11, "decided in this stage").
    @Test("a server whose socket file was removed counts as gone")
    func presence_missingSocketOfRunningServer_isGone() throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")
        let pid = try #require(Int32(server.format("#{pid}")))
        defer { kill(pid, SIGTERM) }

        try FileManager.default.removeItem(atPath: server.socketPath)

        #expect(TmuxSessionProbe.presence(
            tmuxPath: server.executable,
            socketPath: server.socketPath,
            sessionID: sessionID
        ) == .gone)
    }

    @Test("a server that does not answer leaves the session unknown")
    func presence_hungServer_isUnknown() throws {
        let server = try TmuxServerFixture.launch()
        defer { server.tearDown() }
        let sessionID = try server.format("#{session_id}")
        let pid = try server.suspendServer()
        defer { server.resumeServer(pid) }

        #expect(TmuxSessionProbe.presence(
            tmuxPath: server.executable,
            socketPath: server.socketPath,
            sessionID: sessionID
        ) == .unknown)
    }
}
