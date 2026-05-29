// ConflictService.swift
// Limpid — assembles the conflict-detection pipeline into one owned
// object per window: FS base → registry of watchers → detector, wired by
// the pipeline. The UI observes `detector.conflicts`; the rest is
// internal plumbing.
//
// Lifecycle: create one, `start()`, and call `updateWorktrees(from:)`
// whenever the session's projects change (the sidebar already re-syncs
// the model via GitSyncCoordinator; we follow it). `stop()` on teardown.

import Foundation

@MainActor
final class ConflictService {
    /// The observable the UI binds to.
    let detector: ConflictDetector

    private let coordinator: FSEventCoordinator
    private let registry: WorktreeRegistry
    private let pipeline: DetectionPipeline

    init(
        config: DetectorConfig = DetectorConfig(),
        git: any GitInspecting = ShellGit(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        let coordinator = FSEventCoordinator()
        let registry = WorktreeRegistry(coordinator: coordinator, git: git)
        self.coordinator = coordinator
        self.registry = registry
        detector = ConflictDetector(config: config, now: now) {
            await registry.snapshot()
        }
        pipeline = DetectionPipeline(coordinator: coordinator, registry: registry, detector: detector)
    }

    func start() {
        pipeline.start()
    }

    func stop() {
        pipeline.stop()
    }

    /// Reconcile the watched set to the current sidebar model, then
    /// re-evaluate (membership changes can create or clear conflicts on
    /// their own, independent of any file event).
    func updateWorktrees(from projects: [Project]) async {
        await registry.sync(to: ConflictWorktreeBridge.watchedWorktrees(from: projects))
        await detector.reevaluate()
    }
}
