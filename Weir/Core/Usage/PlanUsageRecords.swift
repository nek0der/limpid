// PlanUsageRecords.swift
// Weir — the plan usage records the status line relay writes, and a signal when one changes.

import Foundation
import OSLog

private let log = Logger.weir("usage.records")

/// Where the agents' plan usage records are read from; the store's seam, so a
/// test hands it records without a directory to watch.
@MainActor
protocol PlanUsageRecordSource: AnyObject {
    /// The agent's record, or `nil` when it has none yet.
    func record(for agent: AgentKind) -> PlanUsage?
    /// Calls `onChange` after a record is written, from now on.
    func watch(_ onChange: @escaping @MainActor () -> Void)
}

/// The usage directory the relay writes into, one `<agent>.json` per agent
/// (`AgentProviderRegistry.usageDirectory`).
@MainActor
final class PlanUsageRecordDirectory: PlanUsageRecordSource {
    private let directory: URL
    private var onChange: (@MainActor () -> Void)?
    private var reloadTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so deinit, nonisolated under Swift 6, can cancel
    /// the source; the source's cancel handler closes the descriptor it
    /// captured. Optional until `watch` opens it.
    private nonisolated(unsafe) var source: (any DispatchSourceFileSystemObject)?

    /// The relay writes by rename, which arrives as a burst of events.
    private static let debounce: Duration = .milliseconds(200)

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        source?.cancel()
    }

    nonisolated static func recordURL(for agent: AgentKind, in directory: URL) -> URL {
        directory.appendingPathComponent("\(agent.rawValue).json", isDirectory: false)
    }

    func record(for agent: AgentKind) -> PlanUsage? {
        // `try?`: no record yet is the usual case, and an unreadable one is
        // replaced by the relay's next write.
        guard let data = try? Data(contentsOf: Self.recordURL(for: agent, in: directory)) else { return nil }
        do {
            return try PlanUsage.decode(data)
        } catch {
            log.error("\(agent.rawValue, privacy: .public) usage record unreadable: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    func watch(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard source == nil else { return }
        // The directory may not exist before the first record, and an open
        // of a missing one would leave nothing watched.
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("could not watch the usage directory: errno \(errno, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func scheduleChange() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
