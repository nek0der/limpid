// DetectionPipeline.swift
// Limpid — wires the FS base to the watchers and the detector (spec
// §12.2). It is the single consumer of `coordinator.changes` (already
// debounced in the coordinator), which matters: an `AsyncStream` has one
// consumer, so all FS-derived work must flow through here. A future
// ActivityTracker (method B) would be notified from this same loop
// rather than subscribing to `changes` independently (review concern 2).

import Foundation

@MainActor
final class DetectionPipeline {
    private let coordinator: any FSEventCoordinating
    private let registry: WorktreeRegistry
    private let detector: ConflictDetector
    private var task: Task<Void, Never>?

    init(
        coordinator: any FSEventCoordinating,
        registry: WorktreeRegistry,
        detector: ConflictDetector
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.detector = detector
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        task = Task { [coordinator, registry, detector] in
            for await id in coordinator.changes {
                guard let watcher = await registry.watcher(for: id) else { continue }
                let changed = await watcher.refresh()
                // Only re-evaluate when the changed-path set actually
                // moved — a re-save of the same files is a no-op.
                if changed { await detector.reevaluate() }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
