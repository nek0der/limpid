// AttentionState+PromptCache.swift
// Limpid — which rows and panes show a prompt cache clock, what its panel
// says, what the panel's buttons do, and when the panel opens by itself.
//
// Every answer here reads `promptCache.now` rather than the wall clock, so a
// view that asks re-renders when the monitor's timer crosses a threshold and
// at no other time.

import Foundation
import OSLog

private let log = Logger.limpid("prompt-cache.action")

/// What a clock shows: the status, the window it describes, and the run
/// and pane its panel speaks for.
struct PromptCacheMark: Equatable {
    let status: PromptCacheStatus
    let window: AgentCacheWindow
    let target: PromptCacheTarget

    /// What the clock is called aloud: its own label, and a part of the
    /// pane header's when the header speaks for the clock inside it.
    var spokenStatus: String {
        status == .expired
            ? String(localized: "Prompt cache expired", comment: "Spoken label of the red prompt cache clock")
            : String(localized: "Prompt cache expires soon", comment: "Spoken label of the yellow prompt cache clock")
    }
}

/// An expired window the panel's answers act on, the run it belongs to,
/// and the pane whose terminal the panel's commands are typed into.
struct ExpiredPromptCache: Equatable {
    let runtimeID: String
    let paneID: UUID
    let window: AgentCacheWindow
}

/// The panel's three answers to an expired cache.
enum PromptCacheAction: Equatable {
    /// Summarize the conversation, reading it once at the write rate, so
    /// later turns resend a short prefix.
    case summarize
    /// Start over without the prefix; the conversation stays resumable.
    case newConversation
    /// Pay the rewrite and carry on.
    case continueAsIs

    /// What is typed at the agent's prompt, if anything. The agent's own
    /// commands, not a Limpid feature: the user could type the same.
    var command: String? {
        switch self {
        case .summarize: "/compact"
        case .newConversation: "/clear"
        case .continueAsIs: nil
        }
    }
}

/// Where the panel's commands are typed. A protocol so Core can decide
/// when typing is allowed without holding the terminal view, and so tests
/// can stand in for it.
@MainActor
protocol AgentCommandTyping: AnyObject {
    /// The process in front on the terminal and its name, or `nil` when
    /// they cannot be read. What receives a typed command is whatever is in
    /// front, whatever the records say.
    var foregroundProcessID: pid_t? { get }
    var foregroundProcessName: String? { get }

    /// When the user last sent a key, text, or paste to the terminal, or
    /// `nil` before the first. A key after the agent's turn ended may have
    /// opened a picker or started a draft the agent has not reported.
    var lastKeyInputAt: Date? { get }

    /// Whether text reached the terminal since the last submit (an
    /// unmodified Return, or Ctrl+C), so the prompt may hold a draft a
    /// typed command would be appended to.
    var hasUnsubmittedInput: Bool { get }

    /// Types `command` at the prompt as keystrokes and submits it. Returns
    /// false when there is no terminal to type into.
    func typeAgentCommand(_ command: String) -> Bool
}

@MainActor
extension AttentionState {
    /// Hands the monitor every window the runtimes carry.
    func refreshPromptCacheWindows() {
        var windows: [String: AgentCacheWindow] = [:]
        for runtime in allRuntimes {
            if let window = runtime.badge.cacheWindow {
                windows[runtime.id] = window
            }
        }
        promptCache.update(windows: windows)
    }

    /// The clock a Waiting row shows for one run in one pane, or `nil`.
    func promptCacheMark(runtimeID: String, paneID: UUID) -> PromptCacheMark? {
        guard let runtime = allRuntimes.first(where: { $0.id == runtimeID }) else { return nil }
        return visibleMark(for: runtime, paneID: paneID, at: promptCache.now)
    }

    /// The clock a split pane's header shows: the most urgent of the runs
    /// in that pane.
    func promptCacheMark(paneID: UUID) -> PromptCacheMark? {
        let now = promptCache.now
        return Self.mostUrgent(
            allRuntimes
                .filter { $0.paneIDs.contains(paneID) }
                .compactMap { visibleMark(for: $0, paneID: paneID, at: now) }
        )
    }

    /// The one clock a tab row shows for every run in its panes: the most
    /// urgent, and among equals the one that expired first or expires
    /// soonest, since that is the one the user would act on first. Its
    /// panel speaks for the pane that run is in, the focused one when the
    /// run spans several.
    func promptCacheMark(in tab: Tab) -> PromptCacheMark? {
        let leaves = tab.splitTree.allLeafIDs()
        let focused = tab.splitTree.effectiveFocusedLeafID
        let now = promptCache.now
        return Self.mostUrgent(allRuntimes.compactMap { runtime in
            let panes = leaves.filter { runtime.paneIDs.contains($0) }
            guard let paneID = panes.first(where: { $0 == focused }) ?? panes.first else { return nil }
            return visibleMark(for: runtime, paneID: paneID, at: now)
        })
    }

    /// What the clock's panel shows for `target`, or `nil` once its clock
    /// has gone: the run's turn started, its window was answered, or the
    /// run ended. The host closes the panel then. `typist` is the pane's
    /// terminal, which decides whether the commands can be typed now; the
    /// same checks run again when one is pressed.
    func promptCachePanelContent(
        for target: PromptCacheTarget,
        typist: (any AgentCommandTyping)?
    ) -> PromptCachePanelContent? {
        guard let runtime = allRuntimes.first(where: { $0.id == target.runtimeID }),
              let window = runtime.badge.cacheWindow
        else { return nil }
        return PromptCacheRules.panelContent(
            status: runtime.badge.promptCacheStatus(at: promptCache.now),
            window: window,
            isAnswered: promptCache.isAnswered(runtimeID: runtime.id, window: window),
            commandBlock: commandBlock(for: runtime, in: target.paneID, typist: typist)
        )
    }

    /// The line naming `target`'s pane in its panel; see
    /// `PromptCacheRules.paneLine(for:)`. The same label the pane header
    /// shows, read the same way for a single-pane tab, which has no header,
    /// so a panel opened from the tab row names its pane too.
    func promptCachePaneLine(for target: PromptCacheTarget, in session: WindowSession) -> String {
        PromptCacheRules.paneLine(for: paneHeaderLabel(paneID: target.paneID, in: session))
    }

    /// Records that `target`'s panel is on screen. An expired panel the
    /// user has seen, however it opened, does not open by itself again for
    /// that expiry. Called again when an open panel's cache expires under
    /// it, so a panel opened while yellow counts once it turns red.
    func notePromptCachePanelShown(_ target: PromptCacheTarget) {
        guard let runtime = allRuntimes.first(where: { $0.id == target.runtimeID }),
              let window = runtime.badge.cacheWindow,
              PromptCacheRules.clockStatus(
                  runtime.badge.promptCacheStatus(at: promptCache.now),
                  isAnswered: promptCache.isAnswered(runtimeID: runtime.id, window: window)
              ) == .expired
        else { return }
        promptCache.markPresented(runtimeID: target.runtimeID, window: window)
    }

    /// Opens the panel by itself for the pane focus just arrived at, when
    /// `PromptCacheRules.shouldAutoOpen` says so, below the clock
    /// `PromptCacheRules.autoOpenPlace` picks. True when it opened.
    @discardableResult
    func autoOpenPromptCachePanel(
        paneID: UUID,
        in window: PromptCacheAutoOpenWindow,
        presentation: PromptCachePanelPresentation
    ) -> Bool {
        let expired = expiredPromptCache(paneID: paneID)
        let place = PromptCacheRules.autoOpenPlace(
            paneID: paneID,
            tabID: window.tabID,
            showsPaneHeader: window.showsPaneHeader
        )
        guard PromptCacheRules.shouldAutoOpen(
            hasActionableExpiry: expired != nil,
            hasPresented: expired.map { promptCache.hasPresented(runtimeID: $0.runtimeID, window: $0.window) } ?? false,
            hasAnchor: PromptCacheRules.isAnchorVisible(presentation.anchor(for: place), in: window.bounds),
            isAnotherPanelOpen: window.isAnotherPanelOpen,
            isPanelOpen: presentation.request != nil
        ),
            let expired
        else { return false }
        let target = PromptCacheTarget(runtimeID: expired.runtimeID, paneID: paneID)
        guard presentation.open(target: target, place: place, trigger: .automatic) else { return false }
        promptCache.markPresented(runtimeID: expired.runtimeID, window: expired.window)
        return true
    }

    /// The expired window whose commands may be typed into a pane, or
    /// `nil`. Only while the agent sits at its prompt: a running turn is
    /// warming the cache, and a pending question or approval must not
    /// receive a typed command. A window the user already answered stays
    /// quiet.
    func expiredPromptCache(paneID: UUID) -> ExpiredPromptCache? {
        let now = promptCache.now
        let candidates = allRuntimes.filter { runtime in
            guard runtime.paneIDs.contains(paneID),
                  Self.isInFront(runtime, in: paneID),
                  runtime.badge.isAwaitingPrompt,
                  let window = runtime.badge.cacheWindow,
                  runtime.badge.promptCacheStatus(at: now) == .expired
            else { return false }
            return !promptCache.isAnswered(runtimeID: runtime.id, window: window)
        }
        // Runs hosted in tmux can share a pane, and only the active tmux
        // pane's is left by the filter above; among several without tmux
        // facts, the most recent turn is the one in front.
        guard let runtime = candidates.max(by: { lhs, rhs in
            (lhs.badge.cacheWindow?.observedAt ?? .distantPast)
                < (rhs.badge.cacheWindow?.observedAt ?? .distantPast)
        }),
            let window = runtime.badge.cacheWindow
        else { return nil }
        return ExpiredPromptCache(runtimeID: runtime.id, paneID: paneID, window: window)
    }

    /// Carries out one of the panel's answers. Returns false, and leaves
    /// the clock up, when the run has moved on since the panel was drawn
    /// — a new window, a turn started, the answer already given — or the
    /// command could not be typed safely.
    @discardableResult
    func performPromptCacheAction(
        _ action: PromptCacheAction,
        for expired: ExpiredPromptCache,
        typist: (any AgentCommandTyping)?
    ) -> Bool {
        // A second activation of the same answer, from a double click or a
        // click while the panel fades out, must not type the command twice.
        if promptCache.isAnswered(runtimeID: expired.runtimeID, window: expired.window) {
            log.notice("prompt cache action refused: the expiry was already answered")
            return false
        }
        guard let runtime = allRuntimes.first(where: { $0.id == expired.runtimeID }),
              runtime.badge.cacheWindow == expired.window
        else {
            log.notice("prompt cache action refused: the run ended or a newer turn replaced the window")
            return false
        }
        if let command = action.command {
            // Re-checked at the moment of typing, not taken from the frame
            // the button was drawn in: text typed into a running turn queues
            // as the next prompt, text typed into another tmux pane or a
            // shell left behind by a suspended or killed agent reaches
            // something that never asked for it, and text typed over a
            // draft or into an open picker joins it.
            if let block = commandBlock(for: runtime, in: expired.paneID, typist: typist) {
                log.notice("prompt cache action refused: \(String(describing: block), privacy: .public)")
                return false
            }
            guard let typist, typist.typeAgentCommand(command) else {
                log.notice("prompt cache action refused: the terminal could not take the command")
                return false
            }
        }
        // Answered at once rather than when the hooks report the command:
        // the clock would otherwise stay red, still offering the same
        // answers, until the agent's next event arrives.
        promptCache.markAnswered(runtimeID: expired.runtimeID, window: expired.window)
        return true
    }

    /// Why the run's commands cannot be typed into the pane through
    /// `typist` now, or nil when they can; see
    /// `PromptCacheRules.commandBlock`. No terminal counts as nothing in
    /// front.
    private func commandBlock(
        for runtime: AgentRuntimePresentation,
        in paneID: UUID,
        typist: (any AgentCommandTyping)?
    ) -> PromptCacheCommandBlock? {
        PromptCacheRules.commandBlock(
            isAtPromptInFront: runtime.badge.isAwaitingPrompt && Self.isInFront(runtime, in: paneID),
            isAgentInFront: typist.map { Self.isAgentInFront(runtime, in: paneID, typist: $0) } ?? false,
            hasUnsubmittedInput: typist?.hasUnsubmittedInput ?? false,
            lastKeyInputAt: typist?.lastKeyInputAt,
            turnEndedAt: runtime.badge.updatedAt
        )
    }

    /// Whether the run is the one the pane shows. A run hosted in tmux is
    /// in front only in the active pane of the tmux window the client
    /// shows; the others share the surface but are out of sight. One whose
    /// tmux location the topology probe has not resolved yet is treated as
    /// out of sight too, since the keys might reach another pane. The active
    /// flag is as fresh as the last probe, so a click just after switching
    /// tmux panes can still be judged against the previous one.
    private static func isInFront(_ runtime: AgentRuntimePresentation, in paneID: UUID) -> Bool {
        if let location = runtime.tmuxLocations[paneID] {
            return location.isActive
        }
        return runtime.badge.isTmuxHosted != true
    }

    /// Whether what is in front of the pane is the run's agent, so a typed
    /// command reaches it and not a shell it left behind when suspended or
    /// killed without ending its session.
    ///
    /// A recorded process settles it: the shim `exec`s the agent, so the pid
    /// the hooks record is the agent's, and anything else in front is not
    /// it, whatever its name. Names are the fallback, for runs whose hooks
    /// recorded no pid; they alone would refuse an agent that runs under an
    /// interpreter's name, as an npm install runs under `node`.
    ///
    /// A run hosted in tmux sees the tmux client in front, which forwards
    /// the keys to the pane `isInFront` already checked. That is as far as
    /// the check reaches: what runs inside that tmux pane is not visible
    /// from here, so a shell the agent left behind there still passes.
    private static func isAgentInFront(
        _ runtime: AgentRuntimePresentation,
        in paneID: UUID,
        typist: any AgentCommandTyping
    ) -> Bool {
        if runtime.tmuxLocations[paneID] != nil {
            return typist.foregroundProcessName == TmuxClientProbe.clientProcessName
        }
        if let recorded = runtime.processID {
            return recorded == typist.foregroundProcessID
        }
        guard let name = typist.foregroundProcessName else { return false }
        return AgentProviderRegistry.processNames(for: runtime.kind).contains(name)
    }

    /// The clock a run shows, speaking for `paneID`, or `nil`.
    private func visibleMark(
        for runtime: AgentRuntimePresentation,
        paneID: UUID,
        at now: Date
    ) -> PromptCacheMark? {
        guard let window = runtime.badge.cacheWindow,
              let status = PromptCacheRules.clockStatus(
                  runtime.badge.promptCacheStatus(at: now),
                  isAnswered: promptCache.isAnswered(runtimeID: runtime.id, window: window)
              )
        else { return nil }
        return PromptCacheMark(
            status: status,
            window: window,
            target: PromptCacheTarget(runtimeID: runtime.id, paneID: paneID)
        )
    }

    /// The most urgent mark, and among equals the one that expired first or
    /// expires soonest.
    private static func mostUrgent(_ marks: [PromptCacheMark]) -> PromptCacheMark? {
        marks.max { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
            }
            return lhs.window.expiresAt > rhs.window.expiresAt
        }
    }
}
