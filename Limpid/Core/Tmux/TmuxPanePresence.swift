// TmuxPanePresence.swift
// Limpid — bounded topology polling joined to immutable local tty snapshots.

import Foundation

struct TmuxSurfaceSnapshot: Equatable {
    let paneID: UUID
    let tty: String?
    let foregroundPID: Int32?
    let foregroundName: String?
    var isTmuxClient: Bool {
        foregroundName == TmuxClientProbe.clientProcessName
    }
}

enum AgentAttachmentResolution: Equatable {
    case attached
    case detached
    case unresolved
}

@MainActor
@Observable
final class TmuxPanePresence {
    private(set) var paneIDs: Set<UUID> = []
    private(set) var bindingsByPaneID: [UUID: TmuxBinding] = [:]
    private(set) var topology = TmuxTopology()
    private(set) var surfaces: [TmuxSurfaceSnapshot] = []
    private(set) var detachedPaneIDs: Set<UUID> = []
    var onBindingsChanged: (() -> Void)?
    nonisolated static let pollInterval: TimeInterval = 2

    /// MainActor owns timer mutation; deinit only invalidates the resource.
    @ObservationIgnored private nonisolated(unsafe) var timer: Timer?
    private var surfaceProvider: () -> [TmuxSurfaceSnapshot] = { [] }
    private var candidateProvider: () -> Set<String> = { [] }
    private var isActive = false
    private var isClientProbeRunning = false
    private var revision = 0
    private var cursor = 0
    private static let queue = DispatchQueue(label: "dev.limpid.tmux.probe", qos: .utility)

    init(bindingsByPaneID: [UUID: TmuxBinding] = [:], topology: TmuxTopology = TmuxTopology()) {
        self.bindingsByPaneID = bindingsByPaneID
        self.topology = topology
    }

    deinit { timer?.invalidate() }

    func start(surfaces: @escaping () -> [TmuxSurfaceSnapshot], candidates: @escaping () -> Set<String>) {
        stop()
        surfaceProvider = surfaces
        candidateProvider = candidates
        isActive = true
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = Self.pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isActive = false
        revision += 1
        timer?.invalidate()
        timer = nil
    }

    /// This local observation also runs at quit; it does not launch tmux or
    /// resolve filesystem paths on MainActor.
    func refreshLocalSurfaces() {
        let next = surfaceProvider()
        for frame in next where frame.tty != nil {
            if frame.isTmuxClient {
                detachedPaneIDs.remove(frame.paneID)
            } else if surfaces.contains(where: { $0.paneID == frame.paneID && $0.isTmuxClient }) {
                detachedPaneIDs.insert(frame.paneID)
            }
        }
        if next != surfaces {
            revision += 1
            surfaces = next
        }
        paneIDs = Set(next.filter(\.isTmuxClient).map(\.paneID))
        let filtered = bindingsByPaneID.filter { paneIDs.contains($0.key) }
        if filtered != bindingsByPaneID {
            bindingsByPaneID = filtered
            onBindingsChanged?()
        }
    }

    func refresh() {
        guard isActive else { return }
        refreshLocalSurfaces()
        guard !isClientProbeRunning, let path = TmuxClientProbe.locateTmux() else { return }
        let frames = surfaces
        let requestRevision = revision
        let candidates = candidateProvider()
        let startCursor = cursor
        isClientProbeRunning = true
        Self.queue.async { [weak self] in
            let defaults = TmuxClientProbe.socketPaths(inServerDirectory: TmuxClientProbe.defaultServerDirectory())
            let batch = TmuxClientProbe.probe(tmuxPath: path, paths: candidates.union(defaults.map(\.path)), cursor: startCursor)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isClientProbeRunning = false
                guard self.isActive else { return }
                self.refreshLocalSurfaces()
                guard self.revision == requestRevision, self.surfaces == frames else {
                    self.refresh()
                    return
                }
                self.cursor = batch.nextCursor
                self.topology.merge(
                    batch.snapshot,
                    candidates: Set(batch.snapshot.socketAliases.values),
                    now: ProcessInfo.processInfo.systemUptime
                )
                self.bindingsByPaneID = Self.resolveClients(frames: frames, clients: self.topology.clients)
                // Observation can resolve a pending event without changing a binding.
                self.onBindingsChanged?()
            }
        }
    }

    static func resolveClients(frames: [TmuxSurfaceSnapshot], clients: [String: TmuxBinding]) -> [UUID: TmuxBinding] {
        var resolved: [UUID: TmuxBinding] = [:]
        for frame in frames where frame.isTmuxClient {
            guard let tty = frame.tty, frames.count(where: { $0.tty == tty }) == 1 else { continue }
            resolved[frame.paneID] = clients[tty]
        }
        return resolved
    }

    func attachments(for endpoint: TmuxRuntimeEndpoint?) -> [UUID: TmuxPaneLocation] {
        var result: [UUID: TmuxPaneLocation] = [:]
        for location in topology.locations(for: endpoint) {
            for paneID in paneIDs(socketPath: location.socketPath, sessionID: location.sessionID) {
                result[paneID] = location
            }
        }
        return result
    }

    func resolution(for endpoint: TmuxRuntimeEndpoint?) -> AgentAttachmentResolution {
        if !attachments(for: endpoint).isEmpty {
            return .attached
        }
        guard let endpoint else { return .unresolved }
        if case .success = topology.outcomes[topology.socketKey(endpoint.socketPath)] {
            return .detached
        }
        return .unresolved
    }

    func paneIDs(socketPath: String, sessionID: String) -> Set<UUID> {
        Self.paneIDs(in: bindingsByPaneID, socketPath: socketPath, sessionID: sessionID, aliases: topology.socketAliases)
    }

    nonisolated static func paneIDs(
        in bindings: [UUID: TmuxBinding], socketPath: String, sessionID: String, aliases: [String: String] = [:]
    ) -> Set<UUID> {
        let expected = aliases[socketPath] ?? socketPath
        return Set(bindings.compactMap { id, binding in
            (aliases[binding.socketPath] ?? binding.socketPath) == expected && binding.sessionID == sessionID ? id : nil
        })
    }

    nonisolated static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
