// WorktreeEventTracker.swift
// Limpid — Watches the `worktree-events` directory the
// `limpid-pretool-worktree-hook` shim script writes into and fires a
// handler for each fresh record. Mirrors `CwdEventTracker`'s shape:
// bootstrap-then-watch with a directory-level
// `DispatchSource.makeFileSystemObjectSource`.
//
// Each event file is a single JSON document written atomically by the
// hook. We consume (delete) the file after dispatching so the next
// launch doesn't re-fire records the app has already acted on; the
// `seen` in-memory set covers the same-launch case where the watcher
// re-scans the directory before the consumed delete has propagated.
//
// Bootstrap snapshots existing files as "already seen" (rather than
// deleting them) so a launch that races a hook in flight doesn't lose
// the event. If a file was dropped after the snapshot it shows up as
// "fresh" on the next fs event and gets dispatched normally.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.worktree.event.tracker")

/// On-disk payload written by `limpid-pretool-worktree-hook`. Fields
/// beyond `event` and `worktreePath` are optional so the schema can
/// grow without breaking older trackers.
struct WorktreeEventRecord: Codable, Equatable {
    let event: String
    let repoRoot: String?
    let worktreePath: String
    let branch: String?
}

@MainActor
final class WorktreeEventTracker {
    /// Sub-directory under `$LIMPID_AGENT_STATES_DIR` that the hook
    /// scripts write to. Kept as a static so the shim and the app
    /// can't drift apart.
    static let directoryName = "worktree-events"

    private let directory: URL

    /// File names we've already routed. Keyed by filename (the hook
    /// uses `date +%s%N` for monotonic uniqueness within a launch).
    private var seen: Set<String> = []

    private var handler: ((WorktreeEventRecord) -> Void)?

    /// `nonisolated(unsafe)` so `deinit` (nonisolated under Swift 6)
    /// can read these handles to close the fd / cancel the source.
    private nonisolated(unsafe) var dirSource: (any DispatchSourceFileSystemObject)?
    private nonisolated(unsafe) var dirFD: Int32 = -1

    init(agentStatesDirectory: URL) {
        self.directory = agentStatesDirectory
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    deinit {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
    }

    // MARK: - Bootstrap

    func bootstrap(handler: @escaping (WorktreeEventRecord) -> Void) {
        self.handler = handler
        guard !DemoFixture.isDemoActive else { return }

        // `open(O_EVTONLY)` fails on a non-existent directory; pre-create
        // so the watcher arms even on fresh installs.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // Snapshot, don't delete. The Limpid app may have started
        // mid-event — the hook could be flushing right now, and we
        // don't want to lose its write. Anything already present is
        // either stale (we already routed it last launch and forgot
        // to delete) or about to be deleted by the catch-up scan.
        if let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) {
            seen = Set(names)
        }
        startDirectoryWatch()
    }

    // MARK: - Directory watch

    private func startDirectoryWatch() {
        dirSource?.cancel()
        if dirFD >= 0 { close(dirFD) }

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("""
            open(\(self.directory.path, privacy: .public), O_EVTONLY) \
            failed errno=\(errno)
            """)
            return
        }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scanAndDispatch()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dirFD >= 0 {
                close(self.dirFD)
                self.dirFD = -1
            }
        }
        source.resume()
        dirSource = source
        log.notice("worktree-events watcher armed on \(self.directory.path, privacy: .public)")
    }

    private func scanAndDispatch() {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return
        }

        // Sort by filename so events within the same fs burst process
        // in their ns-timestamp order rather than directory-listing
        // order.
        let fresh = names.filter { !seen.contains($0) }.sorted()
        for name in fresh {
            seen.insert(name)
            let url = directory.appendingPathComponent(name)
            do {
                let data = try Data(contentsOf: url)
                let record = try JSONDecoder().decode(
                    WorktreeEventRecord.self, from: data
                )
                handler?(record)
            } catch {
                log.warning("""
                Failed to parse \(url.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
            // Consume the file in either case — keeping unparseable
            // events around just pollutes the directory and risks
            // re-firing on rescan. The hook will write a fresh
            // record next time anyway.
            try? FileManager.default.removeItem(at: url)
        }
    }
}
