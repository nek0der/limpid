// SettingsFileWatcherTests.swift
// Weir — canceling the watcher closes the directory fd its source was registered with.
//
// The cancel handler captures the fd by value, so it closes the fd that
// source watched, never one a re-armed watcher opened since.

import Darwin
import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsFileWatcherTests {

    @Test("cancel closes the watched directory fd")
    func cancelClosesFD() async throws {
        try await withTempDir { dir in
            let store = SettingsStore(directory: dir)
            let watcher = SettingsFileWatcher(store: store)
            watcher.start()
            let fd = watcher.currentDirFD
            try #require(fd >= 0)
            var watchedDirectory = stat()
            try #require(fstat(fd, &watchedDirectory) == 0)

            watcher.stop()
            // The cancel handler runs on the source's main queue: wait until
            // the descriptor no longer names the watched directory, rather
            // than a fixed turn.
            await pollUntil(interval: .milliseconds(10)) {
                var now = stat()
                return fstat(fd, &now) == -1 || now.st_dev != watchedDirectory.st_dev || now.st_ino != watchedDirectory.st_ino
            }

            var currentDescriptor = stat()
            if fstat(fd, &currentDescriptor) == -1 {
                #expect(errno == EBADF)
            } else {
                // Swift Testing runs suites concurrently, so the kernel may reuse
                // the integer immediately. In that case, prove it no longer names
                // the unique directory that this watcher opened.
                #expect(
                    currentDescriptor.st_dev != watchedDirectory.st_dev
                        || currentDescriptor.st_ino != watchedDirectory.st_ino
                )
            }
        }
    }
}
