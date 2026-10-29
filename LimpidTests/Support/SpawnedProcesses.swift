// SpawnedProcesses.swift
// Limpid — starts a test's process as the leader of its own process group, reaps it, and ends what a test's child left running.

import Darwin
import Foundation
import Testing

/// Starts `arguments`, the executable's path first, as the leader of a
/// process group of its own, as a setup step or a terminal's foreground job
/// is, so a test can signal or wait for the group. The process is not
/// reaped here: a test that needs it gone once it ends calls
/// `reapWhenItEnds(_:)`, and one that looks at the zombie reaps it itself.
func spawnProcessGroup(_ arguments: [String]) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, arguments[0], nil, &attributes, &argv, environ)
    try #require(status == 0, "posix_spawn failed: \(status)")
    return pid
}

/// Reaps `pid` on another thread once it ends, as `Process` reaps a step,
/// so the test leaves no zombie behind.
func reapWhenItEnds(_ pid: pid_t) {
    DispatchQueue.global().async {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

/// Ends the process whose pid a test's child wrote to `file`, as `$!` after
/// starting it in the background. A run that returns while such a process
/// still holds its output is what those tests check, so the process outlives
/// the run, and without this it would go on for as long as it sleeps.
func killRecordedProcess(in file: URL) {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0
    else { return }
    kill(pid, SIGKILL)
}
