// PlanUsageText.swift
// Weir — what the usage panel and its rail button say: each agent's section, each window's row, the rail's mark.

import Foundation
import WeirDomain

/// One agent's part of the usage panel, worded.
struct PlanUsageSection: Equatable {
    /// The agent's name.
    let title: String
    /// How long ago the values were reported. Optional because an agent
    /// with no values yet has nothing to date.
    let observedAt: Date?
    /// Whether the values are old enough that the person has probably used
    /// the agent since (`staleAfter`).
    let isStale: Bool
    let rows: [PlanUsageRow]
    /// "Reset credits left: 2 (until 10/30, 3:47 AM)". Optional because only
    /// Codex grants them, and none are left most of the time.
    let resetCredits: String?
    /// Values kept from an earlier read while a new one runs or after it
    /// failed.
    let isDimmed: Bool
    /// What to say in place of, or under, the rows. Optional because a
    /// section with fresh values says nothing more.
    let note: LocalizedStringResource?
}

/// One limit window's row: its name, the share used, and when it resets.
struct PlanUsageRow: Equatable {
    let kind: String
    let name: LocalizedStringResource
    /// From 0 to 100, for the number and the bar.
    let percent: Int
    let level: PlanUsageLevel
    /// The reset time has passed, so the share no longer holds: the row
    /// says so in place of a number.
    let hasReset: Bool
    /// "Resets 3:40 PM", "Resets Tue 9:00 AM". Optional because an agent may
    /// not say when, and a window that has reset has nothing to wait for.
    let resetText: String?
}

enum PlanUsageText {
    /// Values older than this may well have moved: the person has probably
    /// used the agent elsewhere since.
    static let staleAfter: TimeInterval = 60 * 60

    // MARK: Sections

    static func claudeSection(_ usage: PlanUsage?, now: Date, locale: Locale) -> PlanUsageSection {
        let note = LocalizedStringResource(
            "Shows once Claude on a Pro or Max plan replies. Needs a status line of your own (set one with /statusline).",
            comment: "Plan usage panel, Claude Code section before any usage was reported; /statusline is a command name"
        )
        // Under the values, how fresh they are: they move only when Claude
        // replies, unlike Codex's, which are read while the panel is open.
        let asOfLastReply = LocalizedStringResource(
            "Claude’s values are as of its last reply.",
            comment: "Plan usage panel, under Claude's values: they are only as fresh as its last reply"
        )
        return section(
            agent: .claude,
            Content(usage: usage, isDimmed: false, note: usage == nil ? note : asOfLastReply),
            now: now,
            locale: locale
        )
    }

    static func codexSection(
        _ state: PlanUsageStore.CodexState,
        last: PlanUsage?,
        now: Date,
        locale: Locale
    ) -> PlanUsageSection {
        switch state {
        // A read under way leaves the last values as they are, so the panel
        // does not change height while Codex answers; the header shows the
        // read instead. Only with nothing to show yet does the section say
        // it is reading.
        case .unread, .reading:
            section(agent: .codex, Content(usage: last, isDimmed: false, note: last == nil ? reading : nil), now: now, locale: locale)
        case let .read(.usage(usage)):
            section(agent: .codex, Content(usage: usage, isDimmed: false, note: nil), now: now, locale: locale)
        case .read(.noPlan):
            section(agent: .codex, Content(usage: nil, isDimmed: false, note: noPlan), now: now, locale: locale)
        case .read(.notInstalled):
            section(agent: .codex, Content(usage: nil, isDimmed: false, note: notInstalled), now: now, locale: locale)
        case .read(.failed):
            section(agent: .codex, Content(usage: last, isDimmed: true, note: failed), now: now, locale: locale)
        }
    }

    private static let reading = LocalizedStringResource(
        "Reading…",
        comment: "Plan usage panel, Codex section while Codex is being asked"
    )
    private static let noPlan = LocalizedStringResource(
        "Codex reported no plan usage. Sign in to Codex with ChatGPT to see it.",
        comment: "Plan usage panel, Codex section when Codex answers with no plan (an API key, or signed out)"
    )
    private static let notInstalled = LocalizedStringResource(
        "Codex was not found.",
        comment: "Plan usage panel, Codex section when no codex executable is installed"
    )
    private static let failed = LocalizedStringResource(
        "Codex’s usage could not be read.",
        comment: "Plan usage panel, Codex section when Codex did not answer or answered with an error"
    )

    /// What one section shows, before it is worded.
    private struct Content {
        let usage: PlanUsage?
        let isDimmed: Bool
        let note: LocalizedStringResource?
    }

    private static func section(agent: AgentKind, _ content: Content, now: Date, locale: Locale) -> PlanUsageSection {
        let usage = content.usage
        return PlanUsageSection(
            title: SessionRowFactText.agentName(.agent(agent), locale: locale),
            observedAt: usage?.observedAt,
            isStale: usage.map { now.timeIntervalSince($0.observedAt) > staleAfter } ?? false,
            rows: usage?.windows.map { row($0, now: now, locale: locale) } ?? [],
            resetCredits: usage?.resetCredits.map { resetCredits($0, locale: locale) },
            isDimmed: content.isDimmed,
            note: content.note
        )
    }

    // MARK: Rows

    static func row(_ window: PlanUsageWindow, now: Date, locale: Locale) -> PlanUsageRow {
        let hasReset = window.hasReset(at: now)
        return PlanUsageRow(
            kind: window.kind,
            name: windowName(window.kind, locale: locale),
            percent: hasReset ? 0 : window.displayPercent,
            level: hasReset ? .normal : window.level,
            hasReset: hasReset,
            resetText: hasReset ? nil : window.resetsAt.map { resetsAt in
                let time = StopReasonText.resetTime(resetsAt, locale: locale, now: now)
                return LocalizedStringResource(
                    "Resets \(time)",
                    comment: "Plan usage window; argument: when it resets, the time today or the weekday and time (3:40 PM, Tue 9:00 AM)"
                ).resolved(in: locale)
            }
        )
    }

    /// The resets left and when the first lapses, the day and the time, as
    /// one may lapse within hours.
    static func resetCredits(_ credits: PlanResetCredits, locale: Locale) -> String {
        guard let expiresAt = credits.expiresAt else {
            return LocalizedStringResource(
                "Reset credits left: \(credits.available)",
                comment: "Plan usage panel, Codex section: how many limit resets the account may still spend"
            ).resolved(in: locale)
        }
        let date = expiresAt.formatted(
            Date.FormatStyle(locale: locale).month(.defaultDigits).day().hour().minute()
        )
        return LocalizedStringResource(
            "Reset credits left: \(credits.available) (until \(date))",
            comment: "Plan usage panel, Codex section: limit resets the account may still spend, and when the first lapses (10/30, 3:47 AM)"
        ).resolved(in: locale)
    }

    /// The names the decision bar gives a limit an agent stopped at, so a
    /// window reads the same wherever it is named; a window Codex gives by a
    /// length with no name of its own (`minutes_1440`) is named by that
    /// length ("1-day limit").
    static func windowName(_ kind: String, locale: Locale) -> LocalizedStringResource {
        guard kind.hasPrefix(minutesPrefix), let minutes = Int(kind.dropFirst(minutesPrefix.count)), minutes > 0 else {
            return StopReasonText.limitName(kind)
        }
        let length = Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow).locale(locale)
        )
        return LocalizedStringResource(
            "\(length) limit",
            comment: "Plan usage window of a length with no name of its own; argument: the length (1d, 12h)"
        )
    }

    /// How the Rust side names a window by its length alone
    /// (`weir_provider_codex::rate_limits`).
    private static let minutesPrefix = "minutes_"

    static let reset = LocalizedStringResource(
        "usage.window.reset",
        defaultValue: "Reset",
        comment: "Plan usage panel: the window's reset time has passed, so its usage starts over"
    )

    /// VoiceOver's value for a row: the share, or that it has reset.
    static func spokenValue(_ row: PlanUsageRow, locale: Locale) -> String {
        guard !row.hasReset else { return reset.resolved(in: locale) }
        return LocalizedStringResource(
            "\(row.percent)% used",
            comment: "Plan usage window, VoiceOver value; argument: the whole percent used"
        ).resolved(in: locale)
    }

    // MARK: Rail

    static func railBadge(_ level: PlanUsageLevel) -> RailBadge? {
        switch level {
        case .normal: nil
        case .nearLimit: .usage(isAtLimit: false)
        case .atLimit: .usage(isAtLimit: true)
        }
    }

    static func levelLabel(_ level: PlanUsageLevel, locale: Locale) -> String? {
        switch level {
        case .normal:
            nil
        case .nearLimit:
            LocalizedStringResource("Near a limit", comment: "Plan usage rail mark: a limit window is at 80% or more")
                .resolved(in: locale)
        case .atLimit:
            LocalizedStringResource("At a limit", comment: "Plan usage rail mark: a limit window is used up")
                .resolved(in: locale)
        }
    }

    /// "Plan Usage · At a limit"; the name alone while nothing is close.
    static func railHelp(_ level: PlanUsageLevel, locale: Locale) -> String {
        let name = LocalizedStringResource(
            "Plan Usage",
            comment: "The rail button and panel that show how much of each agent's plan limits is used"
        ).resolved(in: locale)
        guard let label = levelLabel(level, locale: locale) else { return name }
        return "\(name) · \(label)"
    }
}
