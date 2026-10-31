// ApprovalLedger.swift
// Weir — every approval request the app has seen, kept until its episode ends.

import Foundation
import Observation

/// Every request the broker has shown as pending, and where each one stands.
///
/// The pending list says only which requests are still open. A request that
/// leaves it may have been answered, handed to the TUI, withdrawn, or
/// expired, and the card and the attention list need to know which. The
/// ledger keeps each request past that point, settled by what the broker
/// reports, and lets it go only when the turn it belonged to is over.
@MainActor
@Observable
final class ApprovalLedger {
    struct Entry: Equatable {
        let presentation: ApprovalPresentation
        var state: ApprovalRequestState
        /// When Weir first saw the request pending, on the wall clock. A
        /// prompt its run takes after this moment has started another turn,
        /// so the turn the request was asked in is over even when the run
        /// never reported its end (`ApprovalPresentationStore.turnHasEnded`).
        /// Kept with the entry because that evidence is about this request,
        /// and the entry outlives the request's place in the pending list.
        let firstSeenAt: Date
        /// The person's decision was refused because another answer (the
        /// TUI, the menu bar, a second card) reached the broker first. The
        /// card says so instead of offering a retry that cannot succeed.
        var isAnsweredElsewhere = false
        /// The broker has told us how the request ended, or that it has no
        /// record of it. Kept apart from the state because a request our
        /// own clock timed out reads the same as one the broker expired,
        /// and only the first is still worth asking the broker about.
        var hasBrokerOutcome = false
        /// The episode of the agent's wait at its prompt that is this
        /// request seen from the hook: the first wait its run showed while
        /// the request was the run's oldest listed one
        /// (`ApprovalPresentationStore.noteWaitEpisodes`). Only that wait is
        /// the request's own; a wait the run starts later is a new one
        /// (`AttentionQueueReducer`).
        var waitEpisodeToken: String?
        /// The runs the request belongs to, by runtime ID, as the store first
        /// found them (`ApprovalPresentationStore.bindRequestsToRuns`). For a
        /// request that names its run, that run, once it was listed, so its
        /// going away reads as gone rather than not listed yet. For one that
        /// names none, the runs of its conversation that were in a turn then:
        /// one when that settles it, several when it does not. `nil` until
        /// then. A conversation resumed in a second run keeps its session
        /// ID, so only the runs noted here may end the request: a prompt in
        /// another run of the same conversation says nothing about its turn.
        var runtimeIDs: Set<String>?

        /// Whether a card showing this request stays open. It does while
        /// the request is open, being sent, with the TUI, or timed out,
        /// and while it tells the person their answer lost to another one;
        /// it closes once the request was answered, withdrawn, or its
        /// result is lost.
        var holdsCardOpen: Bool {
            switch state {
            case .held, .sending, .sendFailed, .handedToTerminal, .timedOut: true
            case .answered: isAnsweredElsewhere
            case .withdrawn, .unknownResult: false
            }
        }
    }

    private(set) var entries: [ApprovalKey: Entry] = [:]

    /// The service epoch of the last pending list the ledger read, or nil
    /// before the first one and after `serviceDidStop`. Until it has read
    /// one, the ledger cannot say that a request it lacks has ended: after a
    /// launch, the running service may still hold a request that a history
    /// row names (`NotificationLiveStatus.ofRequest`). `serviceDidStop`
    /// makes it nil again rather than "read": the service may come back in
    /// the same epoch, still holding the request.
    private(set) var epoch: UUID?

    /// The same entries by the string ID the cards and rows use, so a lookup
    /// does not rebuild every key's string. Kept in step by the methods that
    /// add or remove entries.
    @ObservationIgnored private var keysByID: [String: ApprovalKey] = [:]
    /// Requests whose episode ended in this epoch. A projection fetched
    /// before the episode ended can still list one as pending; it must not
    /// bring it back.
    @ObservationIgnored private var endedKeys: Set<ApprovalKey> = []

    /// Requests whose ending the broker has not yet told us: the projection
    /// looks these up when they leave the pending list.
    var trackedIDs: Set<String> {
        Set(entries.values
            .filter { !$0.hasBrokerOutcome && $0.state.isAwaitingBrokerOutcome }
            .map(\.presentation.id))
    }

    func entry(for approval: ApprovalPresentation) -> Entry? {
        entries[approval.key]
    }

    func entry(id: String) -> Entry? {
        keysByID[id].flatMap { entries[$0] }
    }

    /// Whether the request's episode already ended in this epoch, so a
    /// projection that still lists it as pending is stale.
    func hasEnded(_ approval: ApprovalPresentation) -> Bool {
        endedKeys.contains(approval.key)
    }

    /// Takes the pending list, read at `seenAt`. A new request starts held
    /// and is first seen then; one already known keeps its state and its
    /// first sight, because leaving and re-reading the list is not news.
    /// Entries from another epoch go through `outliveEpoch`: the service
    /// restarted, and its new broker knows nothing about them.
    func observe(pending: [ApprovalPresentation], epoch: UUID, seenAt: Date = Date()) {
        // Written only when it changes: every pending list passes through
        // here, and each write would wake the history's observers.
        // Carried over once per reading of an epoch, not on every list: an
        // old entry stays until its turn ends, and each pass over it would
        // be another write.
        if self.epoch != epoch {
            self.epoch = epoch
            outliveEpoch(for: epoch)
        }
        for approval in pending where entries[approval.key] == nil && !endedKeys.contains(approval.key) {
            entries[approval.key] = Entry(presentation: approval, state: .held, firstSeenAt: seenAt)
            keysByID[approval.id] = approval.key
        }
        // Projections arrive in order from one loop, so a key that is not
        // pending now never comes back as pending; only the ended keys a
        // stale projection could still list need remembering.
        let pendingKeys = Set(pending.map(\.key))
        endedKeys.formIntersection(pendingKeys)
    }

    /// Applies how the broker says a request ended.
    func settle(id: String, by terminal: BrokerTerminal, now: SuspendingClock.Instant) {
        record(.brokerTerminal(terminal), for: id, now: now)
    }

    /// The broker has no record of the request any more.
    func markMissing(id: String, now: SuspendingClock.Instant) {
        record(.brokerRecordMissing, for: id, now: now)
    }

    /// Moves a request by `event`. Does nothing when the event does not
    /// apply to its state, or the request is unknown.
    func record(_ event: ApprovalEvent, for id: String, now: SuspendingClock.Instant) {
        guard let current = entry(id: id) else { return }
        let key = current.presentation.key
        switch event {
        case .brokerTerminal, .brokerRecordMissing:
            // A broker speaks only for its own epoch. The first projection of
            // a new one is computed from tracked IDs read before it came in,
            // so it reports every old key as missing; the new broker never
            // knew them, which says nothing about how they ended
            // (`outliveEpoch`). With no epoch read (the service stopped), a
            // refused send can still settle its request.
            guard epoch == nil || key.epoch == epoch else { return }
            // Even when the state stays (a request our clock timed out that
            // the broker then expired), the broker has had its say.
            entries[key]?.hasBrokerOutcome = true
        case .userDecided, .paneBecameVisible, .sendSucceeded, .sendFailed, .deadlinePassed:
            break
        }
        guard let next = ApprovalRequestState.transition(current.state, event, now: now) else { return }
        entries[key]?.state = next
    }

    /// Notes the wait that is the request's own (`Entry.waitEpisodeToken`).
    /// The first one stays: the run's next wait is another.
    func noteWait(id: String, episodeToken: String) {
        guard let key = keysByID[id], entries[key]?.waitEpisodeToken == nil else { return }
        entries[key]?.waitEpisodeToken = episodeToken
    }

    /// Notes the runs that could have asked the request
    /// (`Entry.runtimeIDs`). The first finding stays: a run that starts in
    /// the same conversation later did not ask it.
    func bindRuns(id: String, runtimeIDs: Set<String>) {
        guard !runtimeIDs.isEmpty, let key = keysByID[id], entries[key]?.runtimeIDs == nil else { return }
        entries[key]?.runtimeIDs = runtimeIDs
    }

    /// Marks that the person's decision lost to another answer.
    func markAnsweredElsewhere(id: String) {
        guard let key = keysByID[id] else { return }
        entries[key]?.isAnsweredElsewhere = true
    }

    /// Carries the entries of an earlier epoch into `epoch`'s.
    ///
    /// A new epoch means a new service process, whose broker has no record of
    /// the old one's requests, so its pending list not naming one says
    /// nothing about how that request ended. The agent's wait does not end
    /// with the service. A request handed to the TUI is the agent's own
    /// prompt's, and so is one Weir's time ran out on. One the old broker
    /// still held, or was sending a decision for, went to that prompt as
    /// well: the hook helper answers nothing when it loses the service, and
    /// no answer leaves the request to the agent's own permission flow. We
    /// cannot say whether a decision in flight landed first, so those are
    /// marked as having lost their result (`unknownResult`) and close their card,
    /// whose buttons the new broker would refuse.
    ///
    /// So we drop only what the old broker settled for good (answered or
    /// withdrawn), and keep every other request waiting until the evidence
    /// that ends any request left to the agent's prompt: its turn ends, its
    /// run goes away, or its pane does (`ApprovalPresentationStore
    /// .endFinishedEpisodes`). Each kept entry counts as having had its
    /// broker outcome, so the new broker is never asked about a key it
    /// cannot know, and `record` ignores what it reports about one. The
    /// ended keys of the old epoch go: no projection of the new one can
    /// list them. Each write happens only when it changes something, since
    /// every write wakes the history's observers.
    private func outliveEpoch(for epoch: UUID) {
        for (key, entry) in entries where key.epoch != epoch {
            if entry.state.hasLeftTheQueue {
                entries[key] = nil
                keysByID[entry.presentation.id] = nil
                continue
            }
            if entry.state.isHeldByWeir {
                // Held, sending, or after a failed send.
                entries[key]?.state = .unknownResult
            }
            if !entry.hasBrokerOutcome {
                entries[key]?.hasBrokerOutcome = true
            }
        }
        if endedKeys.contains(where: { $0.epoch != epoch }) {
            endedKeys = endedKeys.filter { $0.epoch == epoch }
        }
    }

    /// Lets a request go once the turn it belonged to is over.
    func endEpisode(id: String) {
        guard let key = keysByID[id] else { return }
        entries[key] = nil
        keysByID[id] = nil
        endedKeys.insert(key)
    }

    /// The service stopped being ready (`ApprovalPresentationStore.stop`).
    /// We keep every entry and forget only that a pending list was read.
    ///
    /// A readiness check can fail once while the service runs on, and the
    /// next one reconnects to the same epoch. Nothing reports the TUI's
    /// answer to a request handed to it (`ApprovalEvent`), and the
    /// projection rebuilds only pending requests, so a delegated request
    /// dropped here could never be rebuilt. Its history row would then read
    /// as resolved while the TUI still waits, although delegating a request
    /// to the agent's prompt is not answering it. We do not instead treat
    /// an absent request as waiting until something shows it ended, because
    /// a row of an earlier launch, which the ledger never held, must still
    /// retire once a pending list is read. Nor do we fall back to the run's
    /// state, which would mix up two requests of one run.
    ///
    /// A held request is kept too, as a dropped subscription keeps it. The
    /// broker can expire or evict it during the outage, and only a request
    /// the ledger still tracks is looked up on reconnect, so dropping it
    /// would read that ending as an answer. Kept, it is looked up and turns
    /// timed out or lost, both of which still wait at the agent's prompt. A
    /// decision in flight is kept because `stop` does not cancel its send,
    /// whose result lands on the entry. The cost is a card whose buttons
    /// fail while the service is down; a failed send says so, and the card
    /// stays open for the person to answer at the prompt instead. Every kept
    /// request leaves with its turn, as it would have without the stop, and
    /// a new epoch carries it over as `outliveEpoch` says.
    ///
    /// `epoch` goes back to nil so that, until the service is read again, a
    /// row the ledger does not hold is not called resolved
    /// (`NotificationLiveStatus.ofRequest`).
    func serviceDidStop() {
        epoch = nil
    }
}

private extension ApprovalRequestState {
    /// Whether the broker can still tell us how the request ended. Once it
    /// has (or has lost the record), there is nothing to look up.
    var isAwaitingBrokerOutcome: Bool {
        switch self {
        case .held, .sending, .sendFailed, .timedOut: true
        case .handedToTerminal, .withdrawn, .unknownResult, .answered: false
        }
    }
}

extension ApprovalPresentation {
    /// The broker's three IDs, as the attention list keys requests.
    var key: ApprovalKey {
        ApprovalKey(epoch: epoch, runID: runID, requestID: requestID)
    }
}
