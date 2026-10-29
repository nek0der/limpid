// ProcessLivenessTests.swift
// Limpid — a killed process not yet reaped counts as gone, alone and as its group's last member.

import Darwin
import Foundation
import Testing
@testable import Limpid

struct ProcessLivenessTests {
    /// `kill(pid, 0)` still answers for the zombie; the process table says
    /// it has exited.
    @Test func aKilledProcess_notYetReaped_isNotLive_norIsItsGroup() async throws {
        // Reaped only at the end: the test looks at the zombie.
        let pid = try spawnProcessGroup(["/bin/sleep", "30"])
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        #expect(ProcessLiveness.isLive(pid))
        #expect(ProcessLiveness.hasLiveMembers(group: pid))

        kill(pid, SIGKILL)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { !ProcessLiveness.isLive(pid) }

        #expect(kill(pid, 0) == 0, "not reaped: the zombie is still in the table")
        #expect(!ProcessLiveness.isLive(pid))
        #expect(!ProcessLiveness.hasLiveMembers(group: pid))
    }

    @Test func noProcess_isNotLive() {
        #expect(!ProcessLiveness.isLive(0))
        #expect(!ProcessLiveness.hasLiveMembers(group: 0))
    }
}
