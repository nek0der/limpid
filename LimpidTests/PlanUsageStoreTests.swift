// PlanUsageStoreTests.swift
// Limpid — the store behind the usage panel: Claude Code's record as it changes, and Codex's reads.

import Foundation
import Testing
@testable import Limpid

/// A Codex usage the tests hand out.
private let codexUsage = PlanUsage(
    windows: [PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 90, resetsAt: nil)],
    observedAt: Date(timeIntervalSince1970: 0)
)

@MainActor
@Suite("Plan usage store")
struct PlanUsageStoreTests {
    @Test("reads Claude Code's record at the start and again when it changes")
    func start_readsAndFollowsTheRecord() {
        let records = FakeRecords()
        let store = PlanUsageStore(records: records, codexReader: FakeCodex([]))
        store.start()
        #expect(store.claude == nil)

        records.claude = codexUsage
        records.change()
        #expect(store.claude == codexUsage)
        #expect(store.level(at: Date()) == .nearLimit)
    }

    @Test("asks Codex once at the start, before any panel opens")
    func start_asksCodexOnce() async {
        let store = PlanUsageStore(records: FakeRecords(), codexReader: FakeCodex([.usage(codexUsage)]))
        store.start()
        await pollUntil { store.codex == .read(.usage(codexUsage)) }
        #expect(store.lastCodexUsage == codexUsage)
    }

    @Test("keeps Codex's last usage through a read that failed")
    func refreshCodex_keepsTheLastUsageThroughAFailure() async {
        let store = PlanUsageStore(records: FakeRecords(), codexReader: FakeCodex([.usage(codexUsage), .failed]))
        await store.refreshCodex()
        #expect(store.codex == .read(.usage(codexUsage)))
        await store.refreshCodex()
        #expect(store.codex == .read(.failed))
        #expect(store.lastCodexUsage == codexUsage)
        #expect(store.level(at: Date()) == .nearLimit)
    }

    @Test("drops Codex's last usage once Codex says there is no plan")
    func refreshCodex_noPlan_dropsTheLastUsage() async {
        let store = PlanUsageStore(records: FakeRecords(), codexReader: FakeCodex([.usage(codexUsage), .noPlan]))
        await store.refreshCodex()
        await store.refreshCodex()
        #expect(store.lastCodexUsage == nil)
        #expect(store.level(at: Date()) == .normal)
    }

    /// The panel closing cancels a read under way; it says nothing about
    /// Codex, so what was shown before stays.
    @Test("keeps what it showed when a read is cut short")
    func refreshCodex_canceled_keepsWhatItShowed() async {
        let codex = FakeCodex([.usage(codexUsage)], thenHangs: true)
        let store = PlanUsageStore(records: FakeRecords(), codexReader: codex)
        await store.refreshCodex()
        let read = Task { await store.refreshCodex() }
        await pollUntil { store.codex == .reading }
        read.cancel()
        await read.value
        #expect(store.codex == .read(.usage(codexUsage)))
    }

    @Test("reads nothing when it may not show the person's usage")
    func demoMode_readsNothing() async {
        let records = FakeRecords()
        records.claude = codexUsage
        let store = PlanUsageStore(records: records, codexReader: FakeCodex([.usage(codexUsage)]), readsUsage: false)
        store.start()
        await store.refreshCodex()
        #expect(store.claude == nil)
        #expect(store.codex == .unread)
        #expect(store.level(at: Date()) == .normal)
    }
}

/// Records handed out by hand, with the change signal sent by the test.
@MainActor
private final class FakeRecords: PlanUsageRecordSource {
    var claude: PlanUsage?
    private var onChange: (@MainActor () -> Void)?

    func record(for agent: AgentKind) -> PlanUsage? {
        agent == .claude ? claude : nil
    }

    func watch(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func change() {
        onChange?()
    }
}

/// Codex's outcomes in the order a test hands them out. Past them it
/// answers `failed`, or, with `thenHangs`, waits until the read is
/// canceled, as a server that never answers does.
private actor FakeCodex: CodexUsageReading {
    private var outcomes: [CodexUsageOutcome]
    private let thenHangs: Bool

    init(_ outcomes: [CodexUsageOutcome], thenHangs: Bool = false) {
        self.outcomes = outcomes
        self.thenHangs = thenHangs
    }

    func read() async -> CodexUsageOutcome {
        guard outcomes.isEmpty else { return outcomes.removeFirst() }
        if thenHangs {
            // `try?`: the sleep ends by cancellation, which is the point.
            try? await Task.sleep(for: .seconds(60))
        }
        return .failed
    }
}
