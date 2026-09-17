// AgentMirrorRequestWatcher.swift
// Limpid — reads the requests shims leave for agent mirror tabs, once each.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.agent-requests")

/// Whether anything is reading the requests a shim would write.
///
/// A shim that is told to host an agent gets no answer of its own: it writes
/// its request, says it worked, and returns to the prompt. So the pane is
/// only told to host once a watcher is reading that directory — the same
/// shape as `AgentTmuxSupport`, and for the same reason. Without it a
/// directory the watcher refused, or a launch that starts no watcher at all
/// (demo mode), would still get the variables, and the agent would run where
/// no tab ever opens.
enum AgentMirrorIntake: Equatable {
    /// No watcher has been started yet this launch.
    case pending
    /// A watcher was started and could not read the directory, or none is
    /// wanted this launch.
    case unavailable
    /// Requests written in `directory` are being read.
    case watching(directory: URL)

    /// The directory to name to a pane, or `nil` when no pane may be told to
    /// host an agent.
    var directoryPath: String? {
        guard case let .watching(directory) = self else { return nil }
        return directory.path
    }
}

/// Watches the request directory (`AgentMirrorRequest`) and hands each
/// request to `open` once. The same shape as the projection's watch of the
/// hook directories: a directory event only says to look again, and each
/// look reads every file there, so a missed event costs nothing.
///
/// A file is removed as soon as it has been read, whatever it held, so a
/// request is acted on at most once and a malformed one does not come back
/// on every event. A request whose leaf a tab already holds is dropped
/// unopened: that tab is the agent's, and the request was already served,
/// by this run or, for a file left from before a relaunch, by the restored
/// session. `start` looks once before any event, for the requests written
/// while no watcher ran; those are confirmed against the server they name
/// before a tab is opened on them, because that server may have been
/// replaced in the meantime.
@MainActor
final class AgentMirrorRequestWatcher {
    private let directory: URL
    private let ownSocketPath: String
    private let hasLeaf: (UUID) -> Bool
    private let confirmGeneration: (AgentMirrorRequest) async -> Bool
    private let open: (AgentMirrorRequest) -> Void

    /// `nonisolated(unsafe)` so `deinit`, which is nonisolated under Swift 6,
    /// can cancel it. The source owns its descriptor (see `start`).
    private nonisolated(unsafe) var source: (any DispatchSourceFileSystemObject)?

    /// How old a hidden temporary file has to be before a scan removes it.
    /// Far longer than the moment between a shim's write and its rename, so
    /// no scan can take a file a shim is still writing, and short enough that
    /// what `SIGKILL` left behind does not outlive the day.
    static let temporaryFileLifetime: TimeInterval = 60 * 60

    init(
        directory: URL = AgentMirrorRequest.defaultDirectory(),
        ownSocketPath: String = PaneShellEnvironment.defaultAgentSocketPath(),
        hasLeaf: @escaping (UUID) -> Bool,
        confirmGeneration: @escaping (AgentMirrorRequest) async -> Bool,
        open: @escaping (AgentMirrorRequest) -> Void
    ) {
        self.directory = directory
        self.ownSocketPath = ownSocketPath
        self.hasLeaf = hasLeaf
        self.confirmGeneration = confirmGeneration
        self.open = open
    }

    deinit {
        source?.cancel()
    }

    /// Makes the directory private to this user, watches it, and reads what
    /// is already there. A directory another user could write into is not
    /// watched at all: a request says which server to attach a tab to, so
    /// only the user's own files may be taken as one.
    ///
    /// The answer is what a pane reads before it tells a shim to host an
    /// agent (`AgentMirrorIntake`), so a refusal here is also what keeps a
    /// request from ever being written.
    @discardableResult
    func start() -> AgentMirrorIntake {
        stop()
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        guard Self.makeUserOnlyDirectory(directory) else {
            log.error("not watching \(self.directory.path, privacy: .private): not a directory only this user can use")
            return .unavailable
        }
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("cannot watch \(self.directory.path, privacy: .private): errno=\(errno, privacy: .public)")
            return .unavailable
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        // Captured by value so the close belongs to the source's lifetime.
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
        scan(isCatchUp: true)
        return .watching(directory: directory)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Reads, removes, and acts on every request in the directory, oldest
    /// name first so two requests from one moment open in a stable order.
    func scan() {
        scan(isCatchUp: false)
    }

    /// `isCatchUp` marks the one look `start` takes, whose requests were
    /// written while no watcher ran — before this launch, in general. The
    /// server they name may have been replaced since, so they are confirmed
    /// against it before a tab attaches to anything (design §6 decision 6).
    private func scan(isCatchUp: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard !name.hasPrefix(".") else {
                removeStaleTemporary(file, name: name)
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let data = Self.readOwnFile(file)
            removeRequest(file)
            guard let data else {
                log.error("dropped request \(name, privacy: .private): not a private regular file")
                continue
            }
            handle(data, name: name, isCatchUp: isCatchUp)
        }
    }

    /// A shim killed between its write and its rename leaves its hidden file
    /// behind, and no trap runs for `SIGKILL`. Nothing will ever rename it,
    /// so a scan that finds one old enough to be nobody's removes it.
    private func removeStaleTemporary(_ file: URL, name: String) {
        guard name.hasSuffix(".json.tmp") else { return }
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
        let age = Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)
        guard age > Self.temporaryFileLifetime else { return }
        try? FileManager.default.removeItem(at: file)
        log.notice("removed leftover \(name, privacy: .private)")
    }

    private func handle(_ data: Data, name: String, isCatchUp: Bool) {
        let request: AgentMirrorRequest
        do {
            request = try AgentMirrorRequest.parse(data, ownSocketPath: ownSocketPath)
        } catch {
            log.error("dropped request \(name, privacy: .private): \(String(describing: error), privacy: .public)")
            return
        }
        guard !hasLeaf(request.leafID) else {
            log.notice("request \(name, privacy: .private) already has its tab")
            return
        }
        guard !isCatchUp else {
            confirmThenOpen(request, name: name)
            return
        }
        open(request)
    }

    /// Opens a request found at launch, once its server answers as the one
    /// the agent was started on.
    ///
    /// Between the write and this look the application was not running, so
    /// the server may have been killed and started again on the same socket,
    /// numbering its sessions from zero: attaching then would show a session
    /// that has nothing to do with the request. A server that cannot be asked
    /// leaves the request unopened rather than guessed at; the run is still
    /// reachable as a detached runtime if it is there at all.
    private func confirmThenOpen(_ request: AgentMirrorRequest, name: String) {
        Task { [weak self] in
            guard let self else { return }
            let isCurrent = await confirmGeneration(request)
            // A tab may have taken the leaf while the server was answering,
            // and a watcher that has been stopped opens nothing at all.
            guard source != nil, !hasLeaf(request.leafID) else { return }
            guard isCurrent else {
                log.notice("dropped request \(name, privacy: .private): its tmux server is not the one it named")
                return
            }
            open(request)
        }
    }

    /// Confirms a request against the server it names, as the reconnect at
    /// launch confirms a binding. `nil` for the tmux path — no tmux to ask
    /// with — refuses every request, since nothing can say the server is the
    /// recorded one.
    static func generationConfirmation(tmuxPath: String?) -> (AgentMirrorRequest) async -> Bool {
        { request in
            guard let tmuxPath else { return false }
            let verdict = await TmuxServerGeneration.check(tmuxPath: tmuxPath, binding: request.binding)
            return verdict == .matches(hasSession: true)
        }
    }

    private func removeRequest(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            // Left behind, the file is read again on the next look and then
            // dropped as already served, since its tab exists by then.
            log.error("cannot remove \(file.lastPathComponent, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    /// The file's bytes when it is a regular file of this user's that no one
    /// else may read or write, and small enough to be a request; nil
    /// otherwise. `O_NOFOLLOW` keeps a symlink from standing in for a
    /// request, and the checks run on the descriptor that is read.
    private static func readOwnFile(_ file: URL) -> Data? {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_size <= AgentMirrorRequest.byteLimit
        else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            // An empty file reads as nil; it is dropped as malformed.
            return try handle.read(upToCount: AgentMirrorRequest.byteLimit + 1) ?? Data()
        } catch {
            return nil
        }
    }

    /// Whether the directory is one only this user can use, narrowing it if
    /// it is not.
    ///
    /// `ensureUserOnlyDirectory` sets the mode of a directory it creates, and
    /// leaves the mode of one that is already there — a directory an earlier
    /// build made under a wider umask, or one the user widened. Narrowing it
    /// is the repair: the path is ours, and the alternative is a launch that
    /// never reads a request again. A path that is not our own directory at
    /// all is refused rather than replaced, and no pane is then told to host.
    private static func makeUserOnlyDirectory(_ directory: URL) -> Bool {
        guard let info = ownDirectory(directory) else { return false }
        guard info.st_mode & (S_IRWXG | S_IRWXO) != 0 else { return true }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            log.error("cannot narrow \(directory.path, privacy: .private): errno=\(errno, privacy: .public)")
            return false
        }
        log.notice("narrowed \(directory.path, privacy: .private) to this user")
        return ownDirectory(directory).map { $0.st_mode & (S_IRWXG | S_IRWXO) == 0 } ?? false
    }

    /// The directory's own `stat`, and `nil` when the path is a link, is not
    /// a directory, or belongs to someone else.
    private static func ownDirectory(_ directory: URL) -> stat? {
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid()
        else { return nil }
        return info
    }
}
