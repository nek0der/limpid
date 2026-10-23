// RecordingSurfaceRegistry.swift
// Limpid — instrumented `SurfaceViewProviding` that records the last `reconcile(activeIDs:)` set for tests.

import Foundation
@testable import Limpid

@MainActor
final class RecordingSurfaceRegistry: SurfaceViewProviding {
    private(set) var lastReconcileIDs: Set<UUID>?
    private(set) var unregisteredIDs: [UUID] = []

    func view(for _: UUID) -> SurfaceView? {
        nil
    }

    func id(for _: SurfaceView) -> UUID? {
        nil
    }

    func register(_: SurfaceView, for _: UUID) {}

    func unregister(_ id: UUID) {
        unregisteredIDs.append(id)
    }

    func reconcile(activeIDs: Set<UUID>) {
        lastReconcileIDs = activeIDs
    }

    /// What review's text is handed to, by pane. A pane with no entry has no
    /// destination, which is what a closed pane looks like from here.
    var deliverers: [UUID: RecordingReviewDeliverer] = [:]

    func deliverer(for id: UUID) -> (any ReviewTextDelivering)? {
        deliverers[id]
    }

    /// What each pane's terminal hands over as its scrollback. A pane with
    /// no entry has no terminal, as one never mounted this run.
    var scrollback: [UUID: String] = [:]

    func writeScrollback(ofPane paneID: UUID, to url: URL) -> Bool {
        guard let text = scrollback[paneID] else { return false }
        return (try? Data(text.utf8).write(to: url)) != nil
    }
}

/// Takes review's text and remembers it, or refuses.
@MainActor
final class RecordingReviewDeliverer: ReviewTextDelivering {
    private(set) var delivered: [String] = []
    private(set) var receipts: [ReviewPasteReceipt?] = []
    /// When set, the delivery throws instead of landing — a terminal that did
    /// not take the paste.
    var failure: (any Error)?
    /// Whether the terminal would take a paste now; false stands for one
    /// whose surface or staged command is still to come.
    var isReadyForReviewPaste = true
    var hasTerminalSurface = true
    /// What becomes of a paste that was started: it lands at once, as a
    /// bracketed paste does; it is refused, as at the confirmation sheet; or
    /// it waits for the test to settle its receipt, as a sheet left up does.
    var verdict: Verdict = .lands

    enum Verdict {
        case lands, isRefused, waits
    }

    func deliverReviewText(_ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?) throws {
        if let failure {
            throw failure
        }
        delivered.append(prompt.text)
        receipts.append(receipt)
        switch verdict {
        case .lands: receipt?.settlement?.settle(wasDelivered: true)
        case .isRefused: receipt?.settlement?.settle(wasDelivered: false)
        case .waits: break
        }
    }
}
