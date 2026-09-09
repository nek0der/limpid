// AgentFileLock.swift
// Limpid — the same persistent-inode advisory lock used by shell hooks.

import Foundation

enum RecordMutationOutcome: Equatable {
    case applied
    case notFound
    case preconditionChanged
    case busy
}

enum AgentFileLock {
    static func withLock(for url: URL, _ body: () throws -> RecordMutationOutcome) throws -> RecordMutationOutcome {
        let fd = open(url.path + ".flock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
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
