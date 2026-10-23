// ProcessNamesTests.swift
// Limpid — a process is named by the path it was started from, whole, where the kernel's accounting name is cut at 16 bytes.

import Darwin
import Foundation
import Testing
@testable import Limpid

struct ProcessNamesTests {
    /// Longer than the 16 bytes the kernel keeps of an accounting name, as
    /// Codex's native `codex-darwin-arm64` is.
    private static let longName = "codex-darwin-arm64-names-test"

    /// Starts `/bin/sleep` through a link named `longName`, as the leader of
    /// a process group of its own, as a terminal's foreground job is.
    private static func spawnLongNamedSleep(in directory: URL) throws -> pid_t {
        let link = directory.appendingPathComponent(longName)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sleep")
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var pid: pid_t = 0
        let arguments = [link.path, "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, link.path, nil, &attributes, &argv, environ)
        try #require(status == 0, "posix_spawn failed: \(status)")
        return pid
    }

    private static func stop(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// A process whose start path's name is longer than the accounting name
    /// keeps its whole name, alone and as the leader of its group: what a
    /// tmux pane's job (`TmuxPaneJob.foregroundGroupNames`) and a surface's
    /// (`SurfaceView.foregroundGroupProcessNames`) both read, so a Codex
    /// inside the person's tmux is still Codex.
    @Test func aLongExecutableName_isReadWhole_alongWithItsGroup() throws {
        try withTempDir { directory in
            let pid = try Self.spawnLongNamedSleep(in: directory)
            defer { Self.stop(pid) }

            #expect(ProcessNames.name(of: pid) == Self.longName)
            #expect(ProcessNames.foregroundGroupNames(leader: pid) == [Self.longName])
            #expect(
                ProcessNames.accountingName(of: pid) != Self.longName,
                "the accounting name is the link's target, or cut short: never the whole start name"
            )
        }
    }

    /// A group's leader that cannot be read keeps its place as `""`, and a
    /// pid of no group reads as no job.
    @Test func aGroup_keepsItsLeaderFirst_evenUnnamed() throws {
        try withTempDir { directory in
            let pid = try Self.spawnLongNamedSleep(in: directory)
            defer { Self.stop(pid) }

            #expect(ProcessNames.foregroundGroupNames(leader: pid) { _ in nil } == [""])
            #expect(ProcessNames.foregroundGroupNames(leader: 0).isEmpty)
        }
    }

    @Test func aProcessArgumentArea_readsItsPathAndArguments() {
        /// As the kernel lays it out: the path padded with zero bytes to
        /// the next 8-byte boundary from its start.
        func area(_ count: Int32, path: String, _ arguments: [String], end: [UInt8] = []) -> [UInt8] {
            let pathBytes = Array(path.utf8)
            let padding = (pathBytes.count + 1 + 7) / 8 * 8 - pathBytes.count
            return withUnsafeBytes(of: count) { Array($0) } + pathBytes + [UInt8](repeating: 0, count: padding)
                + arguments.flatMap { Array($0.utf8) + [0] } + end
        }
        let login = ProcessNames.parseProcessArguments(area(1, path: "/bin/zsh", ["-zsh", "HOME=/x"]))
        #expect(login?.executable == "/bin/zsh")
        #expect(login?.arguments == [])
        let script = ProcessNames.parseProcessArguments(area(2, path: "/bin/bash", ["bash", "./install.sh"]))
        #expect(script?.arguments == ["./install.sh"])
        // An empty name stays in its place.
        let unnamed = ProcessNames.parseProcessArguments(area(2, path: "/bin/sleep", ["", "20"]))
        #expect(unnamed?.arguments == ["20"])
        // An argument that is not UTF-8 keeps the path readable.
        let odd = ProcessNames.parseProcessArguments(area(2, path: "/bin/sh", ["sh"], end: [0xFF, 0xFE, 0]))
        #expect(odd?.executable == "/bin/sh")
        #expect(ProcessNames.parseProcessArguments(area(3, path: "/bin/bash", ["bash"])) == nil)
        #expect(ProcessNames.parseProcessArguments(Array(area(1, path: "/bin/zsh", ["-zsh"]).dropLast())) == nil)
        #expect(ProcessNames.parseProcessArguments([1, 0]) == nil)
    }

    @Test("reads the executable name of a live process")
    func processName_ofSelf_isTheTestHost() {
        let name = ProcessNames.accountingName(of: getpid())
        #expect(name?.isEmpty == false)
    }

    /// The tmux poll runs against pids libghostty reported a tick ago, so a
    /// process that has since exited is the ordinary case rather than an
    /// error. It has to come back `nil` and not as a stale name.
    @Test("returns nil for a pid that is not ours to see")
    func processName_ofDeadPID_isNil() {
        // Pid 0 is the kernel's swapper: never a tmux client, and never
        // something `proc_name` hands back a name for.
        #expect(ProcessNames.accountingName(of: 0) == nil)
    }
}
