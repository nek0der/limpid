// TmuxBindingMigration.swift
// Limpid — decides what becomes of the tmux bindings a restored session carries, before any pane mounts.

import Foundation

/// A binding was how a pane said "I was showing this tmux session": the
/// pane got a shell at launch and the attach command was typed into it
/// (`TmuxReattachCommandBuilder`). Agents Limpid hosts are shown as mirror
/// tabs now (design §2.5), so a binding of this build's agent server is
/// converted into one, and the user's own bindings (CHANGELOG #21) are
/// checked against their server before anything is typed into a pane
/// (design §6 decision 10).
///
/// Everything here is pure: the claims are read off the tabs, the answers
/// come from `TmuxServerSessions`, and the plan is applied by
/// `TmuxMirrorActions.reconcileRestoredBindings`. Every agent binding ends
/// the pass converted or dropped, so the next launch finds none of them to
/// migrate. A user's own binding is never converted and is kept unless its
/// session is gone, which is the point of #21: it is how their pane
/// reattaches at the launch after this one too.
enum TmuxBindingMigration {
    /// One restored binding, and the leaf that carries it.
    struct Claim: Equatable {
        let tabID: UUID
        let leafID: UUID
        let binding: TmuxBinding
        /// Whether the socket is a Limpid build's agent server. Those are
        /// the bindings this migration converts; the user's own are only
        /// checked.
        let isAgentServer: Bool

        var socketPath: String {
            binding.socketPath
        }
    }

    /// A leaf that becomes a mirror pane.
    struct Conversion: Equatable {
        let tabID: UUID
        let leafID: UUID
        let ref: TmuxPaneRef
        /// Whether the leaf has to move to a tab of its own. A tab whose
        /// only leaf is the agent's becomes the mirror itself, which keeps
        /// its place in the list and everything else the tab holds.
        let needsOwnTab: Bool
    }

    /// A leaf that keeps its shell, having lost its binding.
    struct Drop: Equatable {
        let tabID: UUID
        let leafID: UUID
    }

    struct Plan: Equatable {
        var conversions: [Conversion] = []
        var drops: [Drop] = []

        var isEmpty: Bool {
            conversions.isEmpty && drops.isEmpty
        }
    }

    /// What one claim's server answer allows.
    enum Verdict: Equatable {
        /// The recorded server still has the recorded session. Only this
        /// answer lets an agent's binding become a mirror, because a
        /// mirror's reference must name the server run: pane ids restart
        /// with the server, and the run is what a later reconnect and the
        /// endpoint reports are checked against.
        case live(sessionID: String)
        /// A server answered and has a session of the recorded name,
        /// though not the recorded one. The user's own reattach may still
        /// find it by name, as it always could after a tmux-resurrect
        /// restore.
        case namedSessionOnly
        /// The session this binding names is not there to attach to.
        case gone
        /// Nothing was learned. A user's binding is kept rather than lost
        /// for good; an agent's is dropped anyway, since a mirror cannot be
        /// opened without knowing the window and pane, and the run stays
        /// reachable as a detached one.
        case unknown
    }

    // MARK: - Reading the tabs

    static func claims(in tabs: [Tab]) -> [Claim] {
        tabs.flatMap { tab in
            tab.tmuxBindings
                .filter { !$0.value.socketPath.isEmpty }
                .map { leafID, binding in
                    Claim(
                        tabID: tab.id,
                        leafID: leafID,
                        binding: binding,
                        isAgentServer: PaneShellEnvironment.isAgentSocketPath(binding.socketPath)
                    )
                }
                // A dictionary has no order of its own, and the plan is
                // compared in tests and logged.
                .sorted { $0.leafID.uuidString < $1.leafID.uuidString }
        }
    }

    /// The sessions whose panes have to be looked up before a plan can be
    /// made: one query per agent session that is still live.
    static func liveAgentSessions(
        _ claims: [Claim],
        answers: [String: TmuxServerSessions]
    ) -> [(socketPath: String, sessionID: String)] {
        var found: [(socketPath: String, sessionID: String)] = []
        for claim in claims where claim.isAgentServer {
            guard case let .live(sessionID) = verdict(for: claim, answer: answers[claim.socketPath]) else { continue }
            if !found.contains(where: { $0.socketPath == claim.socketPath && $0.sessionID == sessionID }) {
                found.append((claim.socketPath, sessionID))
            }
        }
        return found
    }

    // MARK: - Deciding

    static func verdict(for claim: Claim, answer: TmuxServerSessions?) -> Verdict {
        guard let answer else { return .unknown }
        switch answer {
        case .serverGone:
            return .gone
        case .unreachable:
            return .unknown
        case let .sessions(rows):
            let recorded = TmuxServerGeneration.recorded(in: claim.binding)
            if let recorded,
               rows.first?.serverPID == recorded.pid, rows.first?.serverStartedAt == recorded.startedAt,
               let row = rows.first(where: { $0.sessionID == claim.binding.sessionID })
            {
                return .live(sessionID: row.sessionID)
            }
            // Either another server answers on the socket or this one no
            // longer has the session. Both leave the name, which is the
            // only target a binding without a recorded run ever had.
            let name = claim.binding.sessionName
            return !name.isEmpty && rows.contains { $0.sessionName == name } ? .namedSessionOnly : .gone
        }
    }

    /// The plan for one pass. `panes` answers the queries
    /// `liveAgentSessions` asked for, keyed by socket path and session id.
    static func plan(
        tabs: [Tab],
        claims: [Claim],
        answers: [String: TmuxServerSessions],
        panes: [String: TmuxSessionPane]
    ) -> Plan {
        let leafCounts = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.splitTree.allLeafIDs().count) })
        var plan = Plan()
        for claim in claims {
            let verdict = verdict(for: claim, answer: answers[claim.socketPath])
            guard claim.isAgentServer else {
                // The user's own binding is only ever kept or dropped. A
                // dropped one is what keeps an attach out of a pane whose
                // server is gone, which used to print "error connecting"
                // into it.
                if verdict == .gone {
                    plan.drops.append(Drop(tabID: claim.tabID, leafID: claim.leafID))
                }
                continue
            }
            guard case let .live(sessionID) = verdict,
                  let pane = panes[paneKey(socketPath: claim.socketPath, sessionID: sessionID)]
            else {
                plan.drops.append(Drop(tabID: claim.tabID, leafID: claim.leafID))
                continue
            }
            var binding = claim.binding
            binding.sessionID = sessionID
            plan.conversions.append(Conversion(
                tabID: claim.tabID,
                leafID: claim.leafID,
                ref: TmuxPaneRef(binding: binding, windowID: pane.windowID, paneID: pane.paneID),
                needsOwnTab: (leafCounts[claim.tabID] ?? 1) > 1
            ))
        }
        return plan
    }

    /// Every claim dropped, for a machine with no tmux to ask. Nothing can
    /// be attached or mirrored there, and a binding kept would only block
    /// the pane's agent from resuming.
    static func planWithoutTmux(claims: [Claim]) -> Plan {
        Plan(conversions: [], drops: claims.map { Drop(tabID: $0.tabID, leafID: $0.leafID) })
    }

    static func paneKey(socketPath: String, sessionID: String) -> String {
        "\(socketPath)|\(sessionID)"
    }
}
