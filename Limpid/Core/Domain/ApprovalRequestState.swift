// ApprovalRequestState.swift
// Limpid — where one approval or question request stands, and how it moves.

import Foundation

/// The time left on a request, measured against the service's own clock.
///
/// The service reports its deadline and its "now" in milliseconds of its
/// own uptime, so the two are subtracted there and only the difference is
/// carried forward on our clock. We use `SuspendingClock` because the
/// service measures with Rust's `Instant`, which on macOS reads
/// `CLOCK_UPTIME_RAW` and stops while the Mac sleeps; a clock that counted
/// the sleep would show a request as expired that the service still holds.
/// We have not yet checked on a real machine whether the CLIs' own hook
/// timeouts count sleep. If they do, it is the service's clock that has to
/// change, and this one follows it.
struct ServiceDeadline: Equatable, Sendable {
    let deadlineMs: UInt64
    let serviceNowMs: UInt64
    /// When the reading arrived, on our clock.
    let receivedAt: SuspendingClock.Instant

    /// Never negative: a passed deadline is zero, and the broker decides
    /// whether a late decision still counts.
    func remaining(at now: SuspendingClock.Instant) -> Duration {
        let leftAtReceipt = deadlineMs > serviceNowMs ? deadlineMs - serviceNowMs : 0
        let atReceipt = Duration.milliseconds(Int64(clamping: leftAtReceipt))
        let elapsed = receivedAt.duration(to: now)
        let left = atReceipt - max(elapsed, .zero)
        return max(left, .zero)
    }
}

/// How the broker settled a request, read from `approval.get`'s `state`.
///
/// `already_terminal` errors carry only a code and a message, so the store
/// asks `approval.get` again and maps the answer here rather than guessing
/// from the error.
enum BrokerTerminal: Equatable, Sendable {
    case resolved(ApprovalResolution)
    case canceled
    case expired
}

/// Something that happened to a request.
///
/// Nothing here says the TUI answered a request handed to it. No provider
/// reports that: Claude's PermissionRequest carries no tool-use ID to match
/// a later tool hook with, and a denial in its own dialog sends no hook at
/// all. Such a request leaves the ledger when its turn is over instead
/// (`ApprovalPresentationStore.turnHasEnded`), which is not a transition.
enum ApprovalEvent: Equatable, Sendable {
    /// The person chose an answer on the card or in the menu bar.
    case userDecided(ApprovalResolution)
    /// The request's pane became visible, so it goes to the TUI.
    case paneBecameVisible
    case sendSucceeded
    case sendFailed(String)
    case brokerTerminal(BrokerTerminal)
    /// `approval.get` found no record: the broker already evicted it.
    case brokerRecordMissing
    /// The deadline we read from the service has passed on our clock.
    case deadlinePassed
}

/// Where one request stands, from the moment the broker holds it until it
/// leaves the attention list.
///
/// The pending list from the service only says which requests are still
/// open, so a request that leaves it could have been answered, handed to
/// the TUI, timed out, or withdrawn. These states keep the difference,
/// which decides whether the item stays in the list and what its card says.
/// The deadline is not part of the state: it belongs to the request
/// (`ApprovalFact.deadline`), so it survives a send, a failure, and a hand-off,
/// and a fresh reading after sleep replaces it without a transition.
enum ApprovalRequestState: Equatable, Sendable {
    /// The broker holds it and no one has acted.
    case held
    case sending(ApprovalResolution, since: SuspendingClock.Instant)
    /// Delegated to the provider's own prompt, since the moment we learned
    /// it was. Stays in the list, because delegating is not answering, until
    /// the turn it was asked in is over: the run reports the turn's end, or
    /// a later prompt of the run overtakes it. Nothing reports the TUI's
    /// answer itself (`ApprovalEvent`), so no event moves it on.
    case handedToTerminal(since: SuspendingClock.Instant)
    /// The broker expired it, or the deadline we read from it passed. Stays
    /// in the list with its buttons disabled; the person answers again in
    /// the terminal, and the item leaves with its turn as a hand-off does.
    case timedOut
    /// The agent took it back.
    case withdrawn
    /// The broker no longer has a record of it, so we cannot say how it
    /// ended. Kept apart from `withdrawn` so the card does not claim the
    /// agent took it back; the item leaves when its turn is over, as a
    /// hand-off does.
    case unknownResult
    case sendFailed(ApprovalResolution, error: String)
    case answered(ApprovalResolution)

    /// Whether Limpid still holds the request, so it is answered on the
    /// approval card and its time left is Limpid's to show. Once handed to
    /// the terminal, the provider's own prompt keeps its time, which Limpid
    /// cannot read.
    var isHeldByLimpid: Bool {
        switch self {
        case .held, .sending, .sendFailed: true
        case .handedToTerminal, .timedOut, .withdrawn, .unknownResult, .answered: false
        }
    }

    /// Whether the request now waits at the provider's own prompt and
    /// nowhere else: handed to it, or left there when Limpid's time ran
    /// out. The person answers it at that prompt, and Limpid can only take
    /// them to its pane.
    var isLeftToTerminal: Bool {
        switch self {
        case .handedToTerminal, .timedOut: true
        case .held, .sending, .sendFailed, .withdrawn, .unknownResult, .answered: false
        }
    }

    /// Whether the card or the menu bar may send a decision now. A failed
    /// send can be retried; anything in flight or settled cannot.
    var acceptsDecision: Bool {
        switch self {
        case .held, .sendFailed: true
        case .sending, .handedToTerminal, .timedOut, .withdrawn, .unknownResult, .answered: false
        }
    }

    /// Whether a delivered banner for the request still leads somewhere
    /// useful: to the card while it is open, or to the pane while the TUI
    /// has it. A timed-out, settled, or lost request's banner is taken
    /// back, so Notification Center never offers an answer that cannot be
    /// given.
    var keepsBanner: Bool {
        switch self {
        case .held, .sending, .sendFailed, .handedToTerminal: true
        case .timedOut, .withdrawn, .unknownResult, .answered: false
        }
    }

    /// Whether the request has left the attention list for good. A timed-out
    /// request, one handed to the TUI, and one with an unknown result stay
    /// until the broker settles them or the ledger lets them go with their
    /// turn.
    var hasLeftTheQueue: Bool {
        switch self {
        case .withdrawn, .answered: true
        case .held, .sending, .handedToTerminal, .timedOut, .unknownResult, .sendFailed: false
        }
    }

    /// The state after `event`, or `nil` when the event does not apply and
    /// the state stays as it is.
    ///
    /// The broker is the authority: whatever it reports settles the request,
    /// even while our own send is in flight and even after our clock called
    /// it timed out. A visible pane does not hand a request to the TUI while
    /// a send is in flight, so the person's answer and the delegation never
    /// race. A request whose send failed is open again, but nothing hands it
    /// over by itself: the failure stays for the person to see and retry,
    /// and resending on every change would retry a broken send forever.
    static func transition(
        _ state: Self,
        _ event: ApprovalEvent,
        now: SuspendingClock.Instant
    ) -> Self? {
        switch state {
        case .held, .sendFailed:
            fromOpen(event, now: now)
        case let .sending(resolution, _):
            fromSending(resolution, event: event, now: now)
        case .handedToTerminal:
            // The broker already settled it as delegated, and the TUI's
            // answer is never reported (`ApprovalEvent`).
            nil
        case .timedOut:
            fromTimedOut(event, now: now)
        case .withdrawn, .unknownResult, .answered:
            nil
        }
    }

    /// `held` and `sendFailed` accept the same events: a failed send left
    /// the request open, as if nothing had been sent.
    private static func fromOpen(_ event: ApprovalEvent, now: SuspendingClock.Instant) -> Self? {
        switch event {
        case let .userDecided(resolution): .sending(resolution, since: now)
        case .paneBecameVisible: .sending(.delegate, since: now)
        case let .brokerTerminal(terminal): settled(by: terminal, now: now)
        case .brokerRecordMissing: .unknownResult
        case .deadlinePassed: .timedOut
        case .sendSucceeded, .sendFailed: nil
        }
    }

    private static func fromSending(
        _ resolution: ApprovalResolution,
        event: ApprovalEvent,
        now: SuspendingClock.Instant
    ) -> Self? {
        switch event {
        case .sendSucceeded:
            if resolution == .delegate {
                .handedToTerminal(since: now)
            } else {
                .answered(resolution)
            }
        case let .sendFailed(error):
            .sendFailed(resolution, error: error)
        case let .brokerTerminal(terminal):
            settled(by: terminal, now: now)
        case .brokerRecordMissing:
            .unknownResult
        // The broker decides whether a send that crosses the deadline
        // counts; we wait for its answer rather than declaring a timeout.
        case .deadlinePassed, .userDecided, .paneBecameVisible:
            nil
        }
    }

    /// A timed-out request can still be answered in the terminal, which is
    /// where the person is told to answer it. Our own timeout is only an
    /// estimate, so a withdrawal or an answer the broker reports still wins.
    private static func fromTimedOut(_ event: ApprovalEvent, now: SuspendingClock.Instant) -> Self? {
        switch event {
        case .brokerRecordMissing: .unknownResult
        case .brokerTerminal(.expired): nil
        case let .brokerTerminal(terminal): settled(by: terminal, now: now)
        case .userDecided, .paneBecameVisible, .sendSucceeded, .sendFailed, .deadlinePassed: nil
        }
    }

    private static func settled(by terminal: BrokerTerminal, now: SuspendingClock.Instant) -> Self {
        switch terminal {
        case .resolved(.delegate): .handedToTerminal(since: now)
        case let .resolved(resolution): .answered(resolution)
        case .canceled: .withdrawn
        case .expired: .timedOut
        }
    }
}
