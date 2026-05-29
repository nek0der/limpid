// FSEventCoordinator.swift
// Limpid — the conflict pipeline's shared FS-watching base (spec §3 /
// §12.1). One `FSEventStream` per watched worktree; raw events are
// debounced per worktree and surfaced as a single "this worktree
// changed" notification on an `AsyncStream`. It interprets nothing — no
// git, no conflict logic — so the watcher and the activity tracker can
// both ride the same base.
//
// We use raw `FSEventStreamCreate` rather than the codebase's usual
// `DispatchSource.makeFileSystemObjectSource` (SettingsFileWatcher,
// ClaudeAgentStateTracker) because those watch a single directory;
// a worktree needs *recursive* coverage, which FSEvents gives for free.
//
// Deviations from the spec's reference listing, all deliberate:
//   - `kFSEventStreamCreateFlagUseCFTypes` is set so the callback's
//     `eventPaths` arrives as a CFArray and the `NSArray` bridge is
//     valid. Without it FSEvents passes a C `char **` and the cast
//     crashes — a latent bug in the reference snippet.
//   - The retained `CallbackBox` is released explicitly in `unwatch` /
//     `deinit` (the spec left this "to do properly at implementation").
//   - Debounce is implemented in-process (a per-worktree trailing-edge
//     timer) instead of pulling in swift-async-algorithms.

import CoreServices
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "conflict.fsevents")

protocol FSEventCoordinating: AnyObject, Sendable {
    /// Begin watching a worktree. Duplicate ids are ignored.
    func watch(_ workTree: WatchedWorktree)
    /// Stop watching (worktree removed). Unknown ids are ignored.
    func unwatch(_ id: WorktreeID)
    /// Debounced "this worktree changed" notifications. May fire off the
    /// main actor. Single-consumer.
    var changes: AsyncStream<WorktreeID> { get }
}

final class FSEventCoordinator: FSEventCoordinating, @unchecked Sendable {

    /// OS-side coalescing latency handed to FSEvents (seconds). The
    /// first of the two debounce stages.
    private let latency: CFTimeInterval
    /// Trailing-edge debounce applied per worktree on top of the OS
    /// latency — agents emit write bursts, and this collapses each burst
    /// into one notification so `git status` isn't run on every keypress.
    private let debounceInterval: Duration

    // The C callback yields onto `rawContinuation`; a long-lived task
    // started in `init` debounces that into `publicStream`, which is
    // what `changes` hands callers.
    private let rawStream: AsyncStream<WorktreeID>
    private let rawContinuation: AsyncStream<WorktreeID>.Continuation
    private let publicStream: AsyncStream<WorktreeID>
    private let publicContinuation: AsyncStream<WorktreeID>.Continuation

    private struct Entry {
        let stream: FSEventStreamRef
        /// Retained on `watch`, released on `unwatch` — the C context
        /// holds the box by opaque pointer, so ARC can't see it.
        let box: Unmanaged<CallbackBox>
    }

    private var entries: [WorktreeID: Entry] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.limpid.conflict.fsevents", qos: .utility)
    private var debounceTask: Task<Void, Never>?

    var changes: AsyncStream<WorktreeID> {
        publicStream
    }

    init(latency: CFTimeInterval = 0.3, debounceInterval: Duration = .milliseconds(400)) {
        self.latency = latency
        self.debounceInterval = debounceInterval
        (rawStream, rawContinuation) = AsyncStream.makeStream(
            of: WorktreeID.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        (publicStream, publicContinuation) = AsyncStream.makeStream(
            of: WorktreeID.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        startDebounce()
    }

    deinit {
        debounceTask?.cancel()
        // No other references can exist at deinit, so the dictionary is
        // safe to drain without the lock.
        for entry in entries.values {
            FSEventStreamStop(entry.stream)
            FSEventStreamInvalidate(entry.stream)
            FSEventStreamRelease(entry.stream)
            entry.box.release()
        }
        rawContinuation.finish()
        publicContinuation.finish()
    }

    // MARK: - Watch / unwatch

    func watch(_ workTree: WatchedWorktree) {
        lock.lock()
        defer { lock.unlock() }
        guard entries[workTree.id] == nil else { return }

        let unmanaged = Unmanaged.passRetained(
            CallbackBox(id: workTree.id, continuation: rawContinuation)
        )
        var ctx = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &ctx,
            [workTree.rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            unmanaged.release()
            log.error("FSEventStreamCreate failed for \(workTree.rootURL.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        entries[workTree.id] = Entry(stream: stream, box: unmanaged)
    }

    func unwatch(_ id: WorktreeID) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.removeValue(forKey: id) else { return }
        FSEventStreamStop(entry.stream)
        FSEventStreamInvalidate(entry.stream)
        FSEventStreamRelease(entry.stream)
        entry.box.release()
    }

    // MARK: - Debounce

    /// Consume the raw stream and re-emit per worktree on a trailing
    /// edge: each new raw event for an id cancels that id's pending
    /// timer and starts a fresh one, so a burst collapses to a single
    /// notification `debounceInterval` after the last write.
    private func startDebounce() {
        debounceTask = Task { [rawStream, publicContinuation, debounceInterval] in
            // `pending` is touched only inside this single serial loop,
            // so it needs no locking. Inner timer tasks just sleep+yield.
            var pending: [WorktreeID: Task<Void, Never>] = [:]
            for await id in rawStream {
                pending[id]?.cancel()
                pending[id] = Task {
                    try? await Task.sleep(for: debounceInterval)
                    guard !Task.isCancelled else { return }
                    publicContinuation.yield(id)
                }
            }
            for timer in pending.values {
                timer.cancel()
            }
        }
    }

    // MARK: - Path filtering

    /// `true` when at least one path is a real worktree edit rather than
    /// git's own bookkeeping. We drop events confined to `.git/` so our
    /// own `git status` runs (and git's index churn) don't loop back in
    /// as change notifications. Extracted as a pure static so the filter
    /// is unit-testable without spinning up FSEvents.
    static func containsMeaningfulChange(_ paths: [String]) -> Bool {
        paths.contains { !$0.contains("/.git/") }
    }
}

/// Boxed context handed to the C callback. `@unchecked Sendable` because
/// it carries only an immutable id and the thread-safe stream
/// continuation across the C boundary.
private final class CallbackBox: @unchecked Sendable {
    let id: WorktreeID
    let continuation: AsyncStream<WorktreeID>.Continuation
    init(id: WorktreeID, continuation: AsyncStream<WorktreeID>.Continuation) {
        self.id = id
        self.continuation = continuation
    }
}

/// FSEvents C callback. With `UseCFTypes` set, `eventPaths` is a CFArray
/// of CFString. We yield the worktree id (raw, pre-debounce) whenever a
/// non-`.git/` path changed.
private let fsEventsCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    if FSEventCoordinator.containsMeaningfulChange(paths) {
        box.continuation.yield(box.id)
    }
}
