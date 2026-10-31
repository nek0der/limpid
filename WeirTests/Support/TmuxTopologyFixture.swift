// TmuxTopologyFixture.swift
// Weir — one tmux pane, as the suites that resolve a run's location need it.

import Foundation
@testable import Weir

extension TmuxTopology {
    /// Pane `%4` of a server on the default socket, reached through its
    /// `/tmp` alias as well.
    static func onePane(sessionID: String = "$2", start: String = "100") -> TmuxTopology {
        TmuxTopology(panes: TmuxTopology.parsePanes(
            "42\t\(start)\t\(sessionID)\t@3\t%4\t1\t1\n",
            socketPath: "/private/tmp/tmux-501/default"
        ), socketAliases: ["/tmp/tmux-501/default": "/private/tmp/tmux-501/default"])
    }
}
