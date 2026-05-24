// SecureFileWrite.swift
// Limpid — helpers that write user data files (session snapshot,
// notification history, scrollback dumps) with `0600` permissions
// and create their parent directories with `0700`. Without these
// the macOS defaults (`0644` / `0755`) leave the file world-readable,
// which matters on shared / multi-user Macs where the data carries
// command history, search needles, project paths, and OSC 52 traffic.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "fs.secure")

enum SecureFileWrite {
    /// Create `dir` (and any missing parents) with mode 0700 so only
    /// the owning user can list its contents. Existing directories
    /// are left untouched — we don't want to silently lock down a
    /// directory the user already opted into sharing.
    static func ensureUserOnlyDirectory(_ dir: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            log.error("createDirectory failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Atomic write with `0600` permissions. We can't pass attributes
    /// through `Data.write(to:options:.atomic)`, so we write into a
    /// sibling tmp file ourselves, `chmod` it, then `rename` over the
    /// target — the same dance `Data.write(.atomic)` does internally,
    /// minus the leak of default permissions.
    static func writeAtomic(_ data: Data, to url: URL) throws {
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
            // `replaceItem` performs an atomic rename when source and
            // destination are on the same volume (which they always
            // are here — same parent dir).
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Best-effort `chmod 0600` on a file that some other component
    /// (e.g. libghostty's scrollback writer) already created. Logs
    /// but does not propagate failures — leaving the file in place
    /// with `0644` is better than throwing on a non-critical path.
    static func tightenPermissions(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            log.error("setAttributes failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
