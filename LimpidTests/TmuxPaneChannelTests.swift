// TmuxPaneChannelTests.swift
// Limpid — a pane's channel outlives the sinks that feed it and closes only once nothing holds it.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// A socket's identity, so a check that a descriptor was closed is not
/// fooled by another test opening something under the same number.
private struct SocketIdentity: Equatable {
    let inode: ino_t

    init?(_ fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        inode = info.st_ino
    }
}

private func isClosed(_ fd: Int32, wasOpenAs identity: SocketIdentity?) -> Bool {
    SocketIdentity(fd) != identity
}

/// A duplicate of the surface end, the way libghostty's mirror backend
/// keeps one, made non-blocking so a check for EOF does not wait.
private func surfaceDuplicate(of channel: TmuxPaneChannel) throws -> Int32 {
    let fd = fcntl(channel.surfaceFd, F_DUPFD_CLOEXEC, 0)
    try #require(fd >= 0)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    return fd
}

private enum ReadResult: Equatable {
    case bytes(Data)
    case wouldBlock
    case endOfStream
}

/// One read of whatever `fd` holds after waiting up to `timeout` for it.
private func readOnce(_ fd: Int32, timeout: Duration = .milliseconds(200)) -> ReadResult {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32(timeout / .milliseconds(1))
    guard poll(&descriptor, 1, milliseconds) > 0 else { return .wouldBlock }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if n > 0 {
        return .bytes(Data(buffer[0..<n]))
    }
    return n == 0 ? .endOfStream : .wouldBlock
}

/// Waits off the main actor, so the channel's cancel handler and main-actor
/// deliveries are free to run meanwhile.
private func eventually(_ timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class OutputLog {
    var received = Data()
}

@Suite("tmux pane channel")
struct TmuxPaneChannelTests {
    private let queue = DispatchQueue(label: "dev.limpid.tests.channel")

    private func write(_ text: String, to sink: TmuxPaneSink) {
        queue.sync { sink.write(Data(text.utf8)) }
    }

    /// Detach the way a connection does, and wait until it has taken effect.
    private func detach(_ sink: TmuxPaneSink) {
        sink.close()
        queue.sync {}
    }

    @Test("a sink attached after another was detached writes to the same surface, in order")
    func sinkSwap_feedsTheSameSurfaceInOrder() async throws {
        let channel = try TmuxPaneChannel { _ in }
        let surface = try surfaceDuplicate(of: channel)
        defer { Darwin.close(surface) }

        let first = TmuxPaneSink(channel: channel, queue: queue, onOverflow: {})
        write("A1|", to: first)
        write("A2|", to: first)
        detach(first)
        write("LOST|", to: first)

        let second = TmuxPaneSink(channel: channel, queue: queue, onOverflow: {})
        defer { second.close() }
        write("B1", to: second)

        let seen = await readUntil(fd: surface, contains: "B1", timeout: .seconds(2))
        #expect(seen == Data("A1|A2|B1".utf8))
    }

    @Test("detaching a sink leaves the surface's stream open")
    func detach_doesNotEndTheStream() throws {
        let channel = try TmuxPaneChannel { _ in }
        let surface = try surfaceDuplicate(of: channel)
        defer { Darwin.close(surface) }
        let sink = TmuxPaneSink(channel: channel, queue: queue, onOverflow: {})
        write("X", to: sink)
        #expect(readOnce(surface) == .bytes(Data("X".utf8)))

        detach(sink)

        #expect(readOnce(surface) == .wouldBlock)
    }

    @Test("releasing the channel ends the stream a surface reads, and closes both ends")
    func release_endsTheStreamAndClosesDescriptors() async throws {
        var channel: TmuxPaneChannel? = try TmuxPaneChannel { _ in }
        let surface = try surfaceDuplicate(of: #require(channel))
        defer { Darwin.close(surface) }
        let surfaceFd = try #require(channel?.surfaceFd)
        let hostFd = try #require(channel?.hostFd)
        let surfaceIdentity = SocketIdentity(surfaceFd)
        let hostIdentity = SocketIdentity(hostFd)
        #expect(readOnce(surface) == .wouldBlock)

        channel = nil

        #expect(await eventually { readOnce(surface, timeout: .zero) == .endOfStream })
        #expect(await eventually {
            isClosed(surfaceFd, wasOpenAs: surfaceIdentity) && isClosed(hostFd, wasOpenAs: hostIdentity)
        })
    }

    @Test("a sink keeps the channel open after every other owner let go, until it is detached and gone")
    func sink_holdsTheChannelUntilItIsGone() async throws {
        var channel: TmuxPaneChannel? = try TmuxPaneChannel { _ in }
        let surface = try surfaceDuplicate(of: #require(channel))
        defer { Darwin.close(surface) }
        let hostFd = try #require(channel?.hostFd)
        let hostIdentity = SocketIdentity(hostFd)
        var sink: TmuxPaneSink? = try TmuxPaneSink(channel: #require(channel), queue: queue, onOverflow: {})
        // A full socket arms the sink's write source, which watches the
        // host end until it is cancelled.
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        for _ in 0..<8 {
            queue.sync { sink?.write(chunk) }
        }

        channel = nil
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!isClosed(hostFd, wasOpenAs: hostIdentity))

        sink?.close()
        sink = nil
        #expect(await eventually {
            // Drain what the socket took before the end shows.
            while case .bytes = readOnce(surface, timeout: .zero) {}
            return readOnce(surface, timeout: .zero) == .endOfStream
        })
    }

    @Test("what the surface writes arrives on the main actor, in order")
    @MainActor
    func surfaceOutput_isDeliveredOnMain() async throws {
        let log = OutputLog()
        let channel = try TmuxPaneChannel { data in
            MainActor.preconditionIsolated()
            log.received.append(data)
        }
        for text in ["one|", "two|", "three"] {
            _ = Data(text.utf8).withUnsafeBytes { Darwin.write(channel.surfaceFd, $0.baseAddress, $0.count) }
        }

        #expect(await waitUntil { log.received == Data("one|two|three".utf8) })
    }

    @Test("one read of the host end tells bytes, nothing yet, a failure, and the end apart")
    func readSurfaceOutput_classifiesEachOutcome() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { Darwin.close(fds[0]) }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)

        #expect(TmuxPaneChannel.readSurfaceOutput(from: fds[0]) == .wouldBlock)
        _ = Data("hi".utf8).withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        #expect(TmuxPaneChannel.readSurfaceOutput(from: fds[0]) == .delivered(Data("hi".utf8)))
        Darwin.close(fds[1])
        #expect(TmuxPaneChannel.readSurfaceOutput(from: fds[0]) == .ended)
        #expect(TmuxPaneChannel.readSurfaceOutput(from: -1) == .failed(errno: EBADF))
    }

    /// `shutdown` makes every later read of the host end end at once, the
    /// way a failing descriptor keeps failing. Reading stops; the
    /// descriptors stay the channel's.
    @Test("after its reads end, the channel still carries output to the surface and closes only when released")
    func readsEnded_channelStaysWritableUntilReleased() async throws {
        var channel: TmuxPaneChannel? = try TmuxPaneChannel { _ in }
        let surface = try surfaceDuplicate(of: #require(channel))
        defer { Darwin.close(surface) }
        let hostFd = try #require(channel?.hostFd)
        let hostIdentity = SocketIdentity(hostFd)
        try #require(shutdown(hostFd, SHUT_RD) == 0)
        try? await Task.sleep(for: .milliseconds(100))

        _ = Data("LIVE".utf8).withUnsafeBytes { Darwin.write(hostFd, $0.baseAddress, $0.count) }
        #expect(readOnce(surface) == .bytes(Data("LIVE".utf8)))
        #expect(!isClosed(hostFd, wasOpenAs: hostIdentity))

        channel = nil
        #expect(await eventually { isClosed(hostFd, wasOpenAs: hostIdentity) })
    }

    /// A shell an ordinary pane forks must not inherit either end.
    @Test("both ends are close-on-exec, and the host end does not block")
    func descriptors_areCloseOnExec() throws {
        let channel = try TmuxPaneChannel { _ in }

        #expect(fcntl(channel.surfaceFd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(channel.hostFd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(channel.hostFd, F_GETFL) & O_NONBLOCK != 0)
    }
}

@MainActor
@Suite("tmux pane channels in the store")
struct TmuxPaneChannelStoreTests {
    private static let ref = TmuxPaneRef(
        binding: TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work"),
        windowID: "@2",
        paneID: "%7"
    )

    @Test("a leaf keeps one channel across calls, and a local leaf's channel is released")
    func channel_isStablePerLeaf() throws {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let first = try #require(store.channel(paneID: leafID))
        #expect(store.channel(paneID: leafID) === first)

        // Still `.local`: nothing reads a channel there.
        store.reconcile(tabs: session.tabs)
        #expect(store.channel(paneID: leafID) !== first)

        session.update(tab.id) { $0.paneSources[leafID] = .tmux(Self.ref) }
        let mirrored = try #require(store.channel(paneID: leafID))
        store.reconcile(tabs: session.tabs)
        #expect(store.channel(paneID: leafID) === mirrored)
        session.update(tab.id) { $0.paneSources[leafID] = .unavailable }
        store.reconcile(tabs: session.tabs)
        #expect(store.channel(paneID: leafID) === mirrored)
    }

    @Test("a channel the store released stays open while a surface still holds it")
    func reconcile_releasesButAHolderKeepsItOpen() async throws {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.paneSources[leafID] = .tmux(Self.ref) }
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        // What `SurfaceView.mirrorChannel` holds.
        var held = store.channel(paneID: leafID)
        let surface = try surfaceDuplicate(of: #require(held))
        defer { Darwin.close(surface) }
        let hostFd = try #require(held?.hostFd)

        store.reconcile(tabs: [])
        #expect(store.channel(paneID: leafID) !== held)
        store.reconcile(tabs: [])
        try? await Task.sleep(for: .milliseconds(100))

        _ = Data("STILL".utf8).withUnsafeBytes { Darwin.write(hostFd, $0.baseAddress, $0.count) }
        #expect(readOnce(surface) == .bytes(Data("STILL".utf8)))

        held = nil
        #expect(await eventually { readOnce(surface, timeout: .zero) == .endOfStream })
    }

    /// `reconcile` returns at once for a store that holds nothing; each of
    /// these holds only one kind of state, which must still be released.
    @Test("a store holding only a tab's connection state forgets it once the tab is gone")
    func reconcile_onlyTabConnection_isReleased() {
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        let tabID = UUID()
        store.setTabConnection(.unreachable, tabID: tabID)

        store.reconcile(tabs: [])

        #expect(store.tabConnections.isEmpty)
    }

    @Test("a store holding only a pane area's report forgets it once the tab is gone")
    func reconcile_onlyAreaReport_isReleased() {
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        store.areaSizeChanged(CGSize(width: 640, height: 400), tabID: UUID())

        store.reconcile(tabs: [])

        #expect(store.surfaceReports.isEmpty)
    }

    @Test("a store that holds nothing stays empty through reconcile of mirror and ordinary tabs")
    func reconcile_emptyStore_staysEmpty() {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.paneSources[leafID] = .tmux(Self.ref) }
        let store = TmuxConnectionStore(tmuxExecutable: nil)

        store.reconcile(tabs: session.tabs)

        #expect(store.tabConnections.isEmpty)
        #expect(store.mirrors.isEmpty)
        #expect(store.connections.isEmpty)
        #expect(store.surfaceReports.isEmpty)
        // A restored tab's leaf still gets its channel when its surface
        // mounts, and keeps it through the next reconcile.
        let channel = store.channel(paneID: leafID)
        store.reconcile(tabs: session.tabs)
        #expect(channel != nil)
        #expect(store.channel(paneID: leafID) === channel)
        store.reconcile(tabs: [])
    }

    @Test("a surface writing with no mirror behind its leaf is ignored")
    func surfaceOutput_withoutMirror_isDropped() async throws {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.paneSources[leafID] = .unavailable }
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let channel = try #require(store.channel(paneID: leafID))

        _ = Data("\u{1B}[I".utf8).withUnsafeBytes { Darwin.write(channel.surfaceFd, $0.baseAddress, $0.count) }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(store.mirror(for: tab.id) == nil)
        #expect(store.connections.isEmpty)
    }
}
