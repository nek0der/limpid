// DebouncedSaveTests.swift
// Limpid — a store's pending save: coalesced, canceled, and what it says is pending.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("DebouncedSave")
struct DebouncedSaveTests {
    /// Counts runs on the main actor. It is a class so the scheduled
    /// closures can share it.
    @MainActor
    private final class Runs {
        var labels: [String] = []
    }

    @Test func schedule_burst_runsOnlyTheLast() async {
        let save = DebouncedSave(delay: .milliseconds(20))
        let runs = Runs()

        save.schedule { runs.labels.append("first") }
        save.schedule { runs.labels.append("second") }
        #expect(save.hasPending)

        await pollUntil(interval: .milliseconds(10)) { !runs.labels.isEmpty }
        // We wait long enough for a first save that was not replaced to run too.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(runs.labels == ["second"])
    }

    @Test func cancel_dropsThePendingSave() async throws {
        let save = DebouncedSave(delay: .milliseconds(20))
        let runs = Runs()

        save.schedule { runs.labels.append("canceled") }
        save.cancel()

        #expect(!save.hasPending)
        try await Task.sleep(for: .milliseconds(80))
        #expect(runs.labels.isEmpty)
    }

    @Test func hasPending_staysTrueOnceTheSaveHasRun() async {
        // A store's flush writes again after a save that ran, as it did
        // before the timer was shared.
        let save = DebouncedSave(delay: .milliseconds(10))
        let runs = Runs()
        #expect(!save.hasPending)

        save.schedule { runs.labels.append("ran") }
        await pollUntil(interval: .milliseconds(10)) { !runs.labels.isEmpty }

        #expect(runs.labels == ["ran"])
        #expect(save.hasPending)
    }
}
