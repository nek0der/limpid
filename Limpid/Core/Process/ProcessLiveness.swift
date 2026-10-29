// ProcessLiveness.swift
// Limpid — whether a process, or anything of a process group, is still running, with a killed process not yet reaped counted as gone.

import Darwin

/// Whether a process we stopped is still there, as the kernel's process
/// table says.
///
/// `kill(pid, 0)` answers for a zombie too: 0 for its pid, and `EPERM`
/// for a group that holds nothing else. A process killed after its parent
/// died is reparented to launchd and stays a zombie until launchd reaps
/// it, which on a busy Mac can outlast a wait's grace. A zombie runs
/// nothing and writes nothing, so a wait for a stopped group that counts
/// it runs to its deadline and reports a process left that is not there.
/// We read each member's state instead (`p_stat`, `SZOMB` for a zombie).
enum ProcessLiveness {
    /// Whether any member of process group `group` has not exited. A
    /// member that changed its user still counts: we cannot signal it, but
    /// it runs. When the table cannot be read, `kill`'s answer stands,
    /// zombies included, so a failed read never ends a wait early.
    static func hasLiveMembers(group: pid_t) -> Bool {
        guard group > 0 else { return false }
        guard let members = processes([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]) else {
            return kill(-group, 0) == 0 || errno == EPERM
        }
        return members.contains { $0.kp_proc.p_stat != SZOMB }
    }

    /// Whether process `pid` exists and has not exited.
    static func isLive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let process = processes([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]) else {
            return kill(pid, 0) == 0 || errno == EPERM
        }
        return process.contains { $0.kp_proc.p_pid == pid && $0.kp_proc.p_stat != SZOMB }
    }

    /// The table entries `mib` selects, or `nil` when the kernel would not
    /// give them. The list can grow between the size query and the read,
    /// so we ask for room for a few more.
    private static func processes(_ mib: [Int32]) -> [kinfo_proc]? {
        var mib = mib
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 8
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return nil }
        return Array(entries.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }
}
