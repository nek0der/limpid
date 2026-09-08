// RecordingSurfaceRegistry.swift
// Limpid — instrumented `SurfaceViewProviding` that records the last `reconcile(activeIDs:)` set for tests.

import Foundation
@testable import Limpid

@MainActor
final class RecordingSurfaceRegistry: SurfaceViewProviding {
    private(set) var lastReconcileIDs: Set<UUID>?
    private(set) var reconcileCount = 0
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
        reconcileCount += 1
    }

    private(set) var lastVisibleIDs: Set<UUID>?

    func updateOcclusion(visibleIDs: Set<UUID>) {
        lastVisibleIDs = visibleIDs
    }

    /// What review's text is handed to, by pane. A pane with no entry has no
    /// destination, which is what a closed pane looks like from here.
    var deliverers: [UUID: RecordingReviewDeliverer] = [:]

    func deliverer(for id: UUID) -> (any ReviewTextDelivering)? {
        deliverers[id]
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

    func deliverReviewText(_ prompt: ReviewPrompt, receipt: ReviewPasteReceipt?) throws {
        if let failure {
            throw failure
        }
        delivered.append(prompt.text)
        receipts.append(receipt)
    }
}
