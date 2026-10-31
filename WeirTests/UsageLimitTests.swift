// UsageLimitTests.swift
// Weir — usage limits: read from the projection, made into stops and row chips, and notified at their reset.

import Foundation
import Testing
@testable import Weir

struct UsageLimitTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private static let reset = start.addingTimeInterval(3600)

    private static func runtime(_ id: String, provider: AgentKind = .claude, limit: UsageLimit?) -> RuntimeFact {
        var fact = RuntimeFact.test(id, .error, provider: provider, tabID: UUID(), updatedAt: start, detail: "rate_limit")
        fact.usageLimit = limit
        return fact
    }

    @Test func badge_readsTheLimitFromTheProjection() throws {
        let json = #"{"state":"error","updatedAt":"2026-10-13T05:00:00Z","#
            + #""usageLimit":{"resetsAt":"2026-10-13T06:40:00Z","window":"five_hour"}}"#
        let badge = try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
        #expect(badge.usageLimit == UsageLimit(resetAt: AgentDateParsing.parseISO8601("2026-10-13T06:40:00Z"), window: "five_hour"))
    }

    /// A shape this build cannot read costs the time, never the badge or
    /// the limit.
    @Test func badge_aLimitItCannotReadStillStands() throws {
        let json = #"{"state":"error","updatedAt":"2026-10-13T05:00:00Z","usageLimit":{"resetsAt":7}}"#
        let badge = try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
        #expect(badge.usageLimit == UsageLimit(resetAt: nil, window: nil))
        let none = #"{"state":"error","updatedAt":"2026-10-13T05:00:00Z"}"#
        #expect(try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(none.utf8)).asAgentBadge.usageLimit == nil)
    }

    @Test func reducer_anErrorAtTheLimitIsAUsageLimitStop() {
        let limited = Self.runtime("r1", limit: UsageLimit(resetAt: Self.reset, window: "five_hour"))
        let other = Self.runtime("r2", limit: nil)
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [limited, other]))
        let kinds = queue.items.map(\.kind)
        #expect(kinds.contains(.stop(.usageLimit(UsageLimit(resetAt: Self.reset, window: "five_hour")))))
        #expect(kinds.contains(.stop(.error("rate_limit"))))
        #expect(queue.counts().stops == 2)
    }

    @Test func ledger_keepsTheUsageLimitAsTheStopsReason() {
        var ledger = StopLedger()
        let limited = Self.runtime("r1", limit: UsageLimit(resetAt: Self.reset, window: nil))
        _ = ledger.update(runtimes: [limited], paneExists: { _ in true })
        #expect(ledger.records.values.map(\.reason) == [.usageLimit(UsageLimit(resetAt: Self.reset, window: nil))])
    }

    static func stop(_ provider: AgentKind, _ limit: UsageLimit, _ token: String) -> AttentionItem {
        AttentionItem.testUsageLimitStop(limit, provider: provider, runtime: token, arrivedAt: start)
    }

    @Test func limits_holdEachProviderUntilItsLatestReset() {
        let later = Self.reset.addingTimeInterval(600)
        let limits = UsageLimits(items: [
            Self.stop(.claude, UsageLimit(resetAt: Self.reset), "a"),
            Self.stop(.claude, UsageLimit(resetAt: later), "b"),
            Self.stop(.claude, UsageLimit(resetAt: nil), "c"),
            Self.stop(.codex, UsageLimit(resetAt: nil), "d")
        ])
        #expect(UsageLimit.holding(limits.limits[.claude] ?? [], at: Self.start)?.resetAt == later)
        #expect(limits.limits[.codex] == [UsageLimit(resetAt: nil)])
        #expect(UsageLimits(items: []).limits.isEmpty)
    }

    /// The person left the stopped agent (upgraded the plan, or signed in
    /// to another account) and went on in a new conversation: a turn of
    /// the provider served to its end after the stop lifts the limit, for
    /// every row and the reset notice, and keeps it lifted through that
    /// run's next turn. The stop itself stays. A prompt taken, a session
    /// started, a turn from before the stop, another provider's turn, or a
    /// model's own weekly limit lifts nothing.
    @Test func limits_aTurnServedAfterTheStop_liftsTheAccountWideLimit() {
        let limited = Self.runtime("r1", limit: UsageLimit(resetAt: nil, window: "five_hour"))
        var stopped = AttentionQueue()
        (stopped, _) = AttentionQueueReducer.reduce(stopped, input: .init(runtimes: [limited]))
        #expect(UsageLimits(queue: stopped).accountWide(of: .claude).count == 1)

        func after(_ runtime: RuntimeFact) -> AttentionQueue {
            AttentionQueueReducer.reduce(stopped, input: .init(runtimes: [limited, runtime])).0
        }
        let later = Self.start.addingTimeInterval(60)
        for runtime in [
            RuntimeFact.test("r2", .running, updatedAt: later),
            RuntimeFact.test("r2", .idle, updatedAt: later),
            RuntimeFact.test("r2", .finished, updatedAt: Self.start),
            RuntimeFact.test("r2", .finished, provider: .codex, updatedAt: later)
        ] {
            #expect(UsageLimits(queue: after(runtime)).accountWide(of: .claude).count == 1)
        }

        let lifted = after(RuntimeFact.test("r2", .finished, updatedAt: later))
        #expect(UsageLimits(queue: lifted).limits.isEmpty)
        #expect(lifted.counts().stops == 1)
        // Its next turn under way, the limit stays lifted.
        let next = AttentionQueueReducer.reduce(
            lifted,
            input: .init(runtimes: [limited, RuntimeFact.test("r2", .running, updatedAt: later.addingTimeInterval(5))])
        ).0
        #expect(UsageLimits(queue: next).limits.isEmpty)

        let opus = AttentionItem.testUsageLimitStop(UsageLimit(resetAt: Self.reset, window: "seven_day_opus"), arrivedAt: Self.start)
        #expect(!UsageLimits.isLifted(opus, by: RuntimeFact.test("r2", .finished, updatedAt: later)))
    }

    /// A time still ahead first, then a time not known, and a time past
    /// never: a reset that has passed does not hide a newer limit.
    @Test func holding_prefersATimeAheadThenAnUnknownOneOverOnePast() {
        let past = UsageLimit(resetAt: Self.start.addingTimeInterval(-60))
        let unknown = UsageLimit(resetAt: nil)
        let ahead = UsageLimit(resetAt: Self.reset)
        #expect(UsageLimit.holding([past, unknown, ahead], at: Self.start) == ahead)
        #expect(UsageLimit.holding([past, unknown], at: Self.start) == unknown)
        #expect(UsageLimit.holding([past], at: Self.start) == nil)
        #expect(UsageLimit.holding([], at: Self.start) == nil)
    }

    /// A weekly limit of one model holds the agents on that model only, so
    /// it marks no other row; it is still notified.
    @Test func limits_aModelsOwnLimitIsNotAccountWide() {
        let opus = UsageLimit(resetAt: Self.reset, window: "seven_day_opus")
        let limits = UsageLimits(items: [Self.stop(.claude, opus, "a")])
        #expect(limits.accountWide(of: .claude).isEmpty)
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.start) == [.claude: Self.reset])
        #expect(UsageLimit(resetAt: nil, window: "five_hour").isAccountWide)
        #expect(UsageLimit(resetAt: nil, window: nil).isAccountWide)
    }

    /// The other agents are free when the account-wide limit resets, even
    /// with a model's weekly limit ahead.
    @Test func notifications_followTheAccountWideLimitFirst() {
        let monday = Self.reset.addingTimeInterval(4 * 24 * 3600)
        let limits = UsageLimits(items: [
            Self.stop(.claude, UsageLimit(resetAt: monday, window: "seven_day_opus"), "a"),
            Self.stop(.claude, UsageLimit(resetAt: Self.reset, window: "five_hour"), "b")
        ])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.start) == [.claude: Self.reset])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.reset) == [.claude: monday])
    }

    @Test func stopReason_namesTheLimitAndItsReset() {
        let en = Locale(identifier: "en_US")
        let ja = Locale(identifier: "ja")
        #expect(StopReasonText.usageLimit(UsageLimit(), locale: en, now: Self.start) == "Usage limit reached")
        #expect(StopReasonText.usageLimit(UsageLimit(resetAt: Self.start), locale: en, now: Self.start) == "Usage limit reached")
        let fiveHour = UsageLimit(resetAt: Self.reset, window: "five_hour")
        #expect(StopReasonText.usageLimit(fiveHour, locale: en, now: Self.start).hasPrefix("5-hour limit reached · resets "))
        #expect(StopReasonText.usageLimit(UsageLimit(window: "seven_day"), locale: en, now: Self.start) == "Weekly limit reached")
        #expect(StopReasonText.usageLimit(UsageLimit(), locale: ja, now: Self.start) == "利用上限に達しました")
        #expect(StopReasonText.usageLimit(fiveHour, locale: ja, now: Self.start).hasPrefix("5 時間枠の上限に達しました · "))
        #expect(StopReasonText.make(.usageLimit(UsageLimit()), locale: en, now: Self.start) == "Stopped: Usage limit reached")
    }

    @Test func resetTime_isTheTimeTodayAndTheWeekdayAfter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let en = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9)))
        let today = now.addingTimeInterval(3 * 3600 + 40 * 60)
        let tomorrow = now.addingTimeInterval(24 * 3600)
        #expect(StopReasonText.resetTime(today, locale: en, now: now, calendar: calendar) == "12:40\u{202F}PM")
        #expect(StopReasonText.resetTime(tomorrow, locale: en, now: now, calendar: calendar).hasPrefix("Wed"))
        let ja = Locale(identifier: "ja")
        #expect(StopReasonText.resetTime(today, locale: ja, now: now, calendar: calendar) == "12:40")
        #expect(StopReasonText.resetTime(tomorrow, locale: ja, now: now, calendar: calendar).contains("水"))
    }

    @Test func chip_goesOnceAKnownResetHasPassed() {
        let en = Locale(identifier: "en_US")
        let limit = UsageLimit(resetAt: Self.reset)
        #expect(SessionRowFactText.usageLimitChip([limit], locale: en, now: Self.start)?.hasPrefix("Limit · ") == true)
        #expect(SessionRowFactText.usageLimitChip([limit], locale: en, now: Self.reset) == nil)
        #expect(SessionRowFactText.usageLimitSpoken([limit], locale: en, now: Self.reset) == nil)
        #expect(SessionRowFactText.usageLimitChip([limit, UsageLimit()], locale: en, now: Self.reset) == "Limit")
        #expect(SessionRowFactText.usageLimitChip([], locale: en, now: Self.start) == nil)
    }

    @Test func badge_keepsTheLimitThroughPersistence() throws {
        let badge = AgentBadge(state: .error, updatedAt: Self.start, usageLimit: UsageLimit(resetAt: Self.reset, window: "five_hour"))
        let decoded = try JSONDecoder().decode(AgentBadge.self, from: JSONEncoder().encode(badge))
        #expect(decoded.usageLimit == badge.usageLimit)
    }

    @Test func sidebar_everyRowWithALimitedAgentShowsTheChip() {
        func row(_ name: String, _ provider: AgentKind) -> SessionSidebarModel.RowInput {
            var fact = SessionRowFact.Input()
            fact.agents = [.init(provider: provider, state: .idle, detail: nil)]
            return SessionSidebarModel.RowInput(
                container: .worktree(projectID: UUID(), worktreeID: UUID()),
                name: name,
                nameTruncation: .name,
                fact: fact,
                lastActivity: nil,
                isMissing: false,
                agents: [fact]
            )
        }
        let stop = AttentionItem(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.usageLimit(UsageLimit())),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivalSequence: 0,
            arrivedAt: Self.start
        )
        let model = SessionSidebarModel(
            rows: [row("a", .claude), row("b", .codex)],
            activeContainer: .loose,
            usageLimits: UsageLimits(items: [stop]),
            locale: Locale(identifier: "en_US")
        )
        let en = Locale(identifier: "en_US")
        #expect(model.rows.map { SessionRowFactText.usageLimitChip($0.usageLimits, locale: en, now: Self.start) } == ["Limit", nil])
        #expect(SessionRowFactText
            .usageLimitSpoken(model.rows.first?.usageLimits ?? [], locale: en, now: Self.start) == "Usage limit reached")
        #expect(SessionRowFactText.spokenLabel(for: model.rows[0], projectName: nil, now: Self.start, locale: en)
            .contains("Usage limit reached"))
    }

    /// The stopped row names its reset only while it is ahead, against the
    /// row's own clock rather than when the sidebar was built.
    @Test func sidebar_theStoppedRowDropsItsResetOnceItPasses() {
        let limit = UsageLimit(resetAt: Self.reset, window: "five_hour")
        var fact = SessionRowFact.Input()
        fact.items = [AttentionItem(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.usageLimit(limit)),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivalSequence: 0,
            arrivedAt: Self.start
        )]
        fact.agents = [.init(provider: .claude, state: .error, detail: nil)]
        let en = Locale(identifier: "en_US")
        let model = SessionSidebarModel(
            rows: [.init(container: .loose, name: "a", nameTruncation: .name, fact: fact, lastActivity: nil, isMissing: false)],
            activeContainer: .loose,
            usageLimits: UsageLimits(items: fact.items),
            locale: en
        )
        #expect(SessionRowFactText.current(model.rows[0], now: Self.start, locale: en).contains("resets"))
        #expect(SessionRowFactText.current(model.rows[0], now: Self.reset, locale: en) == "Stopped: 5-hour limit reached")
    }
}
