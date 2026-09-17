// TmuxChannelReader.swift
// Limpid — reads everything a leaf's pane channel delivers, for the suites that drive a real tmux.

import Darwin
import Foundation
import Testing
@testable import Limpid

/// What a surface would read from a leaf's channel, collected on a
/// duplicate of its descriptor for the whole test, with whether the stream
/// ever ended.
final class ChannelReader: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private var hasEnded = false
    private let source: any DispatchSourceRead

    init(channel: TmuxPaneChannel) throws {
        let fd = fcntl(channel.surfaceFd, F_DUPFD_CLOEXEC, 0)
        try #require(fd >= 0)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "test.channel.reader"))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                hasEnded = true
                source.cancel()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy on purpose: a chunk boundary can split a character, and the
        // markers compared against are ASCII.
        return String(bytes: collected, encoding: .utf8) ?? String(bytes: collected, encoding: .isoLatin1) ?? ""
    }

    var didEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEnded
    }

    func stop() {
        source.cancel()
    }
}
