// AgentMirrorRequestWatcher.swift
// Limpid — reads the requests shims leave for agent mirror tabs, once each.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.agent-requests")

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
/// while no watcher ran.
@MainActor
final class AgentMirrorRequestWatcher {
    private let directory: URL
    private let ownSocketName: String
    private let hasLeaf: (UUID) -> Bool
    private let open: (AgentMirrorRequest) -> Void

    /// `nonisolated(unsafe)` so `deinit`, which is nonisolated under Swift 6,
    /// can cancel it. The source owns its descriptor (see `start`).
    private nonisolated(unsafe) var source: (any DispatchSourceFileSystemObject)?

    init(
        directory: URL = AgentMirrorRequest.defaultDirectory(),
        ownSocketName: String = PaneShellEnvironment.defaultAgentSocketName(),
        hasLeaf: @escaping (UUID) -> Bool,
        open: @escaping (AgentMirrorRequest) -> Void
    ) {
        self.directory = directory
        self.ownSocketName = ownSocketName
        self.hasLeaf = hasLeaf
        self.open = open
    }

    deinit {
        source?.cancel()
    }

    /// Creates the directory if it is missing, watches it, and reads what is
    /// already there. A directory another user could write into is not
    /// watched at all: a request says which server to attach a tab to, so
    /// only the user's own files may be taken as one.
    func start() {
        stop()
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        guard Self.isPrivateDirectory(directory) else {
            log.error("not watching \(self.directory.path, privacy: .private): not a directory only this user can use")
            return
        }
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("cannot watch \(self.directory.path, privacy: .private): errno=\(errno, privacy: .public)")
            return
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
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Reads, removes, and acts on every request in the directory, oldest
    /// name first so two requests from one moment open in a stable order.
    func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") && name.hasSuffix(".json") {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            let data = Self.readOwnFile(file)
            removeRequest(file)
            guard let data else {
                log.error("dropped request \(name, privacy: .private): not a private regular file")
                continue
            }
            handle(data, name: name)
        }
    }

    private func handle(_ data: Data, name: String) {
        let request: AgentMirrorRequest
        do {
            request = try AgentMirrorRequest.parse(data, ownSocketName: ownSocketName)
        } catch {
            log.error("dropped request \(name, privacy: .private): \(String(describing: error), privacy: .public)")
            return
        }
        guard !hasLeaf(request.leafID) else {
            log.notice("request \(name, privacy: .private) already has its tab")
            return
        }
        open(request)
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

    private static func isPrivateDirectory(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && info.st_mode & (S_IRWXG | S_IRWXO) == 0
    }
}
