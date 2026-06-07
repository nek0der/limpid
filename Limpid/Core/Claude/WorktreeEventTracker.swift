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

private let log = Logger.limpid("claude.worktree.event.tracker")

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
        // `dirFD` close is owned by the dispatch source's cancel
        // handler (see `startDirectoryWatch`). Touching it here too
        // would race the handler and double-close the fd. Mirror of
        // `SettingsFileWatcher`'s teardown pattern.
        dirSource?.cancel()
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
        // Re-arm: cancel old source, let its handler close its fd.
        dirSource?.cancel()
        dirFD = -1

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
        // Capture `fd` by value — the close is owned by this source's
        // lifetime, not the tracker's. Mirror of `SettingsFileWatcher`.
        source.setCancelHandler { [fd] in
            close(fd)
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

        let fresh = Self.freshEventFilenames(in: names, seen: seen)
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

    /// Select directory entries the watcher should consume. Pure
    /// function so we can unit-test the `.tmp` exclusion without
    /// touching the file system.
    ///
    /// We skip `.tmp` files because the hook writes JSON to
    /// `<name>.tmp` and atomically renames to `<name>` — without the
    /// suffix filter we race the rename, "parse" a half-flushed
    /// tempfile, fail, then delete it before the hook can rename,
    /// silently losing the event entirely. We sort the result so
    /// events within one fs burst process in ns-timestamp filename
    /// order rather than directory-listing order.
    nonisolated static func freshEventFilenames(
        in names: [String],
        seen: Set<String>
    ) -> [String] {
        names
            .filter { !seen.contains($0) }
            .filter { !$0.hasSuffix(".tmp") }
            .sorted()
    }

    /// Standard handler that maps a `WorktreeCreate` event to a
    /// GitSync refetch on the owning project. We extract it so both
    /// the Claude and Codex trackers can share the same body — and so
    /// `LimpidApp.init` doesn't carry an extra ~20 lines of closure
    /// per agent.
    static func gitSyncRefetchHandler(
        for session: WindowSession
    ) -> (WorktreeEventRecord) -> Void {
        { [weak session] record in
            guard let session, let repoRoot = record.repoRoot else { return }
            // Match by canonical path so symlinked checkouts still
            // resolve to the right project. Strip any trailing slash
            // on both sides — Swift's URL Codable likes to round-trip
            // project roots as `file:///path/` (trailing `/`) while
            // the hook hands us `/path` (no slash), and a naive `==`
            // misses.
            let canonical = URL(fileURLWithPath: repoRoot)
                .standardizedFileURL.path.trimmedTrailingSlash
            let target = session.projects.first {
                $0.rootURL.standardizedFileURL.path.trimmedTrailingSlash == canonical
            }
            guard let target else { return }
            NotificationCenter.default.post(
                name: .limpidGitSyncRequested,
                object: target.id
            )
        }
    }
}
