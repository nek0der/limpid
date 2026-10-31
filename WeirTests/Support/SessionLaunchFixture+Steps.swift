// SessionLaunchFixture+Steps.swift
// Weir — starting the fixture's launch, and a setup step that runs until it is stopped, for the session launch suites.

import Foundation
@testable import Weir
@testable import WeirDomain

extension SessionLaunchFixture {
    /// The request most of the suites start: Claude, after the setup.
    static let claude = SessionLaunchRequest(open: .agent(.claude))

    /// A shell, after the setup.
    static let shell = SessionLaunchRequest(open: .shell)

    /// Starts `request` in the fixture's worktree, in `window` (the
    /// primary when `nil`), with `notes` from before the worktree.
    func begin(
        _ request: SessionLaunchRequest = SessionLaunchFixture.claude,
        notes: [SessionLaunch.Note] = [],
        in window: WindowID? = nil
    ) {
        store.begin(projectID: project.id, worktreeID: worktree.id, request: request, notes: notes, in: session, window: window)
    }

    /// Whether every launch still listed waits for its agent's start
    /// (`.starting`): one that ran to its end without notes is no longer
    /// listed, and one kept `.done` with notes, or waiting in its terminal,
    /// does not count.
    var hasStarted: Bool {
        store.launches.values.allSatisfy { launch in
            if case .starting = launch.phase {
                return true
            }
            return false
        }
    }

    /// A fixture whose one setup step writes its pid to `dir/pid` and runs
    /// until it is stopped, begun with `request`; returns once the step
    /// runs, with its pid. One that `ignoresTERM` runs on until the SIGKILL
    /// that follows a stop's SIGTERM.
    static func startBlockingSetup(
        in dir: URL,
        ignoresTERM: Bool = false,
        request: SessionLaunchRequest = SessionLaunchFixture.claude
    ) async throws -> (fixture: SessionLaunchFixture, pid: pid_t) {
        let pidFile = dir.appendingPathComponent("pid")
        let trap = ignoresTERM ? "trap '' TERM; " : ""
        let fixture = try await make(in: dir, bootstrap: [.shorthand("\(trap)echo $$ > '\(pidFile.path)'; exec sleep 30")])
        fixture.begin(request)
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { pid(in: pidFile) != nil }
        guard let pid = pid(in: pidFile) else { throw StepDidNotStart() }
        return (fixture, pid)
    }

    /// Whether the process is still there. A killed process not yet reaped
    /// writes nothing, so it is not.
    static func isRunning(_ pid: pid_t) -> Bool {
        ProcessLiveness.isLive(pid)
    }

    struct StepDidNotStart: Error {}
}
