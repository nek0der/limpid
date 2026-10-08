// PromptCacheRules.swift
// Limpid — the rules behind the prompt cache clock and its panel: which
// clock shows, what the panel says, when its commands may be typed, and when
// the panel opens by itself.
//
// Kept in Core and free of SwiftUI so the rules can be pinned by tests. The
// clock is drawn in three places — a tab row, a Waiting row, and a split
// pane's header — and the first and last open the same panel, so the
// decisions live here once rather than in each view.

import Foundation

/// The run a clock speaks for, and the pane whose terminal its panel's
/// commands are typed into.
struct PromptCacheTarget: Hashable {
    let runtimeID: String
    let paneID: UUID
}

/// Where a clock that opens the panel is drawn. Also the key each clock
/// publishes its frame under, so a panel can hang below the clock it was
/// opened from and the panel that opens by itself can find a clock to hang
/// from. The Waiting row's clock is only an indicator and has no place.
enum PromptCacheClockPlace: Hashable {
    /// The trailing status group of a tab row.
    case tabRow(tabID: UUID)
    /// The trailing group of a split pane's header.
    case paneHeader(paneID: UUID)
}

/// What the window looks like when focus arrives at a pane, as far as the
/// panel that opens by itself needs to know.
struct PromptCacheAutoOpenWindow: Equatable {
    /// The tab the pane is in, whose row clock stands in for a header.
    let tabID: UUID
    /// Whether the pane's header, and so its clock, is drawn.
    let showsPaneHeader: Bool
    /// Another floating panel, or review, is up.
    let isAnotherPanelOpen: Bool
    /// The window's content in the clocks' global coordinates; a clock
    /// outside it does not count as one to hang from.
    let bounds: CGRect
}

/// Why the panel's two commands cannot be typed right now. Each is a case
/// where keystrokes would land somewhere other than an empty prompt.
enum PromptCacheCommandBlock: Equatable {
    /// The agent is running a turn, asking a question, or out of sight in
    /// another tmux pane.
    case notAtPrompt
    /// Something other than the agent is in front of the pane: a shell it
    /// left behind, or nothing that can be read.
    case notInFront
    /// The prompt may hold text the user has not sent, or a picker the
    /// user opened: a command typed now would join the draft or filter the
    /// picker.
    case unsubmittedInput

    /// What the disabled buttons say instead of their usual help, and the
    /// line above them. Each says what is true of the pane and, where the
    /// panel cannot help, what the user can do instead.
    var reason: String {
        switch self {
        case .notAtPrompt:
            String(
                localized: "Available while the agent waits at its prompt.",
                comment: "Shown on the prompt cache panel while its agent is busy, asking, or out of sight"
            )
        case .notInFront:
            String(
                localized: "Available when the agent is what this pane is running.",
                comment: "Shown on the prompt cache panel while something other than the agent is in front of the pane"
            )
        case .unsubmittedInput:
            // Not "clear the prompt": a key after the turn blocks until the
            // next turn whatever the prompt holds now, so that advice would
            // not work. Typing the command is what does.
            String(
                localized: "You typed in this pane during or after the last turn. Type /compact or /clear yourself.",
                comment: "Shown on the prompt cache panel when the pane may hold input the user has not sent"
            )
        }
    }
}

/// What the clock's panel shows for one run.
struct PromptCachePanelContent: Equatable {
    /// `.expired` or `.expiringSoon`; the panel has nothing to say about the
    /// other states, which show no clock.
    let status: PromptCacheStatus
    let window: AgentCacheWindow
    /// The answers offered, top to bottom. None while the cache is only
    /// about to expire: nothing needs doing yet, and a button there would
    /// invite paying for a summary before it saves anything.
    let actions: [PromptCacheAction]
    /// Why the answers that type a command are disabled, or nil when they
    /// can be typed. "Continue as is" types nothing, so it is offered
    /// whatever this says. Always nil while the cache is only expiring,
    /// which offers no answers.
    let commandBlock: PromptCacheCommandBlock?

    var isExpired: Bool {
        status == .expired
    }

    var canTypeCommands: Bool {
        isExpired && commandBlock == nil
    }

    /// The panel's title, beside the clock.
    var title: String {
        isExpired
            ? String(localized: "Cache expired", comment: "Title of the expired prompt cache panel")
            : String(localized: "Cache expires soon", comment: "Title of the expiring prompt cache panel")
    }

    /// When: how long ago it expired, or how soon it will, at `now`.
    func timeLine(now: Date) -> String {
        if isExpired {
            let ago = PromptCacheFormatting.duration(now.timeIntervalSince(window.expiresAt))
            return String(
                localized: "Expired \(ago) ago.",
                comment: "Expired prompt cache panel; argument: a duration such as 56m"
            )
        }
        let remaining = PromptCacheFormatting.duration(window.expiresAt.timeIntervalSince(now))
        return String(
            localized: "Expires in \(remaining).",
            comment: "Expiring prompt cache panel; argument: a duration such as 2m"
        )
    }

    /// What going on costs, or nil when the provider did not report the
    /// size: "about ? tokens" would say nothing the title has not.
    var costLine: String? {
        guard let rewriteTokens = window.rewriteTokens else { return nil }
        let size = PromptCacheFormatting.tokens(rewriteTokens)
        return isExpired
            ? String(
                localized: "Continuing as is re-writes about \(size) tokens.",
                comment: "Expired prompt cache panel; argument: a token count such as 573k"
            )
            : String(
                localized: "Once expired, continuing re-writes about \(size) tokens.",
                comment: "Expiring prompt cache panel; argument: a token count such as 612k"
            )
    }

    /// The panel's sentences at `now`: when, then what it costs. Separate
    /// lines rather than one wrapped run, so a wrap cannot land inside a
    /// word, nor in Japanese before a long-vowel mark, which a line must not
    /// start with.
    func lines(now: Date) -> [String] {
        [timeLine(now: now)] + (costLine.map { [$0] } ?? [])
    }
}

enum PromptCacheRules {
    /// How long the panel waits, after focus arrives at an expired pane,
    /// before it opens by itself. Long enough for the clock it hangs from to
    /// be laid out after a tab switch, and for a quick walk across panes to
    /// pass through without a panel flashing at each one.
    static let autoOpenSettle: Duration = .milliseconds(300)

    /// The status a run's clock shows, or nil for none. Only the two states
    /// that ask for a decision show one: a healthy window is not news. An
    /// expiry the user already answered shows none either; a clock that
    /// stayed red after the answer would only teach the eye to pass over
    /// red, including the next window's.
    static func clockStatus(_ status: PromptCacheStatus, isAnswered: Bool) -> PromptCacheStatus? {
        switch status {
        case .expiringSoon:
            .expiringSoon
        case .expired:
            isAnswered ? nil : .expired
        case .hidden, .valid:
            nil
        }
    }

    /// What the panel shows for a run whose clock has `status`, or nil
    /// when that run shows no clock and so has no panel. `commandBlock`
    /// matters only once expired.
    static func panelContent(
        status: PromptCacheStatus,
        window: AgentCacheWindow,
        isAnswered: Bool,
        commandBlock: PromptCacheCommandBlock?
    ) -> PromptCachePanelContent? {
        guard let shown = clockStatus(status, isAnswered: isAnswered) else { return nil }
        let isExpired = shown == .expired
        return PromptCachePanelContent(
            status: shown,
            window: window,
            actions: isExpired ? [.summarize, .newConversation, .continueAsIs] : [],
            commandBlock: isExpired ? commandBlock : nil
        )
    }

    /// Whether the panel's commands may be typed into the pane now, and if
    /// not, why. Conservative on purpose: a wrong refusal costs a disabled
    /// button, a wrong yes types a command into the user's draft or into a
    /// picker.
    ///
    /// - `isAtPromptInFront`: the run waits at its prompt and is the one
    ///   the pane shows.
    /// - `isAgentInFront`: the process in front of the terminal is the
    ///   run's agent.
    /// - `hasUnsubmittedInput`: text reached the terminal since the last
    ///   submit.
    /// - `lastKeyInputAt`, `turnEndedAt`: a key typed after the turn ended
    ///   may have opened a picker or started a draft the agent has not
    ///   reported, so it counts as unsent input too.
    static func commandBlock(
        isAtPromptInFront: Bool,
        isAgentInFront: Bool,
        hasUnsubmittedInput: Bool,
        lastKeyInputAt: Date?,
        turnEndedAt: Date
    ) -> PromptCacheCommandBlock? {
        guard isAtPromptInFront else { return .notAtPrompt }
        guard isAgentInFront else { return .notInFront }
        if hasUnsubmittedInput {
            return .unsubmittedInput
        }
        if let lastKeyInputAt, lastKeyInputAt > turnEndedAt {
            return .unsubmittedInput
        }
        return nil
    }

    /// The line under the panel's title that names the pane it is about:
    /// the name its header shows, then the directory, as the header lays
    /// them out. In a split tab the clock alone does not say which pane the
    /// panel speaks for once the panel overlaps a neighbor.
    static func paneLine(for label: PaneHeaderLabel) -> String {
        guard let detail = label.detail else { return label.name }
        return "\(label.name) · \(detail)"
    }

    /// The clock a panel that opens by itself hangs from: the pane's own
    /// header clock while split headers show, otherwise the clock on the
    /// selected tab's row, which is the one beside the pane in view.
    static func autoOpenPlace(paneID: UUID, tabID: UUID, showsPaneHeader: Bool) -> PromptCacheClockPlace {
        showsPaneHeader ? .paneHeader(paneID: paneID) : .tabRow(tabID: tabID)
    }

    /// Whether a clock's frame can anchor a panel: on screen, inside the
    /// window's content. A lazy list keeps rows it has scrolled out of view
    /// alive with frames outside it, and a panel hung from one of those
    /// would open somewhere the user is not looking.
    static func isAnchorVisible(_ anchor: CGRect?, in windowBounds: CGRect) -> Bool {
        guard let anchor, !anchor.isEmpty else { return false }
        return anchor.intersects(windowBounds)
    }

    /// Whether the panel opens by itself for the pane focus just arrived
    /// at. Only for an expiry the panel's commands can act on, only once
    /// per expiry, only with a clock on screen to hang from — a panel
    /// floating free would not say which pane it is about — and never over
    /// another floating panel or one of its own.
    static func shouldAutoOpen(
        hasActionableExpiry: Bool,
        hasPresented: Bool,
        hasAnchor: Bool,
        isAnotherPanelOpen: Bool,
        isPanelOpen: Bool
    ) -> Bool {
        hasActionableExpiry && !hasPresented && hasAnchor && !isAnotherPanelOpen && !isPanelOpen
    }
}
