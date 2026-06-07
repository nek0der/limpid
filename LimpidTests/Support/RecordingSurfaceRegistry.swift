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
}
