// UsageLimitResetRequestTests.swift
// Weir — "Notify When It Resets" on a usage limit stop: when it is offered, what it and the setting
// schedule and withdraw, and the menu that offers it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct UsageLimitResetRequestTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let reset = now.addingTimeInterval(3600)

    private static func stop(_ limit: UsageLimit?, provider: AgentKind = .claude, runtime: String = "r") -> AttentionItem {
        AttentionItem.testUsageLimitStop(limit, provider: provider, runtime: runtime, arrivedAt: now)
    }

    /// The limits of one stop per provider, each with the reset given.
    private static func limits(_ resets: [AgentKind: Date?]) -> UsageLimits {
        UsageLimits(items: resets.map { provider, reset in
            stop(UsageLimit(resetAt: reset), provider: provider, runtime: provider.rawValue)
        })
    }

    private final class Recorder {
        var scheduled: [(AgentKind, Date)] = []
        var cancelled: [AgentKind] = []
    }

    private static func sync(
        _ items: Recorded<[AttentionItem]>,
        isEnabled: Bool = false,
        now: Recorded<Date> = Recorded(now),
        recorder: Recorder
    ) -> UsageLimitResetSync {
        UsageLimitResetSync(
            limits: { UsageLimits(items: items.value) },
            isEnabled: { isEnabled },
            now: { now.value },
            schedule: { recorder.scheduled.append(($0, $1)) },
            cancel: { recorder.cancelled.append($0) }
        )
    }

    // MARK: - When it is offered

    @Test func notice_isOfferedOnlyWhileTheProviderIsHeldWithATimeAhead() {
        let never: (AgentKind) -> Bool = { _ in false }
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let limits = UsageLimits(items: [limited])
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: never, now: Self.now) == .offered)
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: { _ in true }, now: Self.now) == .requested)
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: never, now: Self.reset) == nil)
        let unknown = Self.stop(UsageLimit())
        #expect(UsageLimitResetNotice.of(unknown, in: UsageLimits(items: [unknown]), isRequested: never, now: Self.now) == nil)
        let exited = Self.stop(nil)
        #expect(UsageLimitResetNotice.of(exited, in: UsageLimits(items: [exited]), isRequested: never, now: Self.now) == nil)
    }

    /// A five-hour stop whose reset passed still offers the notice while a
    /// weekly limit holds the provider: resuming would meet that one.
    @Test func notice_followsTheProvidersRelease_notTheStopsOwnReset() {
        let passed = Self.stop(UsageLimit(resetAt: Self.now.addingTimeInterval(-60), window: "five_hour"), runtime: "a")
        let weekly = Self.stop(UsageLimit(resetAt: Self.reset, window: "seven_day"), runtime: "b")
        let limits = UsageLimits(items: [passed, weekly])
        #expect(UsageLimitResetNotice.of(passed, in: limits, isRequested: { _ in false }, now: Self.now) == .offered)
        #expect(limits.releaseAt(of: .claude, now: Self.now) == Self.reset)
    }

    /// A notification is pending for each provider the person asked one for,
    /// or for every provider with the setting on, and only for a reset ahead.
    @Test func pending_onlyForTheProvidersAskedOf_andOnlyForAFutureReset() {
        let limits = UsageLimits(items: [
            Self.stop(UsageLimit(resetAt: Self.reset), provider: .claude, runtime: "a"),
            Self.stop(UsageLimit(resetAt: Self.reset.addingTimeInterval(60)), provider: .codex, runtime: "b")
        ])
        #expect(limits.pendingResetNotifications(isEnabled: false, requested: [], now: Self.now).isEmpty)
        #expect(limits.pendingResetNotifications(isEnabled: false, requested: [.claude], now: Self.now) == [.claude: Self.reset])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.now).count == 2)

        let unknown = Self.limits([.claude: Self.reset, .codex: nil])
        #expect(unknown.pendingResetNotifications(isEnabled: true, now: Self.now) == [.claude: Self.reset])
        #expect(unknown.pendingResetNotifications(isEnabled: true, now: Self.reset).isEmpty)
    }

    // MARK: - What it schedules

    @Test func request_schedulesTheResetWithTheSettingOff() {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), recorder: recorder)
        #expect(recorder.scheduled.isEmpty)
        #expect(sync.notice(for: limited, now: Self.now) == .offered)

        #expect(sync.requestIfOffered(limited, now: Self.now))
        #expect(recorder.scheduled.map(\.1) == [Self.reset])
        #expect(sync.notice(for: limited, now: Self.now) == .requested)
        #expect(!sync.requestIfOffered(limited, now: Self.now), "asked once")
    }

    @Test func request_isRefusedForAStopThatOffersNoNotice() {
        let recorder = Recorder()
        let exited = Self.stop(nil)
        let sync = Self.sync(Recorded([exited]), recorder: recorder)
        #expect(!sync.requestIfOffered(exited, now: Self.now))
        #expect(sync.requested.isEmpty)
    }

    @Test func request_withTheSettingOnIsAlreadyRequested() {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), isEnabled: true, recorder: recorder)
        #expect(sync.isNoticeRequested(for: .claude, now: Self.now))
        #expect(sync.notice(for: limited, now: Self.now) == .requested)
        #expect(recorder.scheduled.map(\.1) == [Self.reset])
    }

    @Test func request_leavesTheOtherProviderAlone() {
        let recorder = Recorder()
        let claude = Self.stop(UsageLimit(resetAt: Self.reset), provider: .claude, runtime: "a")
        let codex = Self.stop(UsageLimit(resetAt: Self.reset), provider: .codex, runtime: "b")
        let items = Recorded([claude, codex])
        let sync = Self.sync(items, recorder: recorder)
        sync.requestIfOffered(claude, now: Self.now)
        #expect(recorder.scheduled.map(\.0) == [.claude])
        #expect(sync.notice(for: codex, now: Self.now) == .offered)

        items.value = [claude]
        sync.refresh()
        #expect(sync.requested.keys.sorted { $0.rawValue < $1.rawValue } == [.claude], "Codex's stop going leaves Claude's request")
    }

    /// A stop replaced before its reset keeps the request, at the new time.
    @Test func request_followsTheReleaseWhileTheProviderIsHeld() {
        let recorder = Recorder()
        let first = Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a")
        let items = Recorded([first])
        let sync = Self.sync(items, recorder: recorder)
        sync.requestIfOffered(first, now: Self.now)

        let sooner = Self.now.addingTimeInterval(75)
        items.value = [Self.stop(UsageLimit(resetAt: sooner), runtime: "a")]
        sync.refresh()
        #expect(sync.requested[.claude] == sooner)
        #expect(recorder.scheduled.map(\.1) == [Self.reset, sooner])
    }

    /// Once the release it was for has come, a request is spent: a limit
    /// met later offers its own notice.
    @Test func request_endsAtTheReleaseItWasFor() {
        let recorder = Recorder()
        let clock = Recorded(Self.now)
        let first = Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a")
        let items = Recorded([first])
        let sync = Self.sync(items, now: clock, recorder: recorder)
        sync.requestIfOffered(first, now: Self.now)

        clock.value = Self.reset.addingTimeInterval(3600)
        let later = Self.reset.addingTimeInterval(7200)
        let second = Self.stop(UsageLimit(resetAt: later), runtime: "b")
        items.value = [first, second]
        sync.refresh()
        #expect(sync.requested.isEmpty)
        #expect(sync.notice(for: second, now: clock.value) == .offered)
    }

    /// A notice the person asked for, or one the setting schedules, is
    /// withdrawn with the limit it was for.
    @Test(arguments: [false, true])
    func aNotice_isWithdrawnWithTheLimitItWasFor(isSettingOn: Bool) {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let items = Recorded([limited])
        let sync = Self.sync(items, isEnabled: isSettingOn, recorder: recorder)
        if !isSettingOn {
            sync.requestIfOffered(limited, now: Self.now)
        }
        #expect(recorder.scheduled.map(\.1) == [Self.reset])
        recorder.cancelled = []

        items.value = []
        sync.refresh()
        #expect(sync.requested.isEmpty)
        #expect(sync.pending.isEmpty)
        #expect(recorder.cancelled == [.claude])
    }

    @Test func sync_withdrawsWhatAnEarlierLaunchLeftThenSchedulesWhatHolds() {
        let recorder = Recorder()
        let reset = Self.now.addingTimeInterval(60)
        _ = UsageLimitResetSync(
            limits: { Self.limits([.claude: reset]) },
            isEnabled: { true },
            now: { Self.now },
            schedule: { recorder.scheduled.append(($0, $1)) },
            cancel: { recorder.cancelled.append($0) }
        )
        #expect(Set(recorder.cancelled) == Set(AgentKind.allCases))
        #expect(recorder.scheduled.map(\.0) == [.claude])
    }

    @Test func sync_schedulesOncePerResetAndWithdrawsWhatGoes() {
        let recorder = Recorder()
        let first = Self.now.addingTimeInterval(60)
        let second = Self.now.addingTimeInterval(120)
        let current = Recorded(Self.limits([.claude: first]))
        let isEnabled = Recorded(true)
        let sync = UsageLimitResetSync(
            limits: { current.value },
            isEnabled: { isEnabled.value },
            now: { Self.now },
            schedule: { recorder.scheduled.append(($0, $1)) },
            cancel: { recorder.cancelled.append($0) }
        )
        #expect(recorder.scheduled.map(\.1) == [first])

        sync.refresh()
        #expect(recorder.scheduled.count == 1, "the same reset is not scheduled twice")

        current.value = Self.limits([.claude: second])
        sync.refresh()
        #expect(recorder.scheduled.map(\.1) == [first, second])

        recorder.cancelled = []
        isEnabled.value = false
        sync.refresh()
        #expect(recorder.cancelled == [.claude])
        #expect(sync.pending.isEmpty)
    }

    // MARK: - Reading again

    /// The bar and the menu are drawn again when the limits are read, which
    /// the sync does a second past the next reset with no event to ask.
    @Test func check_isDueASecondPastTheNextReset() {
        let recorder = Recorder()
        let clock = Recorded(Self.now)
        let soon = Self.now.addingTimeInterval(60)
        let items = Recorded([
            Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a"),
            Self.stop(UsageLimit(resetAt: soon), provider: .codex, runtime: "b")
        ])
        let sync = Self.sync(items, now: clock, recorder: recorder)
        #expect(sync.resetPassedAt == Self.now)
        #expect(sync.nextCheck == soon.addingTimeInterval(1))

        clock.value = soon.addingTimeInterval(1)
        sync.refresh()
        #expect(sync.nextCheck == Self.reset.addingTimeInterval(1))

        items.value = []
        sync.refresh()
        #expect(sync.nextCheck == nil)
    }

    /// The timer itself, on the real clock: a reset a moment ahead is
    /// passed a second later, and the views are told.
    @Test(.tags(.slow)) func check_marksTheResetPassed() async {
        let start = Date()
        let items = Recorded([Self.stop(UsageLimit(resetAt: start.addingTimeInterval(0.05)))])
        let sync = UsageLimitResetSync(
            limits: { UsageLimits(items: items.value) },
            isEnabled: { false },
            schedule: { _, _ in },
            cancel: { _ in }
        )
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(50)) {
            sync.resetPassedAt >= start.addingTimeInterval(1)
        }
        #expect(sync.resetPassedAt >= start.addingTimeInterval(1.05))
        #expect(sync.nextCheck == nil)
    }

    /// A notification whose time has come is the system's to deliver, late
    /// after sleep perhaps; reading the limits then does not withdraw it.
    @Test func reset_doesNotWithdrawTheNotificationItWasFor() {
        let recorder = Recorder()
        let clock = Recorded(Self.now)
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), now: clock, recorder: recorder)
        sync.requestIfOffered(limited, now: Self.now)
        recorder.cancelled = []

        clock.value = Self.reset.addingTimeInterval(1)
        sync.refresh()
        #expect(recorder.cancelled.isEmpty)
        #expect(sync.requested.isEmpty)
    }

    @Test func request_isNotHeldPastItsTime_beforeTheNextRefresh() {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), recorder: recorder)
        sync.requestIfOffered(limited, now: Self.now)
        #expect(sync.isNoticeRequested(for: .claude, now: Self.reset.addingTimeInterval(-1)))
        #expect(!sync.isNoticeRequested(for: .claude, now: Self.reset))
    }

    // MARK: - The menu

    private static func menuItem(
        _ state: NeedsAttentionListModel.RowState,
        notice: UsageLimitResetNotice?,
        request: MenuBarModel.Request? = nil
    ) -> MenuBarModel.Item? {
        let row = NeedsAttentionListModel.Row(
            id: stop(nil).id, state: state, title: "s", place: nil, fact: "f", placeLead: "", action: nil, arrivedAt: now
        )
        return MenuBarModel(
            rows: [row],
            request: { _ in request },
            canResume: { _ in true },
            resetNotice: { _ in notice }
        ).items.first
    }

    @Test func menu_followsTheBar() {
        #expect(Self.menuItem(.stopped, notice: .offered)?.actions == [.notifyAtReset])
        #expect(Self.menuItem(.stopped, notice: .requested)?.actions == [])
        #expect(Self.menuItem(.stopped, notice: .requested)?.note == .resetNoticeRequested)
        #expect(Self.menuItem(.stopped, notice: nil)?.actions == [.resume])
        #expect(Self.menuItem(.stopped, notice: nil)?.note == nil)
    }

    @Test func menu_offersTheNoticeOnStopsOnly() {
        #expect(Self.menuItem(.unread, notice: .requested)?.note == nil)
        #expect(Self.menuItem(.unread, notice: .offered)?.actions == [])
        let request = MenuBarModel.Request(command: "ls", isQuestion: false, offer: .timedOut)
        #expect(Self.menuItem(.approval, notice: .requested, request: request)?.note == .timedOut)
    }
}
