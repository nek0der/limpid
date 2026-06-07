// CommandFinishConfig.swift
// Limpid — how to react when libghostty's COMMAND_FINISHED action fires.
//
// Today the values are hard-coded; a preferences UI will surface them
// later. The split mirrors Ghostty mac's `notifyOnCommandFinish*` config
// keys so future user-facing defaults map 1:1.

import Foundation

struct CommandFinishConfig {
    enum Mode {
        /// Never notify on command finish.
        case never
        /// Notify only when the source pane isn't currently focused
        /// (the window isn't key, or first responder is elsewhere).
        case unfocused
        /// Notify on every finish — useful for monitoring long-running
        /// pipelines from another monitor.
        case always
    }

    var mode: Mode = .unfocused
    /// Skip notifications for commands shorter than this. Long-running
    /// commands are the interesting case; a quick `ls` shouldn't ping
    /// the user.
    var minimumDuration: TimeInterval = 10
    /// Channels to fire. `.notify` posts to UNUserNotificationCenter;
    /// `.bell` invokes the same fan-out as RING_BELL.
    var channels: Channels = [.notify]

    struct Channels: OptionSet {
        let rawValue: Int
        static let notify = Channels(rawValue: 1 << 0)
        static let bell = Channels(rawValue: 1 << 1)
    }

    /// Default until the preferences UI exists.
    static let `default` = CommandFinishConfig()
}
