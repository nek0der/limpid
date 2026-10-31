// ProcessNames.swift
// Weir — names a process by the path it was started from, and lists a foreground process group's names, as the kernel reports them.

import Darwin
import Foundation

/// What a process is called, read from the kernel, for every reader that
/// asks which job runs in front: a surface's pty
/// (`SurfaceView.foregroundGroupProcessNames`) and a tmux pane's
/// (`TmuxPaneJob`). One reading, so an agent is the same name wherever it
/// runs.
///
/// Named by the path it was started from, not the kernel's accounting name
/// (`p_comm`, `proc_name`): that one is cut at 16 bytes, so Codex's native
/// `codex-darwin-arm64` reads as `codex-darwin-arm`, and Claude Code's
/// native installer starts `~/.local/bin/claude`, a link to a file named
/// after the version, whose accounting name is that version (`2.1.292`).
/// The start path is what a provider's declared process names match, and
/// what the hook's own ancestor walk compares, through `ps -o comm`.
enum ProcessNames {
    /// The most a foreground group is read in: a terminal's foreground job
    /// is far smaller.
    static let groupCapacity = 64

    /// The last component of the path `pid` was started from, or its
    /// accounting name when the kernel will not give the path; `nil` when
    /// it gives neither.
    static func name(of pid: pid_t) -> String? {
        executableName(of: pid) ?? accountingName(of: pid)
    }

    /// The last component of the path `pid` was started from, or `nil`
    /// when the kernel will not say.
    static func executableName(of pid: pid_t) -> String? {
        processArguments(of: pid).map { ($0.executable as NSString).lastPathComponent }
    }

    /// The kernel's accounting name for `pid` (`proc_name`), or `nil` for a
    /// process that has exited or is not ours to see.
    static func accountingName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    /// `pid`'s argument area (`KERN_PROCARGS2`), read
    /// (`parseProcessArguments`).
    static func processArguments(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        // The second call can report less than the first sized for.
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// The names of the processes in the process group `leader` leads, the
    /// leader first. An agent run through a launcher is the launcher in
    /// front, with the agent in its group: npm's Codex is `node …/bin/codex`
    /// starting the native `codex`. The leader's name is `""` when it
    /// cannot be read, so the first name is always the leader's. Empty for
    /// no leader. `name` is handed in so a test can name a group it made up.
    static func foregroundGroupNames(leader: pid_t, name: (pid_t) -> String? = ProcessNames.name(of:)) -> [String] {
        guard leader > 0 else { return [] }
        var members = [pid_t](repeating: 0, count: groupCapacity)
        let bytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY), UInt32(leader), &members, Int32(groupCapacity * MemoryLayout<pid_t>.size)
        )
        let count = bytes > 0 ? Int(bytes) / MemoryLayout<pid_t>.size : 0
        let others = members.prefix(count).filter { $0 > 0 && $0 != leader }
        return [name(leader) ?? ""] + others.compactMap(name)
    }

    /// The leader of the foreground process group of `tty`, with its
    /// accounting name (`p_comm`), as the kernel reports it.
    ///
    /// `KERN_PROC_TTY` lists every process whose controlling terminal is that
    /// device; the foreground one is where its process group matches the
    /// terminal's. We ask the kernel about the processes rather than the
    /// terminal because `tcgetpgrp` is `ioctl(TIOCGPGRP)`, which XNU answers
    /// only for the caller's own controlling terminal — and a windowed app has
    /// none.
    static func foregroundProcess(on tty: String) -> (pid: Int32, accountingName: String)? {
        var device = stat()
        guard tty.hasPrefix("/dev/"), stat(tty, &device) == 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(device.st_rdev)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 1
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let foreground = processes.prefix(count).filter {
            $0.kp_eproc.e_pgid == $0.kp_eproc.e_tpgid && $0.kp_eproc.e_tpgid > 1
        }
        // An agent running a tool puts several processes in the same group.
        // The leader is the one worth naming: "claude", not the helper it spawned.
        guard let process = foreground.first(where: { $0.kp_proc.p_pid == $0.kp_eproc.e_pgid })
            ?? foreground.first
        else { return nil }
        return (process.kp_proc.p_pid, accountingName(of: process))
    }

    /// `p_comm` is a fixed-size C array, which Swift imports as a tuple.
    private static func accountingName(of process: kinfo_proc) -> String {
        var command = process.kp_proc.p_comm
        return withUnsafeBytes(of: &command) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// A process's argument area as `KERN_PROCARGS2` lays it out: the
    /// argument count, the path it was started from, zero bytes up to the
    /// next 8-byte boundary from the path's start, then each argument (its
    /// own name first), each ending in a zero byte. Returns the path and
    /// the arguments after the name; `nil` when the area is cut short. An
    /// argument that is not UTF-8 is read with replacement characters: the
    /// path, which names the process, stays readable, and such an argument
    /// is no shell flag.
    static func parseProcessArguments(_ bytes: [UInt8]) -> (executable: String, arguments: [String])? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let count = Int(bytes.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = countSize
        let pathStart = index
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        guard index > pathStart, let path = String(bytes: bytes[pathStart..<index], encoding: .utf8) else { return nil }
        // Only the padding: an empty name (`argv[0] == ""`) is a zero
        // byte past it.
        let padded = pathStart + (index - pathStart + 1 + 7) / 8 * 8
        index += 1
        while index < min(padded, bytes.count), bytes[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        while arguments.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            // One running into the area's end was cut short.
            guard index < bytes.count else { return nil }
            // swiftlint:disable:next optional_data_string_conversion
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        guard count >= 1, arguments.count == count else { return nil }
        return (path, Array(arguments.dropFirst()))
    }
}
