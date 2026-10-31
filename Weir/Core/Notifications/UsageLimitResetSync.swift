// UsageLimitResetSync.swift
// Weir — keeps a notification pending for when each provider's usage limit resets.
// Same pattern as `DockBadgeSync` (observe the sources and push the derived value out), plus the
// requests made from a stop and the moments a reset passes, which the views redraw at.

import Foundation

/// One notification pending per provider at its usage limit, set for when
/// the limit resets: for every limit while the person asked for that in
/// General (off by default), and for one they asked for from its stop
/// with "Notify When It Resets". Scheduled with the system rather than
/// kept on a timer here, so it arrives on time across sleep and while Weir
/// is busy; withdrawn when the limit goes before its time (the agent went
/// on, or the setting went off). The one timer here is for the views: what
/// a stop says changes as its reset passes (`resetPassedAt`).
///
/// A request lives as long as Weir runs: a relaunch withdraws what is
/// pending, and the stop offers the notice again.
@MainActor
@Observable
final class UsageLimitResetSync {
    @ObservationIgnored private let limits: @MainActor () -> UsageLimits
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let schedule: @MainActor (AgentKind, Date) -> Void
    @ObservationIgnored private let cancel: @MainActor (AgentKind) -> Void
    /// What is pending now, so only what changed is scheduled again.
    @ObservationIgnored private(set) var pending: [AgentKind: Date] = [:]
    /// The providers the person asked to hear of from a stop, each
    /// with the release it was asked for. It follows the release while the
    /// provider stays held (a stop replaced before it), and ends once that
    /// release has come: a limit met later is another one, and offers its
    /// own notice. Turning the setting on later does not end it.
    private(set) var requested: [AgentKind: Date] = [:]
    /// When a reset last passed: written a second past each reset still
    /// ahead (`UsageLimits.changeTimes`), when what a stop says and offers
    /// changes with no event to say so. The decision bar, the menu, and the
    /// sidebar read it to be drawn again then; a change of the sources
    /// redraws them on its own.
    private(set) var resetPassedAt: Date
    /// The next time a reset passes, which the timer waits for.
    @ObservationIgnored private(set) var nextCheck: Date?
    @ObservationIgnored private var wake: Task<Void, Never>?

    init(
        limits: @escaping @MainActor () -> UsageLimits,
        isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        schedule: @escaping @MainActor (AgentKind, Date) -> Void,
        cancel: @escaping @MainActor (AgentKind) -> Void
    ) {
        self.limits = limits
        self.isEnabled = isEnabled
        self.now = now
        self.schedule = schedule
        self.cancel = cancel
        resetPassedAt = now()
        // What an earlier launch left pending is not known here, and the
        // limit it was for may have ended while Weir was not running:
        // withdrawn first, then scheduled again if it still holds.
        for provider in AgentKind.allCases {
            cancel(provider)
        }
        refresh()
        // `requested` changes only in `refresh` and `requestIfOffered`, which
        // refreshes itself.
        observeRepeatedly { [weak self] in
            _ = self?.limits()
            _ = self?.isEnabled()
        } onChange: { [weak self] in
            self?.refresh()
        }
    }

    /// What `item` offers at `now` (`UsageLimitResetNotice`), as the bar
    /// and the menu show it.
    func notice(for item: AttentionItem, now: Date) -> UsageLimitResetNotice? {
        UsageLimitResetNotice.of(item, in: limits(), isRequested: { isNoticeRequested(for: $0, now: now) }, now: now)
    }

    /// "Notify When It Resets" on `item`, asked again at the press as the
    /// bar asked. Returns whether it was taken.
    @discardableResult
    func requestIfOffered(_ item: AttentionItem, now: Date) -> Bool {
        guard notice(for: item, now: now) == .offered, let provider = item.subject.provider,
              let release = limits().releaseAt(of: provider, now: now)
        else { return false }
        requested[provider] = release
        refresh()
        return true
    }

    /// Whether `provider`'s reset is notified at `now`: the setting asks for
    /// every one, or the person asked for this one.
    func isNoticeRequested(for provider: AgentKind, now: Date) -> Bool {
        isEnabled() || requested[provider].map { $0 > now } == true
    }

    func refresh() {
        let limits = limits()
        let now = now()
        // A request follows its provider's release while still held, and
        // ends once that release has come or the limit has gone.
        var next: [AgentKind: Date] = [:]
        for (provider, asked) in requested where asked > now {
            next[provider] = limits.releaseAt(of: provider, now: now)
        }
        if next != requested {
            requested = next
        }
        let wanted = limits.pendingResetNotifications(isEnabled: isEnabled(), requested: Set(requested.keys), now: now)
        // One whose time has come is the system's to deliver, perhaps late
        // after sleep: withdrawing it then would lose it.
        for (provider, date) in pending where wanted[provider] == nil && date > now {
            cancel(provider)
        }
        for (provider, date) in wanted where pending[provider] != date {
            schedule(provider, date)
        }
        pending = wanted
        scheduleCheck(after: now, in: limits)
    }

    /// Reads the limits again at their next change. A wait on the
    /// continuous clock passes during sleep, so a reset met then is read on
    /// waking.
    private func scheduleCheck(after now: Date, in limits: UsageLimits) {
        let next = limits.changeTimes(after: now).first
        guard next != nextCheck else { return }
        wake?.cancel()
        nextCheck = next
        guard let next else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled, let self else { return }
            nextCheck = nil
            resetPassedAt = self.now()
            refresh()
        }
    }
}
