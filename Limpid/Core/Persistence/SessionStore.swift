// SessionStore.swift
// Limpid — reads/writes the session snapshot to disk under the
// per-build Application Support directory resolved by `LimpidPaths`
// (`Limpid/` for Release, `Limpid Dev/` for Debug, `Limpid Tests Stray/`
// for the XCTest host). Tests should inject a `WithTempDir` URL via
// `init(directory:)` rather than rely on the default.
//
// We debounce writes with a small leading-edge timer so a burst of
// changes (e.g. resizing the sidebar) doesn't slam the file system.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "session.store")

@MainActor
final class SessionStore {
    private let fileURL: URL
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.limpid.session-store")

    /// Production callers use the no-arg `init()`; tests pass an
    /// isolated temp directory via `init(directory:)` so they don't
    /// clobber the user's real state.json. The override is
    /// internal-only — production code should never call it.
    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.fileURL = directory.appendingPathComponent("state.json")
    }

    /// Outcome of attempting to restore the persisted session.
    /// Surfacing version mismatches and decode failures separately
    /// lets the boot path show a user-visible warning instead of
    /// silently dropping a corrupted file (and the user's history).
    enum LoadOutcome {
        case absent
        case loaded(SessionSnapshot)
        case versionMismatch(found: Int, expected: Int)
        case decodeFailed(any Error)
    }

    func load() -> LoadOutcome {
        // Demo mode swaps the on-disk snapshot for `DemoFixture` so
        // hero-screenshot reruns always produce the same scene. The
        // env var is read once per process (see `DemoFixture.swift`),
        // so we don't pay the lookup cost on every load.
        if DemoFixture.isDemoActive {
            log.notice("LIMPID_DEMO=1 active — using DemoFixture, persistence disabled")
            return .loaded(DemoFixture.snapshot)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return .absent }
        do {
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
            guard snapshot.version == SessionSnapshot.currentVersion else {
                log
                    .notice(
                        """
                        snapshot version mismatch (got \
                        \(snapshot.version, privacy: .public), want \
                        \(SessionSnapshot.currentVersion, privacy: .public))
                        """
                    )
                // Move the unsupported snapshot aside so the next save
                // doesn't destroy it — a future migration may want it.
                quarantineCorruptedFile(reason: "version-mismatch")
                return .versionMismatch(
                    found: snapshot.version,
                    expected: SessionSnapshot.currentVersion
                )
            }
            return .loaded(snapshot)
        } catch {
            log.error("failed to decode snapshot: \(String(describing: error), privacy: .public)")
            // We absolutely don't want the next `scheduleSave` to clobber
            // a file the user might still recover from. Rename it now,
            // before any mutation triggers a write.
            quarantineCorruptedFile(reason: "decode-failed")
            return .decodeFailed(error)
        }
    }

    /// Rename the on-disk snapshot to `state.json.bak-<unix>` so a
    /// subsequent save lands in a fresh file instead of overwriting
    /// the bad one. Best-effort; failures are logged but not surfaced.
    private func quarantineCorruptedFile(reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let bak = fileURL.deletingLastPathComponent()
            .appendingPathComponent("state.json.bak-\(reason)-\(ts)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: bak)
            log.notice("quarantined snapshot to \(bak.lastPathComponent, privacy: .public)")
        } catch {
            log.error("failed to quarantine snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    /// Debounced save. Coalesces a burst of mutations into a single
    /// write 400 ms after the last call. The snapshot value crosses
    /// onto the background queue inside the work item — `SessionSnapshot`
    /// is value-typed (Sendable) so the capture is safe.
    func scheduleSave(_ snapshot: SessionSnapshot) {
        // Demo mode is ephemeral by design — every launch reloads from
        // `DemoFixture` so nothing we'd write here matters, and writing
        // would clobber the user's real state.json if they happen to
        // toggle the env var by accident.
        guard !DemoFixture.isDemoActive else { return }
        pending?.cancel()
        let url = fileURL
        let work = DispatchWorkItem { [queue, snapshot] in
            queue.async {
                Self.write(snapshot, to: url)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    /// Synchronous save — pending work is cancelled and the snapshot is
    /// written through the same serial queue so it cannot race against a
    /// debounced write that may already be in flight. Call from
    /// applicationWillTerminate so the file actually lands before the
    /// process exits.
    func saveSynchronously(_ snapshot: SessionSnapshot) {
        guard !DemoFixture.isDemoActive else { return }
        pending?.cancel()
        pending = nil
        let url = fileURL
        queue.sync { Self.write(snapshot, to: url) }
    }

    private nonisolated static func write(_ snapshot: SessionSnapshot, to url: URL) {
        do {
            let encoder = JSONEncoder()
            // `.sortedKeys` keeps diffs noise-free for users who poke at
            // state.json by hand. `.prettyPrinted` is Debug-only —
            // production runs ship a compact file, which is both
            // smaller and faster to encode on every debounce tick.
            #if DEBUG
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            #else
                encoder.outputFormatting = [.sortedKeys]
            #endif
            let data = try encoder.encode(snapshot)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
