// CodexUsageLimitWatch.swift
// Limpid — watches a Codex session's rollout for a turn that ends at the plan's usage limit.

import Darwin
import Foundation

/// Codex runs no hook when its usage limit ends a turn (its `Stop` runs only
/// after a turn that sampled), so the pane would show the agent running for
/// hours. The rollout records it, as a `task_complete` whose error is
/// `usage_limit_exceeded`. After Codex's `SessionStart`, the helper leaves
/// one watcher per session that reads the rollout as it grows and, on that
/// line, reports `LimpidUsageLimitReached` through the same hook runtime in
/// the same environment as Codex's own hooks, so the run's record, its turn,
/// and the notification follow as for any failure. The report names the
/// session and the time it observed (`CodexUsageLimitReport`), since the run
/// may have moved on by the time it lands.
///
/// The watcher holds no pipe of Codex's (its standard streams are the null
/// device), runs in a process group of its own (`Process` starts each child
/// in one), so a signal to Codex's job does not reach it, and ends with
/// Codex.
enum CodexUsageLimitWatch {
    static let subcommand = "watch-codex-usage"
    /// How often the rollout is read: a limit shown some seconds late is
    /// fine, a busy loop beside every Codex session is not.
    static let interval: TimeInterval = 10
    /// Returns the names Codex's process has, read from the provider descriptor so a
    /// name added there is one the watcher looks for too. A registry that
    /// cannot be read leaves no name, which costs only the detection.
    static func processNames() -> Set<String> {
        do {
            return try RustProviderBridge.processNames(provider: "codex")
        } catch {
            logHookDiagnostic("Limpid hook helper: Codex's process names could not be read: \(error)")
            return []
        }
    }

    /// Leaves a watcher for the rollout `payload` names, when it is Codex's
    /// `SessionStart` in a Limpid run. Everything the watcher needs is taken
    /// here, while Codex waits for this hook: its process, the session, and
    /// the size the rollout has before the session's first turn. A failure
    /// to start one costs only the detection.
    static func start(after payload: Data, environment: [String: String], helper: URL) {
        guard environment["LIMPID_AGENT_RUN_ID"]?.isEmpty == false,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["hook_event_name"] as? String == "SessionStart",
              let rollout = object["transcript_path"] as? String,
              rollout.hasSuffix(".jsonl"),
              let session = object["session_id"] as? String, !session.isEmpty,
              let codex = ProcessAncestry.ancestor(named: processNames(), of: getpid())
        else { return }
        let process = Process()
        process.executableURL = helper
        process.arguments = [subcommand, String(codex), String(RolloutReader.size(of: rollout)), session, rollout]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logHookDiagnostic("Limpid hook helper: the usage limit watcher did not start: \(error)")
        }
    }

    /// The watcher's process: returns once Codex (`codex`) has ended, or at
    /// once when another watcher has the session or the arguments are not
    /// its own.
    static func run(arguments: ArraySlice<String>, environment: [String: String]) {
        let arguments = Array(arguments)
        guard arguments.count == 4, let codex = pid_t(arguments[0]), let offset = UInt64(arguments[1]),
              let runID = environment["LIMPID_AGENT_RUN_ID"], !runID.isEmpty
        else { return }
        let session = arguments[2]
        let rollout = arguments[3]
        guard let lock = claim(runID: runID, rollout: rollout) else { return }
        defer { close(lock) }
        var reader = RolloutReader(path: rollout, offset: offset)
        while isAlive(codex) {
            Thread.sleep(forTimeInterval: interval)
            let lines = reader.readNewLines(keeping: RolloutReader.mayBeUsageLimitLine)
            if let line = lines.compactMap(RolloutReader.usageLimitLine(in:)).last {
                // The time zone Codex printed its reset in is the one this
                // process runs in, its environment being Codex's. A line
                // with no time of its own was written within one interval.
                let writtenAt = line.writtenAt ?? Date().addingTimeInterval(-interval)
                let resetAt = line.message.flatMap {
                    CodexUsageLimitMessage.resetAt(in: $0, writtenAt: writtenAt, timeZone: .current)
                }
                let payload = CodexUsageLimitReport.payload(
                    rollout: rollout,
                    sessionID: session,
                    line: line,
                    readAt: Date(),
                    messageResetAt: resetAt
                )
                report(payload, environment: environment)
            }
        }
    }

    /// One watcher per session: a second `SessionStart` for it (a resume
    /// in the same run) finds the lock taken. Kept in the temporary
    /// directory, outside the record directories the projection reads.
    private static func claim(runID: String, rollout: String) -> Int32? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("limpid-usage-watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "\(runID)-\(URL(fileURLWithPath: rollout).deletingPathExtension().lastPathComponent).lock"
        let descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func report(_ payload: [String: Any], environment: [String: String]) {
        var environment = environment
        // A call of its own, as every hook call is (`limpid-hook`), so the
        // turn records apply it once.
        environment["LIMPID_HOOK_INVOCATION_ID"] = UUID().uuidString
        do {
            _ = try RustProviderBridge.runHook(
                provider: "codex",
                kind: .lifecycle,
                payload: JSONSerialization.data(withJSONObject: payload),
                environment: environment
            )
        } catch {
            logHookDiagnostic("Limpid hook helper: the usage limit was not reported: \(error)")
        }
    }
}

/// The process tree above the hook. Under tmux the hook's environment names
/// a tmux client rather than Codex (`LIMPID_CODEX_PID` is the shim's `$$`
/// outside the session), so Codex is found as the nearest ancestor by name,
/// as the hook runtime finds an agent's process.
enum ProcessAncestry {
    /// The nearest ancestor of `pid` (itself excluded) whose name is one
    /// of `names`.
    static func ancestor(named names: Set<String>, of pid: pid_t) -> pid_t? {
        var current = parent(of: pid)
        // A bound on the walk: a process tree is never this deep, and a
        // cycle (a reused pid read mid-change) must not loop.
        for _ in 0..<64 {
            guard let process = current, process > 1, let info = info(of: process) else { return nil }
            if names.contains(info.name) {
                return process
            }
            current = info.parent
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        info(of: pid)?.parent
    }

    /// The process's executable name and its parent. The name is read
    /// from its path: the kernel's own copy is cut at 16 characters, which
    /// `codex-darwin-arm64` is longer than.
    private static func info(of pid: pid_t) -> (name: String, parent: pid_t)? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            return ("", process.kp_eproc.e_ppid)
        }
        let bytes = path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        let name = String(bytes: bytes, encoding: .utf8).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return (name, process.kp_eproc.e_ppid)
    }
}
