// DescriptorReading.swift
// Limpid — reads a pane socket in tests until an expected marker arrives, off the main actor.

import Darwin
import Foundation

/// Everything readable on `fd` until `marker` arrives, the far end closes,
/// or `timeout` passes. Runs detached so a blocked read never stalls the
/// main-actor deliveries the caller is waiting on.
func readUntil(fd: Int32, contains marker: Data, timeout: Duration) async -> Data {
    await Task.detached {
        var collected = Data()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 65536)
        while clock.now < deadline, collected.range(of: marker) == nil {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            collected.append(contentsOf: buffer[0..<n])
        }
        return collected
    }.value
}

func readUntil(fd: Int32, contains marker: String, timeout: Duration) async -> Data {
    await readUntil(fd: fd, contains: Data(marker.utf8), timeout: timeout)
}
