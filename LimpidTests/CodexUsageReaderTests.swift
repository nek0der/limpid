// CodexUsageReaderTests.swift
// Limpid — asking Codex's app server for its usage: the exchange, and reading the answer through the Rust bridge.

import Foundation
import Testing
@testable import Limpid

@Suite("Codex usage reader")
struct CodexUsageReaderTests {
    /// A stand-in for `codex app-server`: it reads the handshake and the
    /// request, answers the request, and leaves when its input closes, as the
    /// real server does.
    private static let fakeServer = #"""
    #!/bin/sh
    read -r initialize
    read -r initialized
    read -r request
    echo '{"method":"configWarning","params":{}}'
    echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}'
    while read -r line; do :; done
    """#

    @Test("asks for the rate limits after the handshake, one message per line")
    func requestLines_holdTheHandshakeAndTheRequest() {
        let lines = (String(bytes: CodexUsageReader.requestLines, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(lines.count == 3)
        #expect(lines.map { $0?["method"] as? String } == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test("knows the answer to the usage request from the rest of the stream")
    func isAnswer_matchesOnlyTheUsageRequest() {
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"result":{}}"#.utf8)))
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"error":{"code":1}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":1,"result":{}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"method":"configWarning"}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data("not json".utf8)))
    }

    @Test("keeps the server's input open until the answer comes, then ends it")
    func exchange_returnsTheAnswerLine() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable(Self.fakeServer, at: server)
            let answer = await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
            let line = try #require(answer)
            #expect(CodexUsageReader.isAnswer(line))
        }
    }

    @Test("gives up on a server that never answers")
    func exchange_timesOut() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nwhile read -r line; do :; done\n", at: server)
            let start = ContinuousClock.now
            let answer = await CodexUsageReader.exchange(
                executable: server.path,
                path: ShimHarness.systemPath,
                timeout: .milliseconds(500)
            )
            #expect(answer == nil)
            // The half-second timeout, against the 15-second default a run
            // that ignored it would wait, or no end at all. The bound leaves
            // room for a busy CI runner.
            #expect(ContinuousClock.now - start < .seconds(10), "the timeout given, not the default")
        }
    }

    /// A server that ends before it reads anything: the requests meet a
    /// closed pipe, which must fail the write rather than end the app.
    @Test("comes back empty from a server that ends at once")
    func exchange_serverThatEndsAtOnce_returnsNothing() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nexit 1\n", at: server)
            for _ in 0..<5 {
                let answer = await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
                #expect(answer == nil)
            }
        }
    }

    /// The panel closing cancels the read at any moment, before the server
    /// starts as well as while it runs.
    @Test("ends cleanly whenever it is canceled")
    func exchange_canceled_endsCleanly() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nwhile read -r line; do :; done\n", at: server)
            for delay in [0, 1, 5, 20] {
                let read = Task {
                    await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
                }
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                read.cancel()
                #expect(await read.value == nil)
            }
        }
    }

    @Test("reads Codex's answer through its adapter, an error apart from no plan")
    func bridge_readsTheAnswer() throws {
        let answer = Data(#"""
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1793776116},
         "secondary":null,"planType":"prolite"}}}
        """#.utf8)
        guard case let .usage(usage) = try LimpidUsageBridge.planUsageAnswer(provider: .codex, answer: answer) else {
            Issue.record("expected the usage")
            return
        }
        #expect(usage.windows.map(\.kind) == [PlanUsageWindow.sevenDay])
        #expect(usage.resetCredits == nil)

        let noPlan = Data(#"{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}"#.utf8)
        #expect(try LimpidUsageBridge.planUsageAnswer(provider: .codex, answer: noPlan) == .noPlan)
        let error = Data(#"{"id":2,"error":{"code":-32600,"message":"failed"}}"#.utf8)
        #expect(try LimpidUsageBridge.planUsageAnswer(provider: .codex, answer: error) == .unreadable)
    }
}
