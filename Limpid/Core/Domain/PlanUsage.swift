// PlanUsage.swift
// Limpid — how much of a plan's limits an agent's account has used, as the agent last reported it.

import Foundation

/// The plan usage one agent reported: its limit windows, and when it was
/// reported. Its wire form, as the Rust side
/// writes it, is Infrastructure's (`PlanUsage+Wire`).
struct PlanUsage: Equatable, Sendable {
    let windows: [PlanUsageWindow]
    let observedAt: Date
    /// The resets the account may spend, when the agent grants them (Codex).
    /// Optional because Claude Code's status line says nothing of them.
    let resetCredits: PlanResetCredits?

    init(windows: [PlanUsageWindow], observedAt: Date, resetCredits: PlanResetCredits? = nil) {
        self.windows = windows
        self.observedAt = observedAt
        self.resetCredits = resetCredits
    }

    /// The most pressing level among the windows that have not reset by
    /// `now`. A window past its reset time no longer says anything about the
    /// account: the next report starts it over.
    func level(at now: Date) -> PlanUsageLevel {
        windows.filter { !$0.hasReset(at: now) }.map(\.level).max() ?? .normal
    }
}

/// The resets an account may spend to start its limit windows over.
struct PlanResetCredits: Equatable, Sendable {
    /// How many are left, more than zero.
    let available: Int
    /// When the first of them lapses. Optional because an agent may not say.
    let expiresAt: Date?
}

/// One limit window: what share is used and when it resets.
struct PlanUsageWindow: Equatable, Sendable {
    /// `five_hour`, `seven_day`, or the agent's own name for another length.
    let kind: String
    /// From 0 to 100; a value past 100 reads as at the limit.
    let usedPercent: Double
    /// Optional because an agent may not say when the window resets.
    let resetsAt: Date?

    static let fiveHour = "five_hour"
    static let sevenDay = "seven_day"

    /// Whether the window's reset time has passed.
    func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// The share as a whole percent from 0 to 100, for display.
    var displayPercent: Int {
        Int(min(max(usedPercent, 0), 100).rounded())
    }

    var level: PlanUsageLevel {
        PlanUsageLevel(usedPercent: usedPercent)
    }
}

/// How close a window is to its limit, which colors its bar and the rail's
/// mark.
enum PlanUsageLevel: Int, Comparable, Sendable {
    case normal
    /// At or past `nearLimitPercent`.
    case nearLimit
    case atLimit

    /// Where a window starts to warrant a look before the limit stops work.
    static let nearLimitPercent = 80.0

    init(usedPercent: Double) {
        if usedPercent >= 100 {
            self = .atLimit
        } else if usedPercent >= Self.nearLimitPercent {
            self = .nearLimit
        } else {
            self = .normal
        }
    }

    static func < (lhs: PlanUsageLevel, rhs: PlanUsageLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
