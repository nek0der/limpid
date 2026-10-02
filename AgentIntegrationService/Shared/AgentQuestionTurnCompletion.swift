// AgentQuestionTurnCompletion.swift
// Limpid — turn-scoped completion for Claude question requests.

import CryptoKit
import Darwin
import Foundation

struct AgentQuestionTurnCompletion {
    static let operationIDPrefix = "limpid-question-turn:"

    private let url: URL
    private let sessionID: String
    private let promptID: String?
    private let agentID: String?
    private let requestedAt: UInt64
    private let bootSessionID: String

    private struct Receipt: Codable {
        let sessionID: String
        let promptID: String?
        let agentID: String?
        let bootSessionID: String
        let completedAt: UInt64
    }

    private struct Identity {
        let url: URL
        let sessionID: String
        let promptID: String?
        let agentID: String?
    }

    var operationID: String {
        Self.operationIDPrefix + url.deletingPathExtension().lastPathComponent
    }

    init?(
        payload: Data, environment: [String: String],
        requestedAt: UInt64? = nil, bootSessionID: String? = nil
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["hook_event_name"] as? String == "PermissionRequest",
              object["tool_name"] as? String == "AskUserQuestion",
              let identity = Self.identity(object, environment: environment),
              let requestedAt = requestedAt ?? Self.processStartedAt(),
              let bootSessionID = bootSessionID ?? Self.currentBootSessionID()
        else { return nil }
        url = identity.url
        sessionID = identity.sessionID
        promptID = identity.promptID
        agentID = identity.agentID
        // XPC startup can finish after the terminal answer and Stop. We use
        // the hook process's birth time, which precedes those startup delays.
        self.requestedAt = requestedAt
        self.bootSessionID = bootSessionID
    }

    func hasCompleted() -> Bool {
        guard let receipt = Self.readReceipt(at: url),
              receipt.sessionID == sessionID, receipt.promptID == promptID,
              receipt.agentID == agentID,
              receipt.bootSessionID == bootSessionID,
              receipt.completedAt <= mach_absolute_time()
        else { return false }
        // Stop hooks can continue the same prompt. A prior Stop must not
        // release a question issued after that continuation begins.
        return receipt.completedAt >= requestedAt
    }

    static func record(
        payload: Data, environment: [String: String],
        completedAt: UInt64 = mach_absolute_time(), bootSessionID: String? = nil
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              ["Stop", "StopFailure", "SubagentStop"].contains(event),
              let identity = identity(object, environment: environment),
              event != "SubagentStop" || identity.agentID != nil,
              let bootSessionID = bootSessionID ?? currentBootSessionID()
        else { return }
        let directory = identity.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Stop writers and cleanup share a lock so cleanup cannot delete a
        // receipt that another writer has just replaced with new evidence.
        let descriptor = try lockReceipts(in: directory)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        if let existing = readReceipt(at: identity.url),
           existing.bootSessionID == bootSessionID, existing.completedAt > completedAt
        {
            return
        }
        let data = try JSONEncoder().encode(Receipt(
            sessionID: identity.sessionID, promptID: identity.promptID,
            agentID: identity.agentID,
            bootSessionID: bootSessionID, completedAt: completedAt
        ))
        try data.write(to: identity.url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.url.path)
        // Cleanup is best effort; a failure must not discard a new receipt.
        try? pruneExpiredReceipts(in: directory, bootSessionID: bootSessionID, completedAt: completedAt)
    }

    private static func identity(
        _ object: [String: Any], environment: [String: String]
    ) -> Identity? {
        guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let directory = environment["LIMPID_AGENT_STATES_DIR"], directory.hasPrefix("/")
        else { return nil }
        let agentID = object["agent_id"] as? String
        if object["agent_id"] != nil, agentID?.isEmpty != false {
            return nil
        }
        // Background children can outlive a root prompt. Their agent ID
        // identifies completion even when the shared prompt ID has changed.
        let promptID: String?
        let scope: String
        if let agentID {
            promptID = nil
            scope = "agent:\(agentID.utf8.count):\(agentID)"
        } else {
            guard let rootPromptID = object["prompt_id"] as? String, !rootPromptID.isEmpty else { return nil }
            promptID = rootPromptID
            scope = "prompt:\(rootPromptID.utf8.count):\(rootPromptID)"
        }
        // Provider identifiers never become path components. The receipt
        // retains the scope identifiers so the digest is not our evidence.
        let key = Data("\(sessionID.utf8.count):\(sessionID)\(scope)".utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("question-turns", isDirectory: true)
            .appendingPathComponent(name + ".json")
        return Identity(url: url, sessionID: sessionID, promptID: promptID, agentID: agentID)
    }

    private static func lockReceipts(in directory: URL) throws -> Int32 {
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        while flock(descriptor, LOCK_EX) != 0 {
            let error = errno
            if error == EINTR {
                continue
            }
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return descriptor
    }

    private static func readReceipt(at url: URL) -> Receipt? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private static func pruneExpiredReceipts(
        in directory: URL, bootSessionID: String, completedAt: UInt64
    ) throws {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return }
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", name.count == 64,
                  name.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let receipt = readReceipt(at: url)
            else { continue }
            // No requester survives a reboot. One day of awake time also
            // exceeds every approval deadline, so live requests keep evidence.
            let hasExpired = receipt.bootSessionID != bootSessionID
                || (completedAt >= receipt.completedAt && Double(completedAt - receipt.completedAt) * secondsPerTick > 86400)
            if hasExpired {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func processStartedAt() -> UInt64? {
        var info = rusage_info_v0()
        // We borrow this buffer only for the synchronous libproc call. Its
        // process-start clock shares the units of mach_absolute_time.
        let result = withUnsafeMutableBytes(of: &info) { bytes in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V0, bytes.baseAddress?.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0, info.ri_proc_start_abstime > 0 else { return nil }
        return info.ri_proc_start_abstime
    }

    private static func currentBootSessionID() -> String? {
        var bytes = [CChar](repeating: 0, count: 64)
        var size = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        guard let identifier = String(bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8),
              !identifier.isEmpty
        else { return nil }
        return identifier
    }
}
