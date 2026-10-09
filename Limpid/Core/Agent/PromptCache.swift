// PromptCache.swift
// Limpid — the prompt cache window a finished turn left, and what it means now.
//
// An agent's conversation prefix is cached on the model provider's servers
// for a fixed time after the last request. The next message after that
// re-writes the whole prefix at the cache-write rate, which for a large
// session is the most expensive message the user sends. The window arrives
// from the Rust projection on the badge; everything here is a pure function of
// that window and a clock, so the interface can say "expiring soon" or
// "expired" without the projection running on a timer.
//
// Provider-neutral by construction: a window is present only when the
// provider declared it can describe one, so nothing here asks which agent
// produced it.

import Foundation

/// One prompt cache lifetime, as the projection reports it.
struct AgentCacheWindow: Codable, Equatable, Hashable {
    /// Whether the provider stated the expiry or we derived it.
    enum Precision: String, Codable, Equatable, Hashable {
        case reported
        case estimated
        /// A value a newer build wrote. Kept decodable because the badge is
        /// part of the persisted session, and an unknown spelling must not
        /// cost the user their tabs.
        case unknown

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Precision(rawValue: raw) ?? .unknown
        }
    }

    /// When the request that last refreshed the cache started. Also the
    /// window's identity: a later request moves it.
    var observedAt: Date
    var ttlSeconds: Int
    /// Prompt tokens the next request re-sends, which is what a cache miss
    /// re-writes. Optional because a provider may not report usage.
    var rewriteTokens: Int?
    var precision: Precision

    var expiresAt: Date {
        observedAt.addingTimeInterval(TimeInterval(ttlSeconds))
    }
}

/// What a window means at one instant.
enum PromptCacheStatus: Int, Equatable, Comparable {
    /// No window, an unknown one, or a turn in progress — whose request
    /// keeps the cache warm by definition.
    case hidden
    /// At least the warning lead left. Shows nothing: an hour-long window
    /// that is fine is not news.
    case valid
    /// Less than the warning lead left; see `warningLead(ttlSeconds:)`.
    case expiringSoon
    /// The next message re-writes the prefix.
    case expired

    /// The longest lead: five minutes is long enough to finish a thought
    /// and send the next message, short enough that a one-hour window does
    /// not wear a warning for most of its life.
    static let maximumWarningLead: TimeInterval = 5 * 60

    /// How far ahead of the expiry the mark appears: a fifth of the window,
    /// at most `maximumWarningLead`. A fixed five minutes would turn a
    /// five-minute window yellow the moment its turn ended, which says
    /// nothing; a fifth leaves it a minute of warning, and an hour's window
    /// its five.
    static func warningLead(ttlSeconds: Int) -> TimeInterval {
        min(maximumWarningLead, TimeInterval(ttlSeconds) / 5)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func status(
        window: AgentCacheWindow?,
        now: Date,
        isRunningTurn: Bool
    ) -> PromptCacheStatus {
        guard let window, window.ttlSeconds > 0, !isRunningTurn else { return .hidden }
        let remaining = window.expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            return .expired
        }
        return remaining < warningLead(ttlSeconds: window.ttlSeconds) ? .expiringSoon : .valid
    }

    /// The next instant after `now` at which `window`'s status changes, or
    /// `nil` once it has expired and nothing further can change.
    static func nextTransition(of window: AgentCacheWindow, after now: Date) -> Date? {
        guard window.ttlSeconds > 0 else { return nil }
        let warning = window.expiresAt.addingTimeInterval(-warningLead(ttlSeconds: window.ttlSeconds))
        if warning > now {
            return warning
        }
        if window.expiresAt > now {
            return window.expiresAt
        }
        return nil
    }

    /// The soonest transition across `windows`, so one timer covers every
    /// pane rather than one per row.
    static func nextTransition(of windows: [AgentCacheWindow], after now: Date) -> Date? {
        windows.compactMap { nextTransition(of: $0, after: now) }.min()
    }
}

extension AgentBadge {
    /// A turn is in flight. Its request refreshes the cache, so whatever
    /// window the badge still carries says nothing about the next message.
    var isRunningTurn: Bool {
        state == .running || state == .compacting
    }

    /// The agent sits at its prompt, so text typed into the pane reaches the
    /// prompt rather than a question, an approval, or a running turn.
    var isAwaitingPrompt: Bool {
        state == .idle || state == .finished
    }

    func promptCacheStatus(at now: Date) -> PromptCacheStatus {
        PromptCacheStatus.status(window: cacheWindow, now: now, isRunningTurn: isRunningTurn)
    }
}

/// Display strings for a window. Kept out of the views so the wording is
/// tested once and every surface that names a window says it the same way.
enum PromptCacheFormatting {
    /// `573k`, `1.2M`, or the bare count under a thousand. A rewrite size is
    /// an order of magnitude to weigh, not an amount to reconcile, so three
    /// significant digits are plenty.
    static func tokens(_ count: Int) -> String {
        let value = max(0, count)
        if value < 1000 {
            return "\(value)"
        }
        let thousands = (Double(value) / 1000).rounded()
        if thousands < 1000 {
            return "\(Int(thousands))k"
        }
        let millions = (Double(value) / 1_000_000 * 10).rounded() / 10
        if millions == millions.rounded() {
            return "\(Int(millions))M"
        }
        return String(format: "%.1fM", millions)
    }

    /// The largest whole unit of `interval`, localized in `locale`: `4m`,
    /// `45s`, `2h`. Rounded down so "expires in 5m" never appears while
    /// under five minutes remain, which the mark's color already says.
    static func duration(_ interval: TimeInterval, locale: Locale) -> String {
        let seconds = max(0, Int(interval))
        let floored = if seconds >= 86400 {
            seconds / 86400 * 86400
        } else if seconds >= 3600 {
            seconds / 3600 * 3600
        } else if seconds >= 60 {
            seconds / 60 * 60
        } else {
            seconds
        }
        return Duration.seconds(floored).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1)
                .locale(locale)
        )
    }
}
