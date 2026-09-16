// TmuxOutputGateIntegrationTests.swift
// Limpid — measures against a real tmux server how per-pane output gating and per-window sizing affect other windows and clients.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// A throwaway tmux server on a socket under a temp directory, so the
/// user's own server is never touched and two tests cannot share state.
/// Duplicated from `TmuxServerConnectionTests` on purpose: the fixture is
/// private there, and these cases need a two-window session instead of the
/// single-window one that file builds.
private struct TmuxServerFixture {
    let executable: String
    let directory: URL
    let socketPath: String

    /// Launches a session with two windows, since every question here is
    /// about what one window's gating or sizing does to the other.
    static func launchTwoWindows() throws -> TmuxServerFixture {
        let executable = try #require(TmuxClientProbe.locateTmux())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-tmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = TmuxServerFixture(
            executable: executable,
            directory: directory,
            socketPath: directory.appendingPathComponent("sock").path
        )
        _ = fixture.run(["new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sh", "-c", "PS1='$ ' exec sh"])
        _ = fixture.run(["set-option", "-g", "status", "off"])
        _ = fixture.run(["new-window", "-t", "t", "sh", "-c", "PS1='$ ' exec sh"])
        return fixture
    }

    @discardableResult
    func run(_ arguments: [String]) -> String? {
        if case let .success(output) = TmuxCommand().run(executable: executable, arguments: ["-S", socketPath] + arguments) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The window ids in index order; the session's first window and the one
    /// `launchTwoWindows` added.
    func windowIDs() throws -> [String] {
        let listed = try #require(run(["list-windows", "-t", "t", "-F", "#{window_id}"]))
        return listed.split(separator: "\n").map(String.init)
    }

    func paneID(inWindow window: String) throws -> String {
        try #require(run(["list-panes", "-t", window, "-F", "#{pane_id}"]))
    }

    /// The size tmux currently holds for `window`, read from outside the
    /// control clients so the answer is the server's view, not a client's.
    func windowSize(_ window: String) -> String? {
        run(["display-message", "-p", "-t", window, "#{window_width}x#{window_height}"])
    }

    func tearDown() {
        _ = run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Read from `fd` until `marker` shows up or `timeout` passes. Runs off the
/// main actor so a blocked read never stalls the connection's deliveries.
private func readUntil(fd: Int32, contains marker: String, timeout: Duration) async -> Data {
    await Task.detached {
        var collected = Data()
        let needle = Data(marker.utf8)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 65536)
        while clock.now < deadline, collected.range(of: needle) == nil {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
            } else {
                break
            }
        }
        return collected
    }.value
}

private func contains(_ data: Data, _ marker: String) -> Bool {
    data.range(of: Data(marker.utf8)) != nil
}

@Suite("tmux output gate and window sizing", .serialized, .disabled(if: TmuxClientProbe.locateTmux() == nil, "tmux is not installed"))
@MainActor
struct TmuxOutputGateIntegrationTests {
    /// Send one command and wait for its reply block, so the next assertion
    /// measures a server that has already applied it.
    private func sendAndWait(
        _ connection: TmuxServerConnection,
        _ command: String,
        timeout: Duration = .seconds(3)
    ) async -> (lines: [String], isError: Bool)? {
        var reply: (lines: [String], isError: Bool)?
        connection.send(command) { lines, isError in reply = (lines, isError) }
        _ = await waitUntil(timeout) { reply != nil }
        return reply
    }

    private func attachedConnection(_ server: TmuxServerFixture) async throws -> TmuxServerConnection {
        let sessionID = try #require(server.run(["display-message", "-p", "-t", "t", "#{session_id}"]))
        let connection = TmuxServerConnection(
            executable: server.executable,
            target: .init(socketPath: server.socketPath, sessionID: sessionID)
        )
        try connection.start()
        #expect(await waitUntil { connection.state == .attached })
        return connection
    }

    @Test("refresh-client -A off silences one pane's output and :on brings it back, while the other pane keeps flowing")
    func outputGate_silencesOnlyItsOwnPane() async throws {
        let server = try TmuxServerFixture.launchTwoWindows()
        defer { server.tearDown() }
        let windows = try server.windowIDs()
        try #require(windows.count == 2)
        let openPane = try server.paneID(inWindow: windows[0])
        let gatedPane = try server.paneID(inWindow: windows[1])

        let connection = try await attachedConnection(server)
        defer { connection.stop() }
        let openSink = try connection.attachPane(openPane)
        let gatedSink = try connection.attachPane(gatedPane)

        let gateOff = await sendAndWait(connection, "refresh-client -A '\(gatedPane):off'")
        #expect(gateOff?.isError == false)

        server.run(["send-keys", "-t", gatedPane, "echo GATED-1", "Enter"])
        server.run(["send-keys", "-t", openPane, "echo OPEN-1", "Enter"])

        // Nothing should reach the gated sink at all: not the echo of the
        // keys we typed, not the command's output.
        let silenced = await readUntil(fd: gatedSink.surfaceFd, contains: "GATED-1", timeout: .seconds(2))
        #expect(!contains(silenced, "GATED-1"))
        #expect(silenced.isEmpty)

        let open = await readUntil(fd: openSink.surfaceFd, contains: "OPEN-1", timeout: .seconds(5))
        #expect(contains(open, "OPEN-1"))

        let gateOn = await sendAndWait(connection, "refresh-client -A '\(gatedPane):on'")
        #expect(gateOn?.isError == false)
        server.run(["send-keys", "-t", gatedPane, "echo GATED-2", "Enter"])

        // Turning the gate back on makes tmux redraw the pane, so the
        // screen the mirror missed — GATED-1 included — arrives together
        // with the new output. We only require the new output.
        let resumed = await readUntil(fd: gatedSink.surfaceFd, contains: "GATED-2", timeout: .seconds(5))
        #expect(contains(resumed, "GATED-2"))

        // The open pane is unaffected by either side of the gate.
        server.run(["send-keys", "-t", openPane, "echo OPEN-2", "Enter"])
        let openAgain = await readUntil(fd: openSink.surfaceFd, contains: "OPEN-2", timeout: .seconds(5))
        #expect(contains(openAgain, "OPEN-2"))
    }

    @Test("a per-window refresh-client -C resizes only the window it names")
    func windowScopedSize_leavesOtherWindowsAlone() async throws {
        let server = try TmuxServerFixture.launchTwoWindows()
        defer { server.tearDown() }
        let windows = try server.windowIDs()
        try #require(windows.count == 2)
        #expect(server.windowSize(windows[0]) == "80x24")
        #expect(server.windowSize(windows[1]) == "80x24")

        let connection = try await attachedConnection(server)
        defer { connection.stop() }

        let first = await sendAndWait(connection, "refresh-client -C '\(windows[0]):60x20'")
        #expect(first?.isError == false)
        #expect(await waitUntil { server.windowSize(windows[0]) == "60x20" })
        #expect(server.windowSize(windows[1]) == "80x24")

        let second = await sendAndWait(connection, "refresh-client -C '\(windows[1]):100x30'")
        #expect(second?.isError == false)
        #expect(await waitUntil { server.windowSize(windows[1]) == "100x30" })
        #expect(server.windowSize(windows[0]) == "60x20")
    }

    @Test("with a second control client attached, each client's window-scoped size stands on its own")
    func windowScopedSize_doesNotDisturbAnotherClientsWindow() async throws {
        let server = try TmuxServerFixture.launchTwoWindows()
        defer { server.tearDown() }
        let windows = try server.windowIDs()
        try #require(windows.count == 2)
        let otherPane = try server.paneID(inWindow: windows[1])

        let clientA = try await attachedConnection(server)
        defer { clientA.stop() }
        let clientB = try await attachedConnection(server)
        defer { clientB.stop() }

        // B speaks for the window Limpid is not mirroring.
        let declared = await sendAndWait(clientB, "refresh-client -C '\(windows[1]):70x22'")
        #expect(declared?.isError == false)
        #expect(await waitUntil { server.windowSize(windows[1]) == "70x22" })

        // A sizes its own window; B's window keeps the size B asked for.
        let ours = await sendAndWait(clientA, "refresh-client -C '\(windows[0]):60x20'")
        #expect(ours?.isError == false)
        #expect(await waitUntil { server.windowSize(windows[0]) == "60x20" })
        #expect(server.windowSize(windows[1]) == "70x22")

        // Gating a pane A does not show is a client-local subscription and
        // must not resize the window B is sizing.
        let gate = await sendAndWait(clientA, "refresh-client -A '\(otherPane):off'")
        #expect(gate?.isError == false)
        #expect(server.windowSize(windows[1]) == "70x22")
        #expect(server.windowSize(windows[0]) == "60x20")
    }
}
