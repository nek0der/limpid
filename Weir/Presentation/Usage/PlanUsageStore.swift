// PlanUsageStore.swift
// Weir — the agents' plan usage the usage panel and its rail button show.

import Foundation
import Observation

/// The plan usage of each agent, as last reported. Claude Code's is the
/// record its status line relay writes, which the record source watches.
/// Codex's is asked of Codex once at launch and every minute while a usage
/// panel is open: Codex reports its usage only inside a session's rollout,
/// as its turns run, so a person who opens the panel between sessions would
/// otherwise see nothing new.
@MainActor
@Observable
final class PlanUsageStore {
    /// Where Codex's usage stands.
    enum CodexState: Equatable {
        /// Not asked yet this launch.
        case unread
        case reading
        case read(CodexUsageOutcome)
    }

    /// Claude Code's last reported usage. Optional because no Claude Code
    /// on a plan with limits has answered in a Weir pane yet.
    private(set) var claude: PlanUsage?
    private(set) var codex: CodexState = .unread
    /// Codex's last usage, kept through a later read that failed, so the
    /// panel can show it dimmed rather than nothing. Dropped when Codex says
    /// it has no plan to count.
    private(set) var lastCodexUsage: PlanUsage?

    /// How often an open panel asks Codex again.
    static let codexRefreshInterval: Duration = .seconds(60)

    @ObservationIgnored private let records: any PlanUsageRecordSource
    @ObservationIgnored private let codexReader: any CodexUsageReading
    /// False in demo mode: the panel stays empty rather than showing the
    /// person's own accounts in a screenshot.
    @ObservationIgnored private let readsUsage: Bool

    init(records: any PlanUsageRecordSource, codexReader: any CodexUsageReading, readsUsage: Bool = true) {
        self.records = records
        self.codexReader = codexReader
        self.readsUsage = readsUsage
    }

    /// Reads Claude Code's record and follows its changes, and asks Codex
    /// once, so the panel's first opening shows values rather than a read
    /// under way.
    func start() {
        guard readsUsage else { return }
        reloadClaude()
        records.watch { [weak self] in self?.reloadClaude() }
        Task { await refreshCodex() }
    }

    func reloadClaude() {
        claude = records.record(for: .claude)
    }

    /// Asks Codex now and every `codexRefreshInterval` until the calling
    /// task ends. A panel runs it for as long as it is shown, so closing the
    /// panel or its window stops it, with nothing to count.
    func followCodex() async {
        while !Task.isCancelled {
            await refreshCodex()
            try? await Task.sleep(for: Self.codexRefreshInterval)
        }
    }

    /// Asks Codex once, now. The panel's refresh button calls it too.
    func refreshCodex() async {
        guard readsUsage, codex != .reading else { return }
        let before = codex
        codex = .reading
        let outcome = await codexReader.read()
        // A read cut short says nothing about Codex: what was shown before
        // stays.
        guard !Task.isCancelled else {
            codex = before
            return
        }
        codex = .read(outcome)
        switch outcome {
        case let .usage(usage):
            lastCodexUsage = usage
        // Codex says there is no plan to count, so the last one no longer
        // stands for this account.
        case .noPlan, .notInstalled:
            lastCodexUsage = nil
        // A failed read says nothing new: the last values are kept, dimmed.
        case .failed:
            break
        }
    }

    /// The most pressing level among the windows still running at `now`, for
    /// the rail's mark. Codex counts once it was read. Old values count as
    /// they are: within a window the share only grows, so an old one is at
    /// most an understatement, and a window that has since reset no longer
    /// counts at all.
    func level(at now: Date) -> PlanUsageLevel {
        [claude, lastCodexUsage].compactMap(\.self).map { $0.level(at: now) }.max() ?? .normal
    }
}
