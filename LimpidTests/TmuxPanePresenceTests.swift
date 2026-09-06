// TmuxPanePresenceTests.swift
// Limpid — covers the part of the tmux presence poll that does not need
// a live surface. The join itself (libghostty's foreground pid for a
// mounted pane) cannot be exercised from a test bundle, so what is
// pinned here is the lookup it depends on: a wrong answer from
// `proc_name` would mark every pane, or none.

import Darwin
import Foundation
import Testing
@testable import Limpid

@Suite("TmuxPanePresence")
struct TmuxPanePresenceTests {
    @Test("reads the executable name of a live process")
    func processName_ofSelf_isTheTestHost() {
        let name = TmuxPanePresence.processName(of: getpid())
        #expect(name?.isEmpty == false)
    }

    /// The poll runs against pids libghostty reported a tick ago, so a
    /// process that has since exited is the ordinary case rather than an
    /// error. It has to come back `nil` and not as a stale name.
    @Test("returns nil for a pid that is not ours to see")
    func processName_ofDeadPID_isNil() {
        // Pid 0 is the kernel's swapper: never a tmux client, and never
        // something `proc_name` hands back a name for.
        #expect(TmuxPanePresence.processName(of: 0) == nil)
    }

    /// `proc_name` yields a basename, so the comparison must not carry a
    /// path. A change to either side would make the mark stop appearing
    /// with nothing else failing.
    @Test("compares against the bare client name")
    func clientProcessName_isABasename() {
        #expect(!TmuxPanePresence.clientProcessName.contains("/"))
        #expect(TmuxPanePresence.clientProcessName == "tmux")
    }
}
