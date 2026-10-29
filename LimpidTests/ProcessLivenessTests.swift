// ProcessLivenessTests.swift
// Limpid — a killed process not yet reaped counts as gone, alone and as its group's last member.

import Darwin
import Foundation
import Testing
@testable import Limpid

struct ProcessLivenessTests {
    /// Starts `/bin/sleep` as the leader of a process group of its own.
    private static func spawnSleepingGroup() throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        try #require(posix_spawn(&pid, "/bin/sleep", nil, &attributes, &argv, environ) == 0)
        return pid
    }

    /// `kill(pid, 0)` still answers for the zombie; the process table says
    /// it has exited.
    @Test func aKilledProcess_notYetReaped_isNotLive_norIsItsGroup() async throws {
        let pid = try Self.spawnSleepingGroup()
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
