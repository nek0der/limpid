// AgentShimLaunchTests.swift
// Limpid — runs each agent's shim from the source tree against stand-in
// agents on disk: which one it starts, on which PATH, and what it hands on.

import Foundation
import Testing
@testable import Limpid

@Suite(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct AgentShimLaunchTests {
    /// Starts `kind`'s shim with no arguments as a pane's shell would: on
    /// `path`, with the catalog's list (home locations only, as in
    /// `homeEntries`) and `environment` in the environment. `nil` when it
    /// has not exited after ten seconds.
    private static func startShim(
        _ kind: AgentKind,
        home: URL,
        scratch: URL,
        path: String = "/usr/bin:/bin",
        environment: [String: String] = [:]
    ) throws -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = try [AgentCatalogFixture.shim(for: kind).path]
        process.environment = AgentCatalog.knownLocationsEnvironment(home: home.path, entries: AgentCatalogFixture.homeEntries)
            .merging(["PATH": path, "HOME": home.path, "TMPDIR": scratch.path]) { _, new in new }
            .merging(environment) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process.waitUntilExit(within: 10) ? process.terminationStatus : nil
    }

    /// A stand-in agent at `url` that writes how it was started, its `$0`
    /// and its `PATH`, to `record`.
    private static func makeRecordingAgent(_ url: URL, record: URL) throws {
        try AgentCatalogFixture.makeExecutable(url, script: "#!/bin/sh\nprintf '%s\\n%s\\n' \"$0\" \"$PATH\" > \"\(record.path)\"\n")
    }

    /// The `$0` and `PATH` a recording agent wrote, empty when none ran.
    private static func recorded(_ record: URL) -> [String] {
        ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// An agent the sheet offers because it sits where a version manager
    /// puts it is one the pane's shim can start: the shim searches the same
    /// known locations the catalog does, not a list of its own.
    @Test
    func onDisk_anAgentFoundOnlyAtAKnownLocation_isTheOneItsShimStarts() throws {
        for entry in AgentCatalogFixture.homeEntries {
            for location in entry.knownLocations {
                try withTempDir { root in
                    let home = root.appendingPathComponent("home")
                    let agent = URL(fileURLWithPath: AgentCatalog.homeExpanded(location, home: home.path)
                        .replacingOccurrences(of: "/*/", with: "/v22.3.0/"))
                    let record = root.appendingPathComponent("launched")
                    try Self.makeRecordingAgent(agent, record: record)
                    #expect(AgentCatalogFixture.installedOnDisk(paths: ["/usr/bin:/bin"], home: home) == [entry.kind], "\(location)")

                    #expect(try Self.startShim(entry.kind, home: home, scratch: root) == 0, "\(location)")
                    // Its folder joins the PATH, after what the PATH had.
                    #expect(
                        Self.recorded(record) == [agent.path, "/usr/bin:/bin:\(agent.deletingLastPathComponent().path)"],
                        "\(location)"
                    )
                }
            }
        }
    }

    /// The PATH comes first, as in a terminal without Limpid, and is left
    /// as it was: the catalog's list is only for what it lacks.
    @Test
    func onDisk_anAgentOnThePath_winsOverAKnownLocation_andThePathIsLeftAlone() throws {
        for entry in AgentCatalogFixture.homeEntries {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let onPath = root.appendingPathComponent("tools/\(entry.kind.launchCommand)")
                let record = root.appendingPathComponent("launched")
                try Self.makeRecordingAgent(onPath, record: record)
                let known = try URL(fileURLWithPath: AgentCatalog.homeExpanded(#require(entry.knownLocations.first), home: home.path))
                try Self.makeRecordingAgent(known, record: record)
                let path = "\(onPath.deletingLastPathComponent().path):/usr/bin:/bin"

                #expect(try Self.startShim(entry.kind, home: home, scratch: root, path: path) == 0, "\(entry.kind)")
                #expect(Self.recorded(record) == [onPath.path, path], "\(entry.kind)")
            }
        }
    }

    @Test
    func onDisk_theOverride_winsOverThePathAndTheKnownLocations() throws {
        for entry in AgentCatalogFixture.homeEntries {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let record = root.appendingPathComponent("launched")
                let onPath = root.appendingPathComponent("tools/\(entry.kind.launchCommand)")
                try Self.makeRecordingAgent(onPath, record: record)
                let known = try URL(fileURLWithPath: AgentCatalog.homeExpanded(#require(entry.knownLocations.first), home: home.path))
                try Self.makeRecordingAgent(known, record: record)
                let override = root.appendingPathComponent("override/agent")
                try Self.makeRecordingAgent(override, record: record)
                let path = "\(onPath.deletingLastPathComponent().path):/usr/bin:/bin"
                let variable = "LIMPID_REAL_\(entry.kind.rawValue.uppercased())"

                #expect(
                    try Self.startShim(entry.kind, home: home, scratch: root, path: path, environment: [variable: override.path]) == 0,
                    "\(entry.kind)"
                )
                #expect(Self.recorded(record).first == override.path, "\(entry.kind)")
            }
        }
    }

    /// This is the gap the known locations leave: an agent that only a
    /// folder-scoped `PATH` has (mise's or direnv's, here recorded from a pane of the project),
    /// which the new pane's `PATH` lacks. The sheet's launch hands the
    /// shim the exact executable it found (`StagedLaunch.environment`), and
    /// the shim starts it on the `node` beside it.
    @Test
    func onDisk_anAgentOnlyOnTheRecordedPanePath_startsFromTheSheet_atThatExactPath() throws {
        for kind in AgentKind.allCases {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let bin = home.appendingPathComponent(".local/share/mise/installs/node/22/bin")
                let agent = bin.appendingPathComponent(kind.launchCommand)
                let ran = root.appendingPathComponent("ran")
                try AgentCatalogFixture.makeExecutable(agent, script: "#!/usr/bin/env node\n")
                let node = "#!/bin/sh\nprintf '%s\\n%s\\n' \"$1\" \"$PATH\" > \"\(ran.path)\"\n"
                try AgentCatalogFixture.makeExecutable(bin.appendingPathComponent("node"), script: node)
                let record = AgentCatalog.panePathRecordURL(in: root, project: UUID())
                try Data("\(bin.path):/usr/bin:/bin\n".utf8).write(to: record)

                // As `detectInstallations` searches: the login shell's PATH,
                // the known locations, then the last pane's.
                let panePath = try #require(AgentCatalog.recordedPanePath(at: record))
                let found = AgentCatalog.installations(
                    searchPaths: ["/usr/bin:/bin"],
                    fallbackPaths: [panePath],
                    home: home.path,
                    entries: AgentCatalogFixture.homeEntries,
                    isExecutable: AgentCatalog.isExecutableFile,
                    isShimDirectory: AgentCatalog.isShimDirectory,
                    contentsOfDirectory: AgentCatalog.contentsOfDirectory
                )
                #expect(found == [AgentInstallation(kind: kind, executable: agent.path)], "\(kind)")

                // A pane of another folder: neither its PATH nor the known
                // locations have the agent.
                #expect(try Self.startShim(kind, home: home, scratch: root) == 127, "\(kind)")
                let staged = WorkspaceSession.StagedLaunch(command: kind.launchCommand, promptFile: nil, agentExecutable: found.first)
                #expect(try Self.startShim(kind, home: home, scratch: root, environment: staged.environment) == 0, "\(kind)")
                #expect(
                    (try? String(contentsOf: ran, encoding: .utf8)) == "\(agent.path)\n/usr/bin:/bin:\(bin.path)\n",
                    "\(kind)"
                )

                // A pane whose own PATH has one (its folder's `.nvmrc`, mise
                // pin or direnv chose it) starts that one, as its terminal
                // would, and leaves the PATH as it was.
                let own = root.appendingPathComponent("project-b/bin/\(kind.launchCommand)")
                let launched = root.appendingPathComponent("launched")
                try Self.makeRecordingAgent(own, record: launched)
                let paneB = "\(own.deletingLastPathComponent().path):/usr/bin:/bin"
                #expect(try Self.startShim(kind, home: home, scratch: root, path: paneB, environment: staged.environment) == 0)
                #expect(Self.recorded(launched) == [own.path, paneB], "\(kind)")
            }
        }
    }

    /// The agent and anything it starts (a tmux server among them, which
    /// would hand it to every session after) never carry what the sheet
    /// found: the shim takes it out once read.
    @Test
    func onDisk_whatTheSheetFound_isNotHandedOnToTheAgent() throws {
        for entry in AgentCatalogFixture.homeEntries {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let agent = root.appendingPathComponent("found/\(entry.kind.launchCommand)")
                let seen = root.appendingPathComponent("seen")
                let variable = entry.foundExecutableVariable
                try AgentCatalogFixture.makeExecutable(
                    agent,
                    script: "#!/bin/sh\nprintf '%s\\n' \"${\(variable)-unset}\" > \"\(seen.path)\"\n"
                )

                #expect(try Self.startShim(entry.kind, home: home, scratch: root, environment: [variable: agent.path]) == 0)
                #expect((try? String(contentsOf: seen, encoding: .utf8)) == "unset\n", "\(entry.kind)")
            }
        }
    }

    /// What the sheet found, gone since (an update moved it), is passed
    /// over for the known locations rather than failing.
    @Test
    func onDisk_whatTheSheetFound_goneSince_isPassedOver() throws {
        for entry in AgentCatalogFixture.homeEntries {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let record = root.appendingPathComponent("launched")
                let known = try URL(fileURLWithPath: AgentCatalog.homeExpanded(#require(entry.knownLocations.first), home: home.path))
                try Self.makeRecordingAgent(known, record: record)
                let gone = root.appendingPathComponent("gone/\(entry.kind.launchCommand)").path
                let environment = [entry.foundExecutableVariable: gone]

                #expect(try Self.startShim(entry.kind, home: home, scratch: root, environment: environment) == 0)
                #expect(Self.recorded(record).first == known.path, "\(entry.kind)")
            }
        }
    }

    /// As the catalog passes it over (`isExecutableFile`): a folder is not
    /// the agent, whatever its permissions.
    @Test
    func onDisk_aFolderNamedLikeTheAgent_isPassedOver_forTheNextKnownLocation() throws {
        for entry in AgentCatalogFixture.homeEntries {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let locations = entry.knownLocations.map { AgentCatalog.homeExpanded($0, home: home.path) }
                try FileManager.default.createDirectory(atPath: locations[0], withIntermediateDirectories: true)
                let record = root.appendingPathComponent("launched")
                let agent = URL(fileURLWithPath: locations[1].replacingOccurrences(of: "/*/", with: "/v22.3.0/"))
                try Self.makeRecordingAgent(agent, record: record)
                #expect(AgentCatalogFixture.installedOnDisk(paths: ["/usr/bin:/bin"], home: home) == [entry.kind], "\(entry.kind)")

                #expect(try Self.startShim(entry.kind, home: home, scratch: root) == 0, "\(entry.kind)")
                #expect(Self.recorded(record).first == agent.path, "\(entry.kind)")
            }
        }
    }

    /// Only the star is a pattern. Taken as one, the `[v]` in this home
    /// folder would match the folder beside it named `my home v` and
    /// start the agent there.
    @Test
    func onDisk_aHomeFolderWithSpacesAndPatternCharacters_isTakenAsWritten() throws {
        for kind in AgentKind.allCases {
            try withTempDir { root in
                let home = root.appendingPathComponent("my home [v]")
                let record = root.appendingPathComponent("launched")
                let agent = home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin/\(kind.launchCommand)")
                try Self.makeRecordingAgent(agent, record: record)
                let decoy = root.appendingPathComponent("my home v/.nvm/versions/node/v99.0.0/bin/\(kind.launchCommand)")
                try Self.makeRecordingAgent(decoy, record: record)
                #expect(AgentCatalogFixture.installedOnDisk(paths: ["/usr/bin:/bin"], home: home) == [kind], "\(kind)")

                #expect(try Self.startShim(kind, home: home, scratch: root) == 0, "\(kind)")
                #expect(Self.recorded(record).first == agent.path, "\(kind)")
            }
        }
    }

    /// By version, not by character: a plain sort would start v9.0.0.
    @Test
    func onDisk_ofSeveralNvmVersions_theNewestStarts() throws {
        for kind in AgentKind.allCases {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let record = root.appendingPathComponent("launched")
                let versions = home.appendingPathComponent(".nvm/versions/node")
                for version in ["v9.0.0", "v18.20.0", "v22.3.0", "v22.10.1"] {
                    try Self.makeRecordingAgent(versions.appendingPathComponent("\(version)/bin/\(kind.launchCommand)"), record: record)
                }

                #expect(try Self.startShim(kind, home: home, scratch: root) == 0, "\(kind)")
                #expect(
                    Self.recorded(record).first == versions.appendingPathComponent("v22.10.1/bin/\(kind.launchCommand)").path,
                    "\(kind)"
                )
            }
        }
    }

    /// npm installs the CLIs as scripts that start `#!/usr/bin/env node`,
    /// and nvm keeps a version's `node` beside them. The shim starts the
    /// script on that node itself, so another node first on the `PATH`
    /// (one too old for the CLI, say) is not the one that runs it.
    @Test
    func onDisk_aNodeCLIUnderAnNvmVersion_startsOnTheNodeBesideIt_notTheOneOnThePath() throws {
        for kind in AgentKind.allCases {
            try withTempDir { root in
                let home = root.appendingPathComponent("home")
                let bin = home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin")
                let agent = bin.appendingPathComponent(kind.launchCommand)
                let ran = root.appendingPathComponent("ran")
                try AgentCatalogFixture.makeExecutable(agent, script: "#!/usr/bin/env node\n")
                let besideNode = "#!/bin/sh\nprintf 'beside %s\\n' \"$1\" > \"\(ran.path)\"\n"
                try AgentCatalogFixture.makeExecutable(bin.appendingPathComponent("node"), script: besideNode)
                let other = root.appendingPathComponent("old-node/node")
                try AgentCatalogFixture.makeExecutable(other, script: "#!/bin/sh\nprintf 'path %s\\n' \"$1\" > \"\(ran.path)\"\n")
                let path = "\(other.deletingLastPathComponent().path):/usr/bin:/bin"
                #expect(AgentCatalogFixture.installedOnDisk(paths: [path], home: home) == [kind], "\(kind)")

                #expect(try Self.startShim(kind, home: home, scratch: root, path: path) == 0, "\(kind)")
                #expect((try? String(contentsOf: ran, encoding: .utf8)) == "beside \(agent.path)\n", "\(kind)")
            }
        }
    }

    @Test
    func thePanesShell_recordsThePathItsZshrcLeftIt_whereTheCatalogFindsTheAgent() throws {
        try withTempDir { root in
            // A person's .zshrc that puts a version manager's folder first,
            // as nvm's and mise's do; a login shell never reads it.
            let home = root.appendingPathComponent("home")
            let managed = root.appendingPathComponent("managed/bin")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try AgentCatalogFixture.makeExecutable(managed.appendingPathComponent("codex"))
            try Data("export PATH=\"\(managed.path):$PATH\"\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
            let record = AgentCatalog.panePathRecordURL(in: root, project: UUID())

            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-i", "-c", "true"]
            shell.environment = try [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "ZDOTDIR": AgentCatalogFixture.shimFolder("claude-shim").appendingPathComponent("zdotdir").path,
                AgentCatalog.panePathRecordVariable: record.path
            ]
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            // A shell that hangs (a startup file waiting on input) fails
            // this test after ten seconds rather than stopping the run.
            guard shell.waitUntilExit(within: 10) else {
                Issue.record("zsh did not exit within ten seconds")
                return
            }

            let panePath = try #require(AgentCatalog.recordedPanePath(at: record))
            #expect(panePath.hasPrefix(managed.path))
            #expect(AgentCatalogFixture.installedOnDisk(paths: [panePath], home: home) == [.codex])
            // Moved into place whole: no temporary file is left beside it.
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                    == ["home", "managed", record.lastPathComponent]
            )
        }
    }

    /// Each run of an agent gets an id of its own, so an id the pane's shell
    /// inherited from an earlier run is never the new run's.
    @Test func eachInvocation_replacesTheInheritedRunID() throws {
        try withTempDir { directory in
            let helper = try AgentCatalogFixture.shimFolder("agent-shim").appendingPathComponent("runtime-common.sh")
            let inherited = "11111111-1111-1111-1111-111111111111"
            let output = directory.appendingPathComponent("ids")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
            . "$HELPER"
            limpid_ensure_run_id
            first="$LIMPID_AGENT_RUN_ID"
            [ "$LIMPID_AGENT_PARENT_RUN_ID" = "$INHERITED" ] || exit 1
            printf '%s\\n' "$first" > "$OUT"
            limpid_ensure_run_id
            [ "$LIMPID_AGENT_PARENT_RUN_ID" = "$first" ] || exit 1
            printf '%s\\n' "$LIMPID_AGENT_RUN_ID" >> "$OUT"
            """]
            process.environment = IsolatedProcessEnvironment.make([
                "PATH": ShimHarness.systemPath,
                "HOME": directory.path,
                "HELPER": helper.path,
                "OUT": output.path,
                "LIMPID_AGENT_RUN_ID": inherited,
                "INHERITED": inherited
            ])
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            #expect(process.waitUntilExit(within: 10))
            #expect(process.terminationStatus == 0)
            let ids = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(ids.count == 2)
            #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
            #expect(Set(ids).count == 2)
            #expect(!ids.contains(inherited))
        }
    }

    @Test(.disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"))
    func eachInvocation_mintsItsOwnMonotonicLaunchOrder() throws {
        let helper = try #require(HookHelperFixture.helperURL)
        try withTempDir { directory in
            let common = try AgentCatalogFixture.shimFolder("agent-shim").appendingPathComponent("runtime-common.sh")
            let output = directory.appendingPathComponent("orders")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
            . "$COMMON"
            limpid_ensure_run_id
            printf '%s\\n' "$LIMPID_AGENT_LAUNCH_ORDER" > "$OUT"
            limpid_ensure_run_id
            printf '%s\\n' "$LIMPID_AGENT_LAUNCH_ORDER" >> "$OUT"
            """]
            process.environment = IsolatedProcessEnvironment.make([
                "PATH": ShimHarness.systemPath,
                "HOME": directory.path,
                "COMMON": common.path,
                "OUT": output.path,
                "LIMPID_HOOK_HELPER": helper.path,
                "LIMPID_AGENT_LAUNCH_ORDER": "18446744073709551615"
            ])
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            #expect(process.waitUntilExit(within: 10))
            #expect(process.terminationStatus == 0)
            let orders = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").compactMap { UInt64($0) }
            #expect(orders.count == 2)
            if orders.count == 2 {
                #expect(orders[0] > 0)
                #expect(orders[1] > orders[0])
                #expect(orders[1] != UInt64.max)
            }
        }
    }

}
