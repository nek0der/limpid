// TmuxOutputGate.swift
// Limpid — which panes of a control connection have their output paused, and the refresh-client commands that change that.

import Foundation

/// The paused-output state of one control connection.
///
/// A control client receives `%output` for every pane of the session, not just
/// the windows we mirror, so we pause the rest with
/// `refresh-client -A '%N:off'` and resume them with `:on`. This type owns the
/// bookkeeping only: it holds where each pane lives and which panes we have
/// already paused, and hands the caller the commands that close the gap. It
/// never touches the connection, which keeps the decision testable apart from
/// the process.
struct TmuxOutputGate: Equatable {
    /// Window id (`@N`) to the pane ids (`%N`) that window holds.
    private(set) var panesByWindow: [String: Set<String>] = [:]
    /// The panes we have sent `:off` for and have not resumed.
    private(set) var silenced: Set<String> = []

    /// Replace everything we know, from every line of
    /// `list-panes -s -F '#{window_id} #{pane_id}'`.
    mutating func replaceAll(_ panes: [(window: String, pane: String)]) {
        var replacement: [String: Set<String>] = [:]
        for entry in panes {
            replacement[entry.window, default: []].insert(entry.pane)
        }
        panesByWindow = replacement
        forgetVanishedPanes()
    }

    /// Replace one window's panes, as `%layout-change` reports them.
    mutating func setPanes(_ panes: Set<String>, ofWindow window: String) {
        panesByWindow[window] = panes
        forgetVanishedPanes()
    }

    /// Forget a window and its panes when tmux reports it closed. The panes
    /// are gone on the tmux side, so we drop them from `silenced` rather
    /// than resuming them: a command naming a closed pane would only draw
    /// an error.
    mutating func removeWindow(_ window: String) {
        panesByWindow[window] = nil
        forgetVanishedPanes()
    }

    /// Bring `silenced` in line with the windows on screen and return what to
    /// send. Panes of a shown window belong on, every other known pane off;
    /// we emit only the panes whose state actually changes, in one
    /// `refresh-client`, and nothing at all when the two already agree.
    mutating func reconcile(shownWindows: Set<String>) -> [String] {
        var target: Set<String> = []
        for (window, panes) in panesByWindow where !shownWindows.contains(window) {
            target.formUnion(panes)
        }
        guard target != silenced else { return [] }

        let toPause = target.subtracting(silenced)
        let toResume = silenced.subtracting(target)
        silenced = target

        let arguments = Self.sorted(toPause).map { "-A '\($0):off'" }
            + Self.sorted(toResume).map { "-A '\($0):on'" }
        return ["refresh-client " + arguments.joined(separator: " ")]
    }

    /// Drop panes that no longer exist in any window. Callers never send
    /// commands for them, so leaving them in `silenced` would make a later
    /// reconcile believe it had already paused a pane it had not.
    private mutating func forgetVanishedPanes() {
        let known = Set(panesByWindow.values.joined())
        silenced.formIntersection(known)
    }

    /// Pane ids in a fixed order so a reconcile produces one comparable
    /// command. tmux numbers panes, so we sort on the number rather than the
    /// text, which would put `%10` before `%9`.
    private static func sorted(_ panes: Set<String>) -> [String] {
        panes.sorted { left, right in
            switch (Int(left.dropFirst()), Int(right.dropFirst())) {
            case let (leftNumber?, rightNumber?):
                leftNumber < rightNumber
            case (nil, _?):
                false
            case (_?, nil):
                true
            case (nil, nil):
                left < right
            }
        }
    }
}
