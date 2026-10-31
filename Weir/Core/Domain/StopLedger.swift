// StopLedger.swift
// Weir — the stops the attention list keeps until their conversation is active again.

import Foundation

/// A stop outlives its run. An agent that failed and exited leaves no
/// runtime once its record is cleaned up, and a stop that went with it
/// would hide the one item the person has to deal with. A stop stays until
/// a run of the same conversation is active again (the person typed on in
/// the TUI, or resumed it), the person starts a new conversation in its
/// pane instead (pressed: `dismiss`; typed: `hasMovedOn`), or its pane is
/// closed. Not the passing of time.
///
/// Kept across launches by `StopLedgerStore`: a stop that exists at quit
/// exists after the relaunch, since the run that died was retired with its
/// record and nothing else says the pane holds a conversation that stopped.
/// A stop whose run was cleaned up before the launch that would have seen
/// it is not known.
struct StopLedger: Equatable, Sendable {
    struct Record: Equatable, Sendable {
        let itemID: AttentionItemID
        let runtimeID: String
        let provider: AgentKind
        let paneID: UUID
        var conversation: ConversationKey?
        /// The provider's session id, which "Resume Same Conversation"
        /// resumes; `nil` when the run never reported one, or when its
        /// session was never prompted and has nothing to resume
        /// (`RuntimeFact.resumableSessionID`).
        var sessionID: String?
        /// The folder the conversation was in, which the resume runs in.
        var cwd: String?
        /// The turn the run stopped in, for "Show Partial Changes".
        var turnID: TurnID?
        var reason: StopReason
        let stoppedAt: Date
        var resume: Resume = .none
    }

    enum Resume: Equatable, Sendable {
        case none
        /// "Resume Same Conversation" typed the resume into the pane's shell
        /// at `since`, asked from `window`; `nil` when no window asked, so no
        /// bar says it is back.
        case resuming(since: Date, window: WindowID?)
        /// The last resume did not bring the conversation back: its command
        /// returned to the shell first, or its deadline passed. Its own
        /// words are in the terminal.
        case failed
    }

    /// A stop that ended with a resume: its pane, and the window that asked,
    /// whose bar says it is back (`nil`: none asked, and no bar says so).
    struct Resumed: Equatable, Sendable {
        let paneID: UUID
        let window: WindowID?
        /// Whether the run it came back in already began a turn since the
        /// stop: a new run with a turn, or the stopped run in a later one.
        /// The person has typed on, so "Type your next instruction" is late.
        var hasBegunATurn = false
    }

    /// What the stops that ended in one `update` say of their panes.
    struct Ended: Equatable, Sendable {
        /// The stops a resume brought back.
        var resumed: [Resumed] = []
        /// The panes whose stop ended as the person moved on to another
        /// conversation there (`hasMovedOn`): what was said in them while
        /// stopped is past. Only the stop can tell this from its
        /// conversation coming back in a new run, which `PaneRunLedger`
        /// sees as the same arrival.
        var movedOn: Set<UUID> = []
    }

    /// The resume Weir typed into a restored pane at launch: its
    /// session, and when it was typed. Not a stop while it is on its way,
    /// since every relaunch would otherwise list one per pane; it becomes
    /// a stop with `.failed` once its command returns to the shell with no
    /// run of the conversation, or its deadline passes with no agent in
    /// front of the pane, and is forgotten once a run of the session
    /// reports or the agent is in front at the deadline.
    struct LaunchResume: Equatable, Sendable {
        let paneID: UUID
        let provider: AgentKind
        let sessionID: String
        let cwd: String?
        let since: Date
    }

    private(set) var records: [AttentionItemID: Record] = [:]
    /// The resumes typed at launch, by pane (`markResumingAtLaunch`).
    private(set) var launchResumes: [UUID: LaunchResume] = [:]
    /// Stops that ended while their run still says so (an agent killed
    /// outright, or left in its error in one pane while its conversation
    /// was resumed in another, stays in error until its record is cleaned
    /// up): the person moved on, or the conversation is back. Neither kept
    /// here again nor listed.
    private(set) var dismissed: Set<AttentionItemID> = []

    init() {}

    /// The ledger as the last launch left it (`StopLedgerStore`): its
    /// stops and the ones the person moved on from. A stop whose pane the
    /// session did not restore ends at the first `update`, as any whose
    /// pane is closed does.
    init(restoring records: [Record], dismissed: Set<AttentionItemID>) {
        self.records = Dictionary(records.map { ($0.itemID, $0) }, uniquingKeysWith: { _, last in last })
        self.dismissed = dismissed
    }

    func record(_ itemID: AttentionItemID) -> Record? {
        records[itemID]
    }

    /// Takes in what the runtimes say now: a run in error is a stop; a
    /// stop whose conversation is active again, whose pane moved on to
    /// another conversation (`hasMovedOn`), or whose pane is gone, ends.
    /// `cwd` is the folder a run's conversation was in, when known. Returns
    /// what the stops that ended say of their panes.
    mutating func update(
        runtimes: [RuntimeFact],
        paneExists: (UUID) -> Bool,
        cwd: (RuntimeFact) -> String? = { _ in nil }
    ) -> Ended {
        let inError = Set(runtimes.filter { $0.state == .error }.map(Self.itemID(of:)))
        dismissed.formIntersection(inError)
        for runtime in runtimes where runtime.state == .error {
            guard let paneID = runtime.paneIDs.first else { continue }
            let itemID = Self.itemID(of: runtime)
            guard !dismissed.contains(itemID) else { continue }
            // The same error, reported again: what the run learned since
            // (its session, its conversation) is the resume's to use.
            if var record = records[itemID] {
                record.sessionID = runtime.hasPrompt == false ? nil : runtime.sessionID ?? record.sessionID
                record.conversation = runtime.conversation ?? record.conversation
                record.cwd = cwd(runtime) ?? record.cwd
                record.turnID = runtime.currentTurnID ?? record.turnID
                record.reason = runtime.stopReason
                if record != records[itemID] {
                    records[itemID] = record
                }
                continue
            }
            // A newer stop of the same run or conversation in the pane is
            // what it did last, and replaces the older. Another run's stop
            // stays: its row resumes its own conversation, which needs its
            // record whichever run stopped first.
            for (other, record) in records where record.paneID == paneID && Self.isSameRun(record, as: runtime) {
                records[other] = nil
            }
            records[itemID] = Record(
                itemID: itemID,
                runtimeID: runtime.runtimeID,
                provider: runtime.provider,
                paneID: paneID,
                conversation: runtime.conversation,
                sessionID: runtime.resumableSessionID,
                cwd: cwd(runtime),
                turnID: runtime.currentTurnID,
                reason: runtime.stopReason,
                stoppedAt: runtime.updatedAt
            )
        }
        for (paneID, launch) in launchResumes {
            // A run of the session that reported after the resume was
            // typed is the conversation back, or its own stop: the old
            // run's record, read before the relaunch, is neither.
            if !paneExists(paneID) || runtimes.contains(where: { Self.isOfTheLaunchResume(launch, $0) }) {
                launchResumes[paneID] = nil
            }
        }
        return endStops(runtimes: runtimes, inError: inError, paneExists: paneExists)
    }

    /// Ends the stops whose pane is gone, whose conversation is back, or
    /// whose pane moved on (`update`).
    private mutating func endStops(
        runtimes: [RuntimeFact],
        inError: Set<AttentionItemID>,
        paneExists: (UUID) -> Bool
    ) -> Ended {
        var ended = Ended()
        for (itemID, record) in records {
            if !paneExists(record.paneID) {
                records[itemID] = nil
            } else if let back = runtimes.first(where: { Self.isBack(record, as: $0) }) {
                // Said in the pane only when the conversation came back
                // there; elsewhere the pane's bar is gone, and a line left
                // for it would show to a later agent.
                if case let .resuming(_, window) = record.resume, back.paneIDs.contains(record.paneID) {
                    let hasBegunATurn = back.runtimeID == record.runtimeID
                        ? back.currentTurnID != record.turnID
                        : back.currentTurnID != nil
                    ended.resumed.append(Resumed(paneID: record.paneID, window: window, hasBegunATurn: hasBegunATurn))
                }
                records[itemID] = nil
                // The old run may stay in its error; the list would make
                // the stop again from it.
                if inError.contains(itemID) {
                    dismissed.insert(itemID)
                }
            } else if !inError.contains(itemID), runtimes.contains(where: { Self.hasMovedOn(record, to: $0) }) {
                records[itemID] = nil
                ended.movedOn.insert(record.paneID)
            }
        }
        return ended
    }

    /// Whether `runtime` is the person moving on in the stop's pane: a run
    /// of another conversation, active there after the stop, while nothing
    /// in that pane is left of the stopped run (it exited, or a resume
    /// typed at launch never brought it back). Starting the agent again by
    /// hand is "Start New Conversation" typed rather than pressed, and the
    /// bar would otherwise call the pane stopped over a working agent.
    ///
    /// A stopped run still in its error keeps its stop beside the new one:
    /// two runs in one pane are two tmux sessions, and the stopped one is
    /// still there to type on (`StopLedgerTests`).
    static func hasMovedOn(_ record: Record, to runtime: RuntimeFact) -> Bool {
        guard runtime.paneIDs.contains(record.paneID), runtime.updatedAt > record.stoppedAt else { return false }
        switch runtime.state {
        case .error, .unknown: return false
        case .idle, .running, .compacting, .needsInput, .finished: return true
        }
    }

    /// The stops whose run no longer says so (it exited, or its record was
    /// cleaned up): the attention list keeps them from here. A run still
    /// in the same error lists its stop itself.
    func retained(besides runtimes: [RuntimeFact]) -> [Record] {
        let listed = Set(runtimes.filter { $0.state == .error }.map(Self.itemID(of:)))
        return records.values
            .filter { !listed.contains($0.itemID) }
            .sorted { $0.stoppedAt != $1.stoppedAt ? $0.stoppedAt < $1.stoppedAt : $0.runtimeID < $1.runtimeID }
    }

    /// Ends a stop the person moved on from: "Start New Conversation".
    mutating func dismiss(_ itemID: AttentionItemID) {
        guard records.removeValue(forKey: itemID) != nil else { return }
        dismissed.insert(itemID)
    }

    mutating func markResuming(_ itemID: AttentionItemID, at date: Date, window: WindowID?) {
        records[itemID]?.resume = .resuming(since: date, window: window)
    }

    /// Weir typed the resume of `sessionID` into the restored `paneID` at
    /// `date`. A resume typed again into the pane is the later one.
    mutating func markResumingAtLaunch(paneID: UUID, provider: AgentKind, sessionID: String, cwd: String?, at date: Date) {
        launchResumes[paneID] = LaunchResume(paneID: paneID, provider: provider, sessionID: sessionID, cwd: cwd, since: date)
        // The pane's own stop of this session (kept from the last launch)
        // is the launch's to resume now: its bar says so rather than
        // offering a second resume, and the launch's end ends it either
        // way (`isBack`, or `failLaunchResume`).
        for itemID in stops(inPane: paneID, provider: provider, sessionID: sessionID) {
            records[itemID]?.resume = .resuming(since: date, window: nil)
        }
    }

    /// The stops of `sessionID` in `paneID`, which a resume typed at
    /// launch takes over.
    private func stops(inPane paneID: UUID, provider: AgentKind, sessionID: String) -> [AttentionItemID] {
        records.values
            .filter { $0.paneID == paneID && $0.provider == provider && $0.sessionID == sessionID }
            .map(\.itemID)
    }

    /// The stop a resume typed at launch becomes when it fails: one per
    /// pane and session, so a resume typed again from its bar and failing
    /// again is the same stop.
    static func launchResumeItemID(paneID: UUID, sessionID: String) -> AttentionItemID {
        .stop(EpisodeKey(origin: .runtime("launch-resume:" + sessionID), episodeToken: paneID.uuidString))
    }

    /// The deadline of the resume typed at launch into `paneID` at `since`
    /// passed; a later one is not this one. With the agent in front of the
    /// pane (`isAgentInFront`), the resume took: the resume is forgotten,
    /// and a stop it took over at launch ends, as a run reporting would
    /// end them (`isOfTheLaunchResume`, `isBack`). With the shell or
    /// something else there, it failed.
    ///
    /// The agent in front is the proof because a run's report cannot be
    /// waited for from every provider. Codex queues its `SessionStart`
    /// hook when the session is built and runs it at the first turn
    /// (`codex-rs/core/src/session/turn.rs`, `run_pending_session_start_hooks`),
    /// so a `codex resume` that shows its conversation reports nothing
    /// until the person prompts, which may be never. Claude runs the hook
    /// at launch (`source: resume`), so its run usually reports well
    /// before the deadline; the agent in front covers a hook that was
    /// lost. A resume that failed (no transcript, a bad id) exits to the
    /// shell within seconds, so the agent still there at the deadline is
    /// the conversation on screen, not a failure under way.
    mutating func launchResumeTimedOut(paneID: UUID, since: Date, isAgentInFront: Bool) {
        guard let launch = launchResumes[paneID], launch.since == since else { return }
        guard isAgentInFront else {
            failLaunchResume(launch)
            return
        }
        launchResumeTook(launch)
    }

    /// The launch resume brought its conversation back with no run to say
    /// so: it is forgotten, and a stop it took over at launch ends.
    private mutating func launchResumeTook(_ launch: LaunchResume) {
        launchResumes[launch.paneID] = nil
        for itemID in stops(inPane: launch.paneID, provider: launch.provider, sessionID: launch.sessionID) {
            records[itemID] = nil
        }
    }

    /// The failed launch resume as a stop the list keeps: its
    /// session and folder are what "Resume Same Conversation" and "Start
    /// New Conversation" use, as for any stop.
    private mutating func failLaunchResume(_ launch: LaunchResume) {
        launchResumes[launch.paneID] = nil
        let itemID = Self.launchResumeItemID(paneID: launch.paneID, sessionID: launch.sessionID)
        // The stop the launch took over (`markResumingAtLaunch`) is this
        // one now: one stop of the conversation in the pane, not two.
        for other in stops(inPane: launch.paneID, provider: launch.provider, sessionID: launch.sessionID) {
            records[other] = nil
        }
        guard !dismissed.contains(itemID) else { return }
        records[itemID] = Record(
            itemID: itemID,
            runtimeID: "launch-resume:" + launch.sessionID,
            provider: launch.provider,
            paneID: launch.paneID,
            conversation: nil,
            sessionID: launch.sessionID,
            cwd: launch.cwd,
            turnID: nil,
            reason: .notResumedAtLaunch,
            stoppedAt: launch.since,
            resume: .failed
        )
    }

    /// Whether `runtime` is a run of the session a launch resume was typed
    /// for, reported after it was typed: the conversation back, or stopped
    /// in its own right, which the run's error lists as a stop.
    private static func isOfTheLaunchResume(_ launch: LaunchResume, _ runtime: RuntimeFact) -> Bool {
        runtime.provider == launch.provider
            && runtime.sessionID == launch.sessionID
            && runtime.state != .unknown
            && runtime.updatedAt > launch.since
    }

    /// The deadline of the resume that started at `since` passed. A later
    /// resume of the same stop is not this one. With the agent in front of
    /// the stop's pane, the conversation is back and the stop ends, for the
    /// reason `launchResumeTimedOut` gives: a Codex resume reports nothing
    /// until its first prompt. Its old run may still say error; the stop
    /// is not made again from it (`dismissed`). Otherwise the resume
    /// failed, which the stop's bar says.
    mutating func resumeTimedOut(_ itemID: AttentionItemID, since: Date, isAgentInFront: Bool) {
        guard case let .resuming(started, _) = records[itemID]?.resume, started == since else { return }
        if isAgentInFront {
            dismiss(itemID)
        } else {
            records[itemID]?.resume = .failed
        }
    }

    /// How long a resume's command runs, at most, when it fails: the agent
    /// prints why and exits (no transcript, a bad session id, a crash on
    /// load) within seconds, npm's `node` start included. One that ran
    /// longer showed its conversation, which the person then quit.
    static let failedResumeRunTime: TimeInterval = 10

    /// What a resume's command coming back to the shell made of it.
    enum ResumeCommandEnd: Equatable, Sendable {
        /// Back within `failedResumeRunTime`: the resume failed, and this
        /// stop says so.
        case failed(AttentionItemID)
        /// Back after it: the conversation was on screen, and the resume
        /// ended as one that took (`resumeTimedOut` with the agent in
        /// front); the stop, or the launch resume's clock, is this one.
        case cameBack(AttentionItemID)

        var itemID: AttentionItemID {
            switch self {
            case let .failed(itemID), let .cameBack(itemID): itemID
            }
        }
    }

    /// The shell of `paneID` is back at its prompt from a command that
    /// began at `startedAt` and ran for `runTime`: the resume typed there
    /// before that, and still waiting, is over.
    ///
    /// Back within `failedResumeRunTime`, it failed: the agent printed why
    /// and exited, so no run of the conversation reported its start, and
    /// nothing else would end the wait before its deadline. Whatever the
    /// exit code: the conversation is confirmed back by its run or its time
    /// on screen, never by the command's exit. Back later, the conversation
    /// was on screen and the person quit it: a Codex resume reports nothing
    /// until its first prompt (`launchResumeTimedOut`), so a run of it may
    /// never have said it was back, and a resume that came back is not a
    /// stop. A command that began before the resume was typed is an
    /// earlier one. Returns what came of the resume; `nil` when none waited.
    mutating func resumeCommandFinished(inPane paneID: UUID, startedAt: Date, runTime: TimeInterval) -> ResumeCommandEnd? {
        let isFailure = runTime < Self.failedResumeRunTime
        if let launch = launchResumes[paneID], startedAt >= launch.since {
            let itemID = Self.launchResumeItemID(paneID: paneID, sessionID: launch.sessionID)
            if isFailure {
                failLaunchResume(launch)
                return .failed(itemID)
            }
            launchResumeTook(launch)
            return .cameBack(itemID)
        }
        for (itemID, record) in records where record.paneID == paneID {
            guard case let .resuming(since, _) = record.resume, startedAt >= since else { continue }
            if isFailure {
                records[itemID]?.resume = .failed
                return .failed(itemID)
            }
            dismiss(itemID)
            return .cameBack(itemID)
        }
        return nil
    }

    /// Whether `runtime` is the stopped conversation active again: the same
    /// run out of its error, or another run of the same conversation (the
    /// resume starts one) that reported after the stop. A run that ended
    /// (`.unknown`) is not active. After, not in the same second: a resume
    /// takes the person longer, and a record written with the stop is an
    /// old one.
    static func isBack(_ record: Record, as runtime: RuntimeFact) -> Bool {
        guard isSameRun(record, as: runtime) else { return false }
        switch runtime.state {
        case .error, .unknown: return false
        case .idle, .running, .compacting, .needsInput, .finished: break
        }
        // The same run is back whenever it reported; another run of the
        // conversation only when it reported after the stop.
        return runtime.runtimeID == record.runtimeID || runtime.updatedAt > record.stoppedAt
    }

    /// Whether `runtime` stopping again is the stop `record` is of: the same
    /// run, or the same conversation by its key or its session.
    private static func isSameRun(_ record: Record, as runtime: RuntimeFact) -> Bool {
        guard runtime.provider == record.provider else { return false }
        if runtime.runtimeID == record.runtimeID {
            return true
        }
        if let conversation = record.conversation, !conversation.isFallback, runtime.conversation == conversation {
            return true
        }
        if let sessionID = record.sessionID, runtime.sessionID == sessionID {
            return true
        }
        return false
    }

    /// The stop item a run in error lists, as the attention list keys it.
    static func itemID(of runtime: RuntimeFact) -> AttentionItemID {
        .stop(EpisodeKey(origin: .runtime(runtime.runtimeID), episodeToken: runtime.episodeToken))
    }
}
