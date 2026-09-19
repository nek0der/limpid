// AgentMirrorRequestTests.swift
// Limpid — which files are taken as a shim's request for an agent mirror tab, and that each is acted on once.

import Foundation
import Testing
@testable import Limpid

/// A socket name `PaneShellEnvironment.isAgentSocketName` accepts, standing
/// in for this build's own.
private let ownSocketName = "limpid-dev.limpid.Limpid.tests"
private let serverDirectory = "/tmp/tmux-\(getuid())"
/// The whole path a request is compared against, as the watcher resolves it
/// once at startup.
private let ownSocketPath = TmuxClientProbe.normalizeSocketPath("\(serverDirectory)/\(ownSocketName)")

/// The request as a shim would write it, with any field replaced.
private func requestJSON(_ overrides: [String: Any] = [:], removing removed: [String] = []) throws -> Data {
    var object: [String: Any] = [
        "version": 1,
        "socket": "\(serverDirectory)/\(ownSocketName)",
        "sessionID": "$3",
        "sessionName": "limpid-1a2b3c4d-4242",
        "windowID": "@12",
        "paneID": "%0",
        "serverPID": "4100",
        "serverStartedAt": "1758130000",
        "leafID": "6F1C2B0A-6E0B-4D1A-9E43-3C5F0C7A1B11",
        "launchPaneID": "0B7D9E55-2C47-4F6B-8B39-54A1F8B0C2D3",
        "provider": "claude"
    ]
    for (key, value) in overrides {
        object[key] = value
    }
    for key in removed {
        object.removeValue(forKey: key)
    }
    return try JSONSerialization.data(withJSONObject: object)
}

private func parse(_ data: Data) -> Result<AgentMirrorRequest, AgentMirrorRequest.Rejection> {
    Result { () throws(AgentMirrorRequest.Rejection) in
        try AgentMirrorRequest.parse(data, ownSocketPath: ownSocketPath)
    }
}

@Suite("Agent mirror request")
struct AgentMirrorRequestTests {
    @Test func wellFormedRequest_isRead() throws {
        let request = try parse(requestJSON()).get()
        #expect(request.sessionID == "$3")
        #expect(request.sessionName == "limpid-1a2b3c4d-4242")
        #expect(request.windowID == "@12")
        #expect(request.paneID == "%0")
        #expect(request.leafID == UUID(uuidString: "6F1C2B0A-6E0B-4D1A-9E43-3C5F0C7A1B11"))
        #expect(request.launchPaneID == UUID(uuidString: "0B7D9E55-2C47-4F6B-8B39-54A1F8B0C2D3"))
        #expect(request.provider == .claude)
        // The binding carries the server run, so a reconnect after a
        // relaunch can check it is still the same server.
        #expect(request.binding.serverPID == "4100")
        #expect(request.binding.serverStartedAt == "1758130000")
        #expect(request.binding.socketPath == request.socketPath)
    }

    /// The binding's path is the one every other tmux boundary compares, so
    /// `/tmp` and `/private/tmp` must come out the same.
    @Test(arguments: ["/tmp", "/private/tmp"])
    func socketPath_isNormalized(prefix: String) throws {
        let request = try parse(requestJSON(["socket": "\(prefix)/tmux-\(getuid())/\(ownSocketName)"])).get()
        #expect(request.socketPath == "/private/tmp/tmux-\(getuid())/\(ownSocketName)")
    }

    /// The user's own server and another build's agent server are not where
    /// this build starts its agents. The last of these is the one a name alone would let through: the same
    /// socket name under a `TMUX_TMPDIR` of the user's choosing is a server
    /// this build never started.
    @Test(arguments: [
        "\(serverDirectory)/default",
        "\(serverDirectory)/limpid-dev.limpid.Limpid",
        "\(serverDirectory)/limpid-dev.limpid.Limpid.tests-other",
        "/tmp/\(ownSocketName)-elsewhere",
        "/tmp/\(ownSocketName)"
    ])
    func foreignSocket_isRefused(socket: String) throws {
        let result = try parse(requestJSON(["socket": socket]))
        #expect(throws: AgentMirrorRequest.Rejection.foreignSocket) { try result.get() }
    }

    @Test func relativeSocket_isRefused() throws {
        #expect(throws: AgentMirrorRequest.Rejection.malformedField("socket")) {
            try parse(requestJSON(["socket": ownSocketName])).get()
        }
    }

    @Test(arguments: [
        ("sessionID", "3"), ("sessionID", "$"), ("sessionID", "$3;kill-server"), ("sessionID", "@3"),
        ("windowID", "12"), ("windowID", "@1 2"), ("windowID", "%12"),
        ("paneID", "0"), ("paneID", "%-1"), ("paneID", "%0x"),
        ("serverPID", ""), ("serverPID", "-1"), ("serverPID", "12a"),
        ("serverStartedAt", "1e9"), ("serverStartedAt", "99999999999999999999"),
        ("sessionName", ""), ("sessionName", "a\nb"),
        ("sessionName", String(repeating: "s", count: AgentMirrorRequest.sessionNameByteLimit + 1)),
        ("leafID", "not-a-uuid"), ("leafID", ""),
        ("launchPaneID", "6F1C2B0A")
    ])
    func malformedField_isRefused(field: String, value: String) throws {
        #expect(throws: AgentMirrorRequest.Rejection.malformedField(field)) {
            try parse(requestJSON([field: value])).get()
        }
    }

    /// A shim writes every value as a string; a number in its place is not
    /// what version 1 says.
    @Test func numberInPlaceOfString_isRefused() throws {
        #expect(throws: AgentMirrorRequest.Rejection.notJSON) {
            try parse(requestJSON(["serverPID": 4100])).get()
        }
    }

    @Test func missingField_isRefused() throws {
        #expect(throws: AgentMirrorRequest.Rejection.notJSON) {
            try parse(requestJSON(removing: ["leafID"])).get()
        }
    }

    @Test func notJSON_isRefused() {
        #expect(throws: AgentMirrorRequest.Rejection.notJSON) {
            try parse(Data("leaf=1".utf8)).get()
        }
    }

    @Test func otherVersion_isRefused() throws {
        #expect(throws: AgentMirrorRequest.Rejection.unsupportedVersion(2)) {
            try parse(requestJSON(["version": 2])).get()
        }
    }

    @Test func unknownProvider_isRefused() throws {
        #expect(throws: AgentMirrorRequest.Rejection.unknownProvider("gemini")) {
            try parse(requestJSON(["provider": "gemini"])).get()
        }
    }

    @Test func unknownKey_isIgnored() {
        #expect((try? parse(requestJSON(["future": true])).get()) != nil)
    }

    /// The variable is the one A7's shim reads; the host carries it only
    /// when the pane is told to host its agents.
    @Test func paneEnvironment_namesTheDirectoryOnlyWhenHosting() {
        let host = PaneShellEnvironment.agentTmuxAnswer(
            hostsAgentsInTmux: true,
            support: .supported(
                binary: "/opt/homebrew/bin/tmux",
                version: TmuxVersion(major: 3, minor: 5, patch: nil, isDevelopment: false)
            ),
            intake: .watching(directory: URL(fileURLWithPath: "/private/tmp/requests", isDirectory: true)),
            socketName: ownSocketName
        ).host
        let hosted = PaneShellEnvironment.variables(paneID: nil, shimDirectories: [], zdotdir: nil, basePath: "/usr/bin", agentTmux: host)
        #expect(hosted["LIMPID_AGENT_MIRROR_REQUESTS_DIR"] == "/private/tmp/requests")
        let direct = PaneShellEnvironment.variables(paneID: nil, shimDirectories: [], zdotdir: nil, basePath: "/usr/bin", agentTmux: nil)
        #expect(direct["LIMPID_AGENT_MIRROR_REQUESTS_DIR"] == nil)
    }

    /// A shim that is told to host says it worked and returns to the prompt,
    /// so nothing is told to host until a watcher is reading the requests.
    /// Without this a launch that opens no watcher — demo mode, or a
    /// directory the watcher refused — would start agents where no tab ever
    /// appears.
    @Test(arguments: [AgentMirrorIntake.pending, .unavailable])
    func paneEnvironment_withoutAnIntake_doesNotHost(intake: AgentMirrorIntake) {
        let host = PaneShellEnvironment.agentTmuxAnswer(
            hostsAgentsInTmux: true,
            support: .supported(
                binary: "/opt/homebrew/bin/tmux",
                version: TmuxVersion(major: 3, minor: 5, patch: nil, isDevelopment: false)
            ),
            intake: intake,
            socketName: ownSocketName
        ).host
        #expect(host == nil)
    }

    /// The path a request's socket is compared against is the one
    /// `tmux -L <name>` resolves for this build.
    @Test func defaultAgentSocketPath_isTheServerDirectoryEntry() {
        let expected = TmuxClientProbe.defaultServerDirectory()
            .appendingPathComponent(PaneShellEnvironment.defaultAgentSocketName(), isDirectory: false)
        #expect(PaneShellEnvironment.defaultAgentSocketPath()
            == TmuxClientProbe.normalizeSocketPath(expected.path))
    }

    /// Each build reads only what its own panes wrote.
    @Test func defaultDirectory_isUnderTheBuildsOwnSupportDirectory() {
        let directory = AgentMirrorRequest.defaultDirectory()
        #expect(directory.deletingLastPathComponent().standardizedFileURL
            == LimpidPaths.applicationSupportDirectory().standardizedFileURL)
    }
}

// MARK: - Watcher

/// A file a watcher must remove without opening it, one reason each, so a
/// case that stops being refused is named by the failure.
/// Internal rather than private: a private argument type would force the
/// test method that takes it to be `fileprivate`.
enum AgentMirrorInvalidRequest: String, CaseIterable, CustomTestStringConvertible {
    case truncatedJSON
    case foreignSocket
    case malformedLeafID
    case empty
    /// Not a file a shim with `umask 077` wrote.
    case readableByOthers
    case overByteLimit

    var testDescription: String {
        rawValue
    }

    /// `0o600` unless the case is about the mode itself.
    var mode: Int {
        self == .readableByOthers ? 0o644 : 0o600
    }

    func bytes() throws -> Data {
        switch self {
        case .truncatedJSON: Data("{".utf8)
        case .foreignSocket: try requestJSON(["socket": "\(serverDirectory)/default"])
        case .malformedLeafID: try requestJSON(["leafID": "nope"])
        case .empty: Data()
        case .readableByOthers: try requestJSON()
        case .overByteLimit: Data(count: AgentMirrorRequest.byteLimit + 1)
        }
    }
}

/// A watcher over a scratch directory that records what it was asked to open.
@MainActor
private final class WatcherHarness {
    /// What the watcher's closures read and write, apart from the harness
    /// so the watcher can be built in `init`.
    final class Record {
        var leaves: Set<UUID> = []
        var opened: [AgentMirrorRequest] = []
        /// The requests the watcher asked to confirm against their server,
        /// which is the ones it found at startup.
        var confirmed: [AgentMirrorRequest] = []
        /// What that confirmation answers.
        var isServerCurrent = true
    }

    let directory: URL
    let record = Record()
    let watcher: AgentMirrorRequestWatcher

    var opened: [AgentMirrorRequest] {
        record.opened
    }

    init(root: URL, ownSocketPath: String = ownSocketPath, isServerCurrent: Bool = true) {
        directory = root.appendingPathComponent("requests", isDirectory: true)
        record.isServerCurrent = isServerCurrent
        let record = record
        watcher = AgentMirrorRequestWatcher(
            directory: directory,
            ownSocketPath: ownSocketPath,
            hasLeaf: { record.leaves.contains($0) },
            confirmGeneration: { request in
                record.confirmed.append(request)
                return record.isServerCurrent
            },
            open: { record.opened.append($0) }
        )
    }

    /// Writes `data` the way a shim does: a hidden file, then a rename.
    @discardableResult
    func write(_ data: Data, name: String, mode: Int = 0o600) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(name).tmp")
        #expect(FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]))
        let file = directory.appendingPathComponent(name)
        #expect(rename(temporary.path, file.path) == 0)
        return file
    }

    func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

@Suite("Agent mirror request watcher", .tags(.smoke))
@MainActor
struct AgentMirrorRequestWatcherTests {
    private static let leaf = UUID(uuidString: "6F1C2B0A-6E0B-4D1A-9E43-3C5F0C7A1B11")

    @Test func start_createsAPrivateDirectory() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            #expect(harness.watcher.start() == .watching(directory: harness.directory))
            let attributes = try FileManager.default.attributesOfItem(atPath: harness.directory.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o700)
        }
    }

    /// A request written while no watcher ran, such as just before a
    /// relaunch, is served when watching starts — once its server has
    /// answered as the one the agent was started on.
    @Test func start_servesRequestsAlreadyThere_andRemovesThem() async throws {
        try await withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            try harness.write(requestJSON(), name: "a.json")

            harness.watcher.start()

            #expect(await waitUntil { harness.opened.count == 1 })
            #expect(harness.opened.map(\.leafID) == [Self.leaf])
            #expect(harness.record.confirmed.map(\.leafID) == [Self.leaf])
            #expect(harness.contents().isEmpty)
        }
    }

    /// While the application was not running, the server on that socket may
    /// have been killed and started again, numbering its sessions from zero:
    /// attaching then would show a session that has nothing to do with the
    /// request.
    @Test func start_whenTheServerWasReplaced_dropsTheRequest() async throws {
        try await withTempDir { root in
            let harness = WatcherHarness(root: root, isServerCurrent: false)
            defer { harness.watcher.stop() }
            try harness.write(requestJSON(), name: "a.json")

            harness.watcher.start()

            #expect(await waitUntil { harness.record.confirmed.count == 1 })
            #expect(harness.opened.isEmpty)
            #expect(harness.contents().isEmpty)
        }
    }

    /// A directory an earlier build left readable by others is narrowed
    /// rather than refused: the path is ours, and refusing it would cost
    /// every launch after it its requests.
    @Test func start_narrowsADirectoryOthersCouldUse() async throws {
        try await withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            try harness.write(requestJSON(), name: "a.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: harness.directory.path)

            #expect(harness.watcher.start() == .watching(directory: harness.directory))

            let attributes = try FileManager.default.attributesOfItem(atPath: harness.directory.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o700)
            #expect(await waitUntil { harness.opened.count == 1 })
        }
    }

    /// Anything that is not our own directory is refused, and the intake
    /// says so — which is what keeps a pane from being told to host an agent
    /// whose request nothing would read.
    @Test func start_whenThePathIsNotOurDirectory_reportsNoIntake() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: harness.directory, withDestinationURL: elsewhere)

            #expect(harness.watcher.start() == .unavailable)
            #expect(harness.opened.isEmpty)
        }
    }

    @Test func requestWrittenWhileWatching_isServedOnce() async throws {
        try await withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            harness.watcher.start()

            try harness.write(requestJSON(), name: "b.json")

            #expect(await waitUntil { harness.opened.count == 1 })
            // Written by a shim of this run: the server it names is the one
            // this application is watching, so nothing is asked of tmux.
            #expect(harness.record.confirmed.isEmpty)
            #expect(harness.contents().isEmpty)
            // Another look finds nothing left to open.
            harness.watcher.scan()
            #expect(harness.opened.count == 1)
        }
    }

    /// The leaf already has its tab: this run served the request, or the
    /// restored session holds the tab it opened before the relaunch.
    @Test func requestForALeafATabHolds_isDroppedUnopened() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            harness.record.leaves = try [#require(Self.leaf)]
            try harness.write(requestJSON(), name: "c.json")

            harness.watcher.start()

            #expect(harness.opened.isEmpty)
            // The tab is the answer; nothing is asked of tmux for it.
            #expect(harness.record.confirmed.isEmpty)
            #expect(harness.contents().isEmpty)
        }
    }

    @Test(arguments: AgentMirrorInvalidRequest.allCases)
    func invalidRequest_isRemovedUnopened(invalid: AgentMirrorInvalidRequest) throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            try harness.write(invalid.bytes(), name: "a.json", mode: invalid.mode)

            harness.watcher.start()

            #expect(harness.opened.isEmpty)
            #expect(harness.contents().isEmpty)
        }
    }

    /// A symlink cannot stand in for a request, even to a valid one.
    @Test func symlinkedRequest_isRemovedUnopened() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            let real = root.appendingPathComponent("real.json")
            #expect(try FileManager.default.createFile(atPath: real.path, contents: requestJSON(), attributes: [.posixPermissions: 0o600]))
            try FileManager.default.createDirectory(
                at: harness.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createSymbolicLink(at: harness.directory.appendingPathComponent("link.json"), withDestinationURL: real)

            harness.watcher.start()

            #expect(harness.opened.isEmpty)
            #expect(harness.contents().isEmpty)
            #expect(FileManager.default.fileExists(atPath: real.path))
        }
    }

    /// A shim's file on its way in, and anything that is not a request, stay
    /// where they are.
    @Test func hiddenAndOtherFiles_areLeftAlone() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            try FileManager.default.createDirectory(
                at: harness.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let pending = harness.directory.appendingPathComponent(".d.json.tmp")
            let note = harness.directory.appendingPathComponent("notes.txt")
            #expect(try FileManager.default.createFile(
                atPath: pending.path,
                contents: requestJSON(),
                attributes: [.posixPermissions: 0o600]
            ))
            #expect(try FileManager.default.createFile(atPath: note.path, contents: requestJSON(), attributes: [.posixPermissions: 0o600]))

            harness.watcher.start()

            #expect(harness.opened.isEmpty)
            #expect(harness.contents() == [".d.json.tmp", "notes.txt"])
        }
    }

    /// A shim killed between its write and its rename leaves its hidden file
    /// behind — no trap runs for `SIGKILL` — and nothing will ever rename it.
    /// One still young enough to be a write in progress is left alone.
    @Test func staleTemporaries_areRemovedAndFreshOnesKept() throws {
        try withTempDir { root in
            let harness = WatcherHarness(root: root)
            defer { harness.watcher.stop() }
            try FileManager.default.createDirectory(
                at: harness.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let old = harness.directory.appendingPathComponent(".old.json.tmp")
            let fresh = harness.directory.appendingPathComponent(".fresh.json.tmp")
            for file in [old, fresh] {
                #expect(try FileManager.default.createFile(
                    atPath: file.path,
                    contents: requestJSON(),
                    attributes: [.posixPermissions: 0o600]
                ))
            }
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -AgentMirrorRequestWatcher.temporaryFileLifetime - 60)],
                ofItemAtPath: old.path
            )

            harness.watcher.start()

            #expect(harness.contents() == [".fresh.json.tmp"])
            #expect(harness.opened.isEmpty)
        }
    }
}

// MARK: - Startup order

@Suite("Agent mirror requests at launch", .tags(.smoke))
@MainActor
struct AgentMirrorRequestStartupTests {
    /// The launch settles the restored session first and starts watching
    /// after it (`LimpidApp`: `reconcileRestoredBindings` then
    /// `startAgentMirrorRequests`). In the other order the catch-up scan
    /// would read a request whose tab the restore is about to bring back,
    /// and every relaunch would leave the same agent with a second tab.
    ///
    /// The request here is the real thing: it names the socket this build
    /// starts its agents on, and the second half shows a watcher does open
    /// it when no tab holds its leaf. So the silence in the first half is
    /// the restored tab, not a request the watcher refused for some other
    /// reason.
    @Test func watchingStartedAfterTheRestore_leavesARestoredTabAlone() async throws {
        try await withTempDir { root in
            let (session, _, leaf) = WindowSessionFixture.withLooseTab()
            let socketPath = PaneShellEnvironment.defaultAgentSocketPath()
            let json = try requestJSON(["socket": socketPath, "leafID": leaf.uuidString])
            let requests = root.appendingPathComponent("requests", isDirectory: true)
            try FileManager.default.createDirectory(
                at: requests,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            #expect(FileManager.default.createFile(
                atPath: requests.appendingPathComponent("a.json").path,
                contents: json,
                attributes: [.posixPermissions: 0o600]
            ))

            // A tmux that records having been run and then answers nothing.
            // Nothing should run it: the tab is the answer, and asking the
            // server is what a watcher started before the restore would do.
            let asked = root.appendingPathComponent("asked")
            let tmux = root.appendingPathComponent("tmux-stub")
            try "#!/bin/sh\n: >> '\(asked.path)'\nexit 1\n".write(to: tmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)

            let settings = SettingsStore(directory: root)
            let watcher = AppState.startAgentMirrorRequests(
                session: session,
                store: TmuxConnectionStore(
                    registry: RecordingSurfaceRegistry(),
                    secureInput: nil,
                    tmuxExecutable: tmux.path
                ),
                settings: settings,
                directory: requests
            )
            defer { watcher?.stop() }

            #expect(settings.agentMirrorIntake == .watching(directory: requests))
            #expect(session.tabs.count == 1)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: requests.path)) == [])

            // The same request, read by a watcher whose session holds no
            // such leaf: this one takes it up, so the silence above is the
            // restored tab rather than a request that would be refused
            // anyway.
            let harness = WatcherHarness(
                root: root.appendingPathComponent("second", isDirectory: true),
                ownSocketPath: socketPath
            )
            defer { harness.watcher.stop() }
            try harness.write(json, name: "a.json")
            harness.watcher.start()
            #expect(await waitUntil { harness.opened.map(\.leafID) == [leaf] })

            // Long enough for a confirmation, which runs in a task of its
            // own, to have reached the stub if one had been made.
            #expect(await waitUntil(.milliseconds(500)) {
                FileManager.default.fileExists(atPath: asked.path)
            } == false)
        }
    }
}
