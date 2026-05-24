// SettingsFileWatcher.swift
// Limpid — watches `settings.json` for external edits (the user
// hand-editing the file, or another tool writing to it) and
// triggers `SettingsStore.reloadFromDisk()` after a short debounce.
//
// We watch the **parent directory** in addition to the file itself.
// Reason: most editors (Code, Sublime, vim with `set backup`) save
// atomically — write to a temp file then `rename(2)` over the
// target. That changes the file's inode, which silently invalidates
// any watcher attached to the old inode. Watching the directory
// catches the rename event so we can re-acquire the file. WezTerm
// applies the same trick.
//
// 200ms debounce mirrors WezTerm's reload cadence — long enough to
// coalesce an editor's atomic-save bursts (write, fsync, rename),
// short enough that the user perceives the change as instant.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "settings.watcher")

@MainActor
final class SettingsFileWatcher {
    private weak var store: SettingsStore?

    private var dirSource: (any DispatchSourceFileSystemObject)?
    private var dirFD: CInt = -1
    private var debounceTask: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(200)

    init(store: SettingsStore) {
        self.store = store
    }

    deinit {
        // Close ownership lives in the cancel handler we set in
        // `start()` — calling `close(dirFD)` here too would double-
        // close the same fd if the source hasn't finished tearing
        // down yet. The cancel handler runs as soon as the source
        // is fully torn down, so leaving it to handle the close is
        // both correct and race-free.
        dirSource?.cancel()
    }

    /// Start watching. Safe to call multiple times — the second call
    /// is a no-op while the first source is still live.
    func start() {
        guard dirSource == nil else { return }
        let url = SettingsStore.settingsFileURL
        let dir = url.deletingLastPathComponent()

        // Make sure the directory exists so `open` doesn't fail on a
        // fresh install where settings.json hasn't been written yet.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("open() on \(dir.path, privacy: .public) failed: errno \(errno, privacy: .public)")
            return
        }
        self.dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.dirSource = source
        log.notice("settings.json watcher armed on \(dir.path, privacy: .public)")
    }

    func stop() {
        // Same rationale as `deinit`: the fd close is owned by the
        // dispatch source's cancel handler, so we just cancel here
        // and let the source close on tear-down.
        dirSource?.cancel()
        dirSource = nil
        dirFD = -1
    }

    /// Debounce reload requests. An editor's atomic save fires
    /// multiple events (rename + write) within a few ms — we want
    /// one reload at the tail, not a burst.
    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.store?.reloadFromDisk()
        }
    }
}
