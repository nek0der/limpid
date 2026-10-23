// SecureFileWrite.swift
// Limpid — helpers that write user data files (session snapshot,
// notification history, scrollback dumps) with `0600` permissions
// and create their parent directories with `0700`, and that move an
// unreadable one aside. Without these the macOS defaults (`0644` /
// `0755`) leave the file world-readable, which matters on shared /
// multi-user Macs where the data carries command history, search
// needles, project paths, and OSC 52 traffic. Every change here passes
// `TestWriteGuard` first, so a test run cannot reach the user's real data.

import Foundation
import OSLog

private let log = Logger.limpid("fs.secure")

enum SecureFileWrite {
    /// Create `dir` (and any missing parents) with mode 0700 so only
    /// the owning user can list its contents. Existing directories
    /// are left untouched — we don't want to silently lock down a
    /// directory the user already opted into sharing.
    static func ensureUserOnlyDirectory(_ dir: URL) {
        guard TestWriteGuard.permits(dir) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("createDirectory failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Atomic write with `0600` permissions. We can't pass attributes
    /// through `Data.write(to:options:.atomic)`, so we write into a
    /// sibling tmp file ourselves, `chmod` it, then `rename` over the
    /// target — the same dance `Data.write(.atomic)` does internally,
    /// minus the leak of default permissions.
    static func writeAtomic(_ data: Data, to url: URL) throws {
        try TestWriteGuard.check(url)
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fm = FileManager.default
        let created = fm.createFile(
            atPath: tmp.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "createFile failed at \(tmp.path)"]
            )
        }
        do {
            // The bytes must be on disk before the rename is: otherwise a
            // power loss right after it can leave the name pointing at an
            // empty file, and the old one is already gone.
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            try handle.synchronize()
            // `replaceItem` performs an atomic rename when source and
            // destination are on the same volume (which they always
            // are here — same parent dir). Without
            // `.usingNewMetadataOnly` it carries the old file's mode over
            // the new one, so a `0644` file left by an older build or by
            // hand would stay world-readable however often we save it.
            _ = try fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Moves a file aside to `<name>.bak-<reason>-<unix time>` beside it,
    /// and returns where it went. A store that cannot read its file calls
    /// this before anything saves: the next save would otherwise replace
    /// bytes the user may still want back with defaults or an empty list.
    /// Best effort: a missing file is left alone, and a failed rename is
    /// logged and leaves the file where it was.
    @discardableResult
    static func quarantine(_ url: URL, reason: String, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), TestWriteGuard.permits(url) else { return nil }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bak-\(reason)-\(Int(now.timeIntervalSince1970))")
        do {
            try fm.moveItem(at: url, to: backup)
            log.notice("quarantined \(url.lastPathComponent, privacy: .public) to \(backup.lastPathComponent, privacy: .public)")
            return backup
        } catch {
            log.error("failed to quarantine \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// What `setAside` left at the file's name.
    enum SetAsideResult {
        /// The file was moved, or was never there: saving is safe.
        case cleared
        /// The file could not be moved. It is the only copy, so the caller
        /// must not save, or the next save would replace it.
        case keptInPlace
    }

    /// Moves a file this build cannot use out of the way, and says whether
    /// its name is now clear to save over.
    static func setAside(_ url: URL, reason: String) -> SetAsideResult {
        quarantine(url, reason: reason) != nil || !FileManager.default.fileExists(atPath: url.path)
            ? .cleared : .keptInPlace
    }

    /// Best-effort `chmod 0600` on a file that some other component
    /// (e.g. libghostty's scrollback writer) already created. Logs
    /// but does not propagate failures — leaving the file in place
    /// with `0644` is better than throwing on a non-critical path.
    static func tightenPermissions(_ url: URL) {
        guard TestWriteGuard.permits(url) else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            log.error(
                "setAttributes failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Removes the file or folder at `url`. Limpid's own data is removed
    /// through here rather than `FileManager` so the test-run guard sees it.
    static func removeItem(at url: URL) throws {
        try TestWriteGuard.check(url)
        try FileManager.default.removeItem(at: url)
    }

    /// Moves `source` to `destination`; both ends are checked, because a move
    /// changes the folder it leaves as much as the one it reaches.
    static func moveItem(at source: URL, to destination: URL) throws {
        try TestWriteGuard.check(source)
        try TestWriteGuard.check(destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
