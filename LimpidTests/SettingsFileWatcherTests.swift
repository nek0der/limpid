// SettingsFileWatcherTests.swift
// Limpid — lifecycle pin for the value-captured DispatchSource fd.
//
// The pre-`5d798bf` cancel handler captured `self` weakly and tried to
// close the *current* `dirFD`, so a re-armed watcher could double-
// close the previous fd. The post-fix shape captures `fd` by value, so
// the cancel handler closes the exact fd the source was registered
// with. We assert the contract holds.

import Darwin
import Foundation
import Testing
@testable import Limpid

@MainActor
struct SettingsFileWatcherTests {

    @Test("cancel closes the watched directory fd")
    func cancelClosesFD() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        let watcher = SettingsFileWatcher(store: store)
        watcher.start()
        let fd = watcher.currentDirFD
        try #require(fd >= 0)
        // Sanity: fd is open before the stop.
        #expect(fcntl(fd, F_GETFD) != -1)

        watcher.stop()
        // The cancel handler runs on the source's main queue; give
        // it a turn before observing the close.
        try await Task.sleep(for: .milliseconds(100))

        #expect(fcntl(fd, F_GETFD) == -1)
        #expect(errno == EBADF)
    }
}
