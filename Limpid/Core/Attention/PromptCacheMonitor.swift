// PromptCacheMonitor.swift
// Limpid — the clock the prompt cache marks are evaluated against, and what
// the user has already done about each expiry.
//
// A window changes what it shows at two instants: when the warning lead is
// left (a fifth of the window, at most five minutes), and when it expires. Ticking every second to notice them would
// re-render every tab row sixty times a minute for a change that happens
// twice an hour, so we keep one timer aimed at the soonest of those
// instants across all windows and move `now` only when it fires or the
// windows change.

import Foundation

@MainActor
@Observable
final class PromptCacheMonitor {
    /// One expiry. Keyed by the window's anchor rather than by the run
    /// alone, so the same expiry stays answered and a later turn's expiry
    /// asks again.
    struct ExpiryKey: Hashable {
        let runtimeID: String
        let observedAt: Date
    }

    /// The instant every status is evaluated at. Views read this rather than
    /// the wall clock so they re-render exactly when a status can change.
    private(set) var now: Date
    // Both sets below live in memory only, deliberately for now: a relaunch
    // forgets them, so an expiry answered before it shows its red clock
    // again and may open its panel by itself once more.

    /// Expiries the user answered from the clock's panel. Their clocks go
    /// away everywhere.
    private(set) var answeredExpiries: Set<ExpiryKey> = []
    /// Expiries whose panel has been on screen, opened by the user or by
    /// itself. The panel opens by itself once per expiry: after the user
    /// has seen it, opening it again unasked would only be in the way.
    /// Not observed, because no view draws anything from it.
    @ObservationIgnored private(set) var presentedExpiries: Set<ExpiryKey> = []

    /// Where the pending timer is aimed, for tests and diagnostics. `nil`
    /// when no window has a transition left.
    @ObservationIgnored private(set) var nextFire: Date?
    @ObservationIgnored private var windows: [String: AgentCacheWindow] = [:]
    /// The single pending wake-up. It captures `self` weakly, so a monitor
    /// that goes away leaves at most one sleeping task that finds nothing to
    /// do when it wakes; there is no `deinit` cleanup to perform.
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
        now = clock()
    }

    /// Replaces the windows, keyed by runtime id, and re-aims the timer.
    /// Called with every projection pass that changed a runtime.
    func update(windows: [String: AgentCacheWindow]) {
        guard self.windows != windows else { return }
        self.windows = windows
        // What was done about windows that are gone can never apply again;
        // a new turn moves `observedAt`, so the key would not match it
        // anyway.
        let live = Set(windows.map { ExpiryKey(runtimeID: $0.key, observedAt: $0.value.observedAt) })
        let answered = answeredExpiries.intersection(live)
        if answered != answeredExpiries {
            answeredExpiries = answered
        }
        presentedExpiries.formIntersection(live)
        advance()
    }

    func isAnswered(runtimeID: String, window: AgentCacheWindow) -> Bool {
        answeredExpiries.contains(ExpiryKey(runtimeID: runtimeID, observedAt: window.observedAt))
    }

    func markAnswered(runtimeID: String, window: AgentCacheWindow) {
        answeredExpiries.insert(ExpiryKey(runtimeID: runtimeID, observedAt: window.observedAt))
    }

    func hasPresented(runtimeID: String, window: AgentCacheWindow) -> Bool {
        presentedExpiries.contains(ExpiryKey(runtimeID: runtimeID, observedAt: window.observedAt))
    }

    func markPresented(runtimeID: String, window: AgentCacheWindow) {
        presentedExpiries.insert(ExpiryKey(runtimeID: runtimeID, observedAt: window.observedAt))
    }

    /// Moves `now` to the wall clock and aims the timer at the next
    /// transition. Internal so tests can stand in for the timer firing.
    func advance() {
        now = clock()
        timer?.cancel()
        guard let next = PromptCacheStatus.nextTransition(of: Array(windows.values), after: now) else {
            nextFire = nil
            timer = nil
            return
        }
        nextFire = next
        // Half a second late on purpose: waking a hair early would evaluate
        // the old status and aim at the same instant again.
        let delay = max(0, next.timeIntervalSince(clock())) + 0.5
        timer = Task { @MainActor [weak self] in
            // The continuous clock keeps counting while the Mac sleeps, so a
            // window that expired during sleep is noticed on wake.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
