// ProcessDrain.swift
// Limpid — run a child process to completion without deadlocking on
// its pipes.
//
// macOS pipe buffers are bounded (~16-64 KB). A child that writes
// more than that blocks in `write(2)` until something reads, so
// draining only after `waitUntilExit()` returns means the child never
// exits and the caller parks forever. `git status --porcelain=v2`
// against a dirty repo with hundreds of untracked files is the
// realistic case; `gh pr view --json` payloads are smaller today but
// a future `gh run view --log-failed` would not be.
//
// Shared by `GitProcess` and the optional-tool path because this is
// the one piece of process handling that is identical between them.
// What differs — throwing versus returning nil on launch failure,
// and whether the run is cancellable — is a deliberate difference in
// posture and stays with each caller.

import Foundation

/// Wait for `process` while draining both pipes concurrently.
/// Returns once the child has exited and both descriptors hit EOF.
func drainAndWait(_ process: Process, stdout: Pipe, stderr: Pipe) -> (stdout: Data, stderr: Data) {
    let outQueue = DispatchQueue(label: "dev.limpid.process.stdout")
    let errQueue = DispatchQueue(label: "dev.limpid.process.stderr")
    // Each buffer is written by exactly one queue and read only
    // after that queue's `DispatchGroup` has been waited on, so the
    // write and the read are ordered by the group rather than by the
    // compiler's isolation checking.
    nonisolated(unsafe) var outBuffer = Data()
    nonisolated(unsafe) var errBuffer = Data()
    let outGroup = DispatchGroup()
    let errGroup = DispatchGroup()
    outGroup.enter()
    outQueue.async {
        outBuffer = stdout.fileHandleForReading.readDataToEndOfFile()
        outGroup.leave()
    }
    errGroup.enter()
    errQueue.async {
        errBuffer = stderr.fileHandleForReading.readDataToEndOfFile()
        errGroup.leave()
    }
    process.waitUntilExit()
    outGroup.wait()
    errGroup.wait()
    return (outBuffer, errBuffer)
}
