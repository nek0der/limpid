// AgentFileLock.swift
// Limpid — the persistent-inode advisory lock shared by Swift and hook receivers.

import Foundation

enum RecordMutationOutcome: Equatable {
    case applied
    case notFound
    case preconditionChanged
    case busy
}

enum AgentFileLock {
    /// Thrown when the bridge could not say what the lock sidecar is called.
    /// A guessed name would be a lock no writer takes, so holding it would
    /// keep nobody out while we replace or delete their file.
    struct LayoutUnavailable: Error {}

    /// Runs `body` while holding the lock every writer of `url` takes: the
    /// sidecar named by the layout's lock suffix.
    static func withLock(for url: URL, _ body: () throws -> RecordMutationOutcome) throws -> RecordMutationOutcome {
        guard let suffix = AgentProviderRegistry.recordLayout?.lockSuffix else { throw LayoutUnavailable() }
        let fd = open(url.path + suffix, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                return .busy
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
