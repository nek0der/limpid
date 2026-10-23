// UsageLimit.swift
// Limpid — an agent's plan ran out of usage: when it resets, and which agents it holds.

import Foundation

/// The usage limit an agent's turn stopped at, as its run reports it.
struct UsageLimit: Codable, Equatable, Hashable, Sendable {
    /// When the limit resets; `nil` when the provider did not say.
    var resetAt: Date?
    /// Which limit, as the provider names it (Claude's `five_hour`,
    /// `seven_day`, …); `nil` when not given.
    var window: String?

    /// Whether the limit holds every agent of the account. Claude's weekly
    /// limits of one model (`seven_day_opus`, `seven_day_sonnet`) stop only
    /// the agents on that model, so they do not mark the others.
    var isAccountWide: Bool {
        !["seven_day_opus", "seven_day_sonnet"].contains(window)
    }

    /// Whether the reset is known and still ahead at `now`.
    func resetsLater(than now: Date) -> Bool {
        resetAt.map { $0 > now } ?? false
    }

    /// Of the limits that hold one agent, the one holding it at `now`: the
    /// one that resets last of those still ahead, else one whose reset is
    /// not known; `nil` when every one has reset. A reset that has passed
    /// never hides a limit whose time is not known.
    static func holding(_ limits: [UsageLimit], at now: Date) -> UsageLimit? {
        let ahead = limits.filter { $0.resetsLater(than: now) }
        if let last = ahead.max(by: { ($0.resetAt ?? now) < ($1.resetAt ?? now) }) {
            return last
        }
        return limits.first { $0.resetAt == nil }
    }
}

/// What a usage limit stop offers instead of resuming while the limit holds:
/// resuming before the reset only meets the limit again, so the bar's
/// primary is "Notify When It Resets", and once asked (or when the setting
/// asks for every reset) the bar says the notice will come.
enum UsageLimitResetNotice: Equatable, Sendable {
    case offered
    case requested

    /// The notice `item` offers at `now`: a usage limit stop while its
    /// provider is held, judged by the same time the notice is sent at
    /// (`UsageLimits.releaseAt`), so the bar never offers to resume into a
    /// limit that still holds nor to notify of one that has passed. Any
    /// other stop resumes as it would.
    static func of(_ item: AttentionItem, in limits: UsageLimits, isRequested: (AgentKind) -> Bool, now: Date) -> Self? {
        guard case .stop(.usageLimit) = item.kind, let provider = item.subject.provider,
              limits.releaseAt(of: provider, now: now) != nil
        else { return nil }
        return isRequested(provider) ? .requested : .offered
    }
}

/// The usage limits that hold each provider's agents now, read from the
/// attention list's stops: one plan per provider on this Mac stands for the
/// account, so every agent of that provider is held until it resets.
struct UsageLimits: Equatable, Sendable {
    /// Each limited provider's limits, one per stop. Which holds it is
    /// chosen against the clock (`UsageLimit.holding`), since a reset that
    /// passes changes the answer.
    private(set) var limits: [AgentKind: [UsageLimit]] = [:]

    init(items: [AttentionItem]) {
        for item in items {
            guard case let .stop(.usageLimit(limit)) = item.kind, let provider = item.subject.provider else { continue }
            limits[provider, default: []].append(limit)
        }
    }

    /// `provider`'s limits that hold every agent of the account, for the
    /// rows they mark.
    func accountWide(of provider: AgentKind) -> [UsageLimit] {
        (limits[provider] ?? []).filter(\.isAccountWide)
    }

    /// When `provider`'s agents are free again, seen at `now`: the
    /// account-wide limit that resets last; a model's own weekly limit sets
    /// it only when nothing else holds the provider. `nil` when no limit
    /// holds it with a time ahead. One time per provider, as the plan is
    /// the account's: an agent on a model whose own weekly limit outlasts
    /// it is told at that time too, which it learns from its own stop.
    func releaseAt(of provider: AgentKind, now: Date) -> Date? {
        guard let all = limits[provider] else { return nil }
        let accountWide = all.filter(\.isAccountWide)
        let candidates = accountWide.contains { $0.resetsLater(than: now) || $0.resetAt == nil } ? accountWide : all
        return UsageLimit.holding(candidates, at: now).flatMap { $0.resetsLater(than: now) ? $0.resetAt : nil }
    }

    /// The times after `now` at which what these limits say has changed: a
    /// second past each known reset still ahead. `UsageLimitResetSync`
    /// reads them again then, rather than on a clock, and the views that
    /// word them are drawn again with it.
    func changeTimes(after now: Date) -> [Date] {
        limits.values.joined().compactMap(\.resetAt).filter { $0 > now }.sorted().map { $0.addingTimeInterval(1) }
    }

    /// The notifications to have pending at `now`: for every limited
    /// provider while the setting asks for every reset, else for the
    /// providers the person asked of from a stop. One per provider, at
    /// its `releaseAt`. A limit with no time, or one past, has none.
    func pendingResetNotifications(isEnabled: Bool, requested: Set<AgentKind> = [], now: Date) -> [AgentKind: Date] {
        Dictionary(uniqueKeysWithValues: limits.keys.compactMap { provider in
            guard isEnabled || requested.contains(provider), let release = releaseAt(of: provider, now: now) else { return nil }
            return (provider, release)
        })
    }
}
