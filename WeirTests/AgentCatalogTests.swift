// AgentCatalogTests.swift
// Weir — the agents a workspace can start, in order, and which count as installed: on a pane's PATH, the login shell's, or where they are
// known to go, where the agent's shim then finds and starts them.

import Foundation
import Testing
@testable import Weir

struct AgentCatalogTests {
    @Test func everyAgent_hasOneEntry_inTheMenusOrder() {
        #expect(AgentCatalog.entries.map(\.kind) == [.claude, .codex])
        #expect(Set(AgentCatalog.entries.map(\.kind)) == Set(AgentKind.allCases))
        for kind in AgentKind.allCases {
            let entry = AgentCatalog.entry(for: kind)
            // What a pane types is the first name looked up.
            #expect(entry.executables.first == kind.launchCommand)
            #expect(entry.id == kind.rawValue)
        }
        #expect(AgentCatalog.entry(for: .claude).displayName == "Claude")
        #expect(AgentCatalog.entry(for: .codex).displayName == "Codex")
    }

    // MARK: - The rules, with the file system given

    private static func installed(
        paths: [String],
        executables: Set<String>,
        shims: Set<String> = [],
        folders: [String: [String]] = [:]
    ) -> [AgentKind] {
        AgentCatalog.installations(
            searchPaths: paths,
            home: "/Users/someone",
            isExecutable: { executables.contains($0) },
            isShimDirectory: { shims.contains($0) },
            contentsOfDirectory: { folders[$0] ?? [] }
        )
        .map(\.kind)
    }

    @Test func anAgentOnAnyPathSearched_isInstalled_inTheCatalogsOrder() {
        #expect(Self.installed(paths: ["/usr/bin:/opt/tools/bin"], executables: ["/opt/tools/bin/codex", "/usr/bin/claude"])
            == [.claude, .codex])
        // Every PATH in `searchPaths` is searched, not only the first.
        #expect(Self.installed(paths: ["/pane/bin", "/usr/bin"], executables: ["/pane/bin/codex"]) == [.codex])
        #expect(Self.installed(paths: ["/usr/bin"], executables: ["/opt/tools/bin/codex"]).isEmpty)
        #expect(Self.installed(paths: [], executables: []).isEmpty)
    }

    /// The executable an installation names: the first on the
    /// `searchPaths` in their order, else the first known location that
    /// has one.
    @Test func anInstallation_isTheFirstOnThePaths_elseTheFirstKnownLocation() {
        let nvm = "/Users/someone/.nvm/versions/node"
        let found = AgentCatalog.installations(
            searchPaths: ["/pane/bin:/usr/bin", "/login/bin"],
            home: "/Users/someone",
            isExecutable: {
                ["/usr/bin/codex", "/login/bin/codex", "/pane/bin/codex", "\(nvm)/v22.3.0/bin/claude", "\(nvm)/v18.20.0/bin/claude"]
                    .contains($0)
            },
            isShimDirectory: { _ in false },
            contentsOfDirectory: { $0 == nvm ? ["v18.20.0", "v22.3.0"] : [] }
        )
        #expect(found == [
            AgentInstallation(kind: .claude, executable: "\(nvm)/v22.3.0/bin/claude"),
            AgentInstallation(kind: .codex, executable: "/pane/bin/codex")
        ])
    }

    /// The project's panes' `PATH` is searched after the known locations:
    /// it can hold the project's own folders, which go after any CLI
    /// installed for everything (`detectInstallations`).
    @Test func theFallbackPaths_comeAfterTheKnownLocations() {
        let nvm = "/Users/someone/.nvm/versions/node"
        let paneBin = "/Users/someone/project-a/node_modules/.bin"
        let found = AgentCatalog.installations(
            searchPaths: ["/login/bin"],
            fallbackPaths: ["\(paneBin):/login/bin"],
            home: "/Users/someone",
            isExecutable: { ["\(paneBin)/codex", "\(paneBin)/claude", "\(nvm)/v22.3.0/bin/codex"].contains($0) },
            isShimDirectory: { _ in false },
            contentsOfDirectory: { $0 == nvm ? ["v22.3.0"] : [] }
        )
        #expect(found == [
            // Nowhere else: the last pane's PATH is still searched.
            AgentInstallation(kind: .claude, executable: "\(paneBin)/claude"),
            AgentInstallation(kind: .codex, executable: "\(nvm)/v22.3.0/bin/codex")
        ])
    }

    @Test func aWeirShimDirectory_onThePath_findsNoAgent() {
        // A pane's PATH, and the app's when opened from a pane, holds the
        // shim, which is there whether or not the agent is.
        let shim = "/Applications/Weir.app/Contents/Resources/claude-shim"
        #expect(Self.installed(paths: [shim], executables: ["\(shim)/claude"], shims: [shim]).isEmpty)
    }

    @Test func aRelativePathEntry_isSkipped() {
        #expect(Self.installed(paths: ["bin"], executables: ["bin/claude"]).isEmpty)
    }

    @Test func anAgentWhereItsShimOrAVersionManagerPutsIt_isInstalled_offThePath() {
        #expect(Self.installed(paths: ["/usr/bin"], executables: ["/Users/someone/.claude/local/claude"]) == [.claude])
        #expect(Self.installed(paths: ["/usr/bin"], executables: ["/Users/someone/.local/bin/codex"]) == [.codex])
        #expect(Self.installed(paths: ["/usr/bin"], executables: ["/Users/someone/.volta/bin/codex"]) == [.codex])
        #expect(Self.installed(paths: ["/usr/bin"], executables: ["/Users/someone/.local/share/mise/shims/claude"]) == [.claude])
        // nvm's folder per Node version.
        let nvm = "/Users/someone/.nvm/versions/node"
        #expect(Self.installed(
            paths: ["/usr/bin"],
            executables: ["\(nvm)/v22.3.0/bin/codex"],
            folders: [nvm: ["v20.1.0", "v22.3.0"]]
        ) == [.codex])
    }

    @Test func aStarInAKnownLocation_isEachEntryOfItsFolder_newestVersionFirst() {
        let paths = AgentCatalog.expanded("~/.nvm/versions/node/*/bin/codex", home: "/h") { folder in
            folder == "/h/.nvm/versions/node" ? ["v9.0.0", "v22.3.0", "v22.10.1", "v18.20.0"] : []
        }
        // By version, not by character: a plain sort puts v9 first.
        #expect(paths == ["v22.10.1", "v22.3.0", "v18.20.0", "v9.0.0"].map { "/h/.nvm/versions/node/\($0)/bin/codex" })
        #expect(AgentCatalog.expanded("/opt/homebrew/bin/codex", home: "/h") { _ in [] } == ["/opt/homebrew/bin/codex"])
        #expect(AgentCatalog.expanded("~/.nvm/versions/node/*/bin/codex", home: "/h") { _ in [] }.isEmpty)
    }

    // MARK: - Real files

    @Test func onDisk_anAgentOnTheRecordedPanePath_andOneUnderNvm_areInstalled() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let paneBin = root.appendingPathComponent("pane-bin")
            try AgentCatalogFixture.makeExecutable(paneBin.appendingPathComponent("codex"))
            try AgentCatalogFixture.makeExecutable(home.appendingPathComponent(".nvm/versions/node/v22.3.0/bin/claude"))
            let record = AgentCatalog.panePathRecordURL(in: root, project: UUID())
            try Data("\(paneBin.path):/usr/bin\n".utf8).write(to: record)
            let panePath = try #require(AgentCatalog.recordedPanePath(at: record))
            #expect(panePath == "\(paneBin.path):/usr/bin")
            #expect(AgentCatalogFixture.installedOnDisk(paths: [panePath], home: home) == [.claude, .codex])
            // Without the record, only the known location is left.
            #expect(AgentCatalogFixture.installedOnDisk(paths: ["/usr/bin"], home: home) == [.claude])
        }
    }

    @Test func onDisk_aShimFolder_aFolderNamedLikeTheAgent_andAPlainFile_findNoAgent() throws {
        try withTempDir { root in
            let shim = root.appendingPathComponent("claude-shim")
            try AgentCatalogFixture.makeExecutable(shim.appendingPathComponent("claude"))
            try Data().write(to: shim.appendingPathComponent(AgentCatalog.shimMarker))
            let folders = root.appendingPathComponent("folders")
            try FileManager.default.createDirectory(at: folders.appendingPathComponent("codex"), withIntermediateDirectories: true)
            let plain = root.appendingPathComponent("plain")
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: plain.appendingPathComponent("claude"))
            let path = [shim.path, folders.path, plain.path].joined(separator: ":")
            #expect(AgentCatalogFixture.installedOnDisk(paths: [path], home: root.appendingPathComponent("home")).isEmpty)
            #expect(!AgentCatalog.isExecutableFile(folders.appendingPathComponent("codex").path))
        }
    }

    @Test func onDisk_noRecordYet_readsAsNone() throws {
        try withTempDir { root in
            let record = AgentCatalog.panePathRecordURL(in: root, project: UUID())
            #expect(AgentCatalog.recordedPanePath(at: record) == nil)
            try Data("\n".utf8).write(to: record)
            #expect(AgentCatalog.recordedPanePath(at: record) == nil)
        }
    }

    // MARK: - The shims and the pane's shell

    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func theShimMarker_isInBothShimFolders() throws {
        for name in ["claude-shim", "codex-shim"] {
            let marker = try AgentCatalogFixture.shimFolder(name).appendingPathComponent(AgentCatalog.shimMarker)
            #expect(FileManager.default.fileExists(atPath: marker.path), "\(name)")
        }
    }

    @Test func theKnownLocations_reachAPane_oneALine_inOrder_withTheHomeFolderFilledIn() {
        let environment = AgentCatalog.knownLocationsEnvironment(home: "/Users/someone")
        #expect(Set(environment.keys) == ["WEIR_CLAUDE_KNOWN_LOCATIONS", "WEIR_CODEX_KNOWN_LOCATIONS"])
        for entry in AgentCatalog.entries {
            let lines = environment[entry.knownLocationsVariable]?.components(separatedBy: "\n")
            // The star stays: the shim's shell expands it at launch.
            #expect(lines == entry.knownLocations.map { $0.replacingOccurrences(of: "~/", with: "/Users/someone/") }, "\(entry.kind)")
        }
        #expect(environment["WEIR_CODEX_KNOWN_LOCATIONS"]?.contains("/Users/someone/.nvm/versions/node/*/bin/codex") == true)
        let pane = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin",
            agentKnownLocations: environment
        )
        for (name, value) in environment {
            #expect(pane[name] == value, "\(name)")
        }
    }

    /// The list lives in the catalog alone: a shim reads its entry's
    /// variable, and keeps no copy that could drift from it again.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func eachShim_readsItsEntrysKnownLocations_andKeepsNoListOfItsOwn() throws {
        for entry in AgentCatalog.entries {
            let script = try String(contentsOf: AgentCatalogFixture.shim(for: entry.kind), encoding: .utf8)
            #expect(script.contains("${\(entry.knownLocationsVariable):-}"), "\(entry.kind)")
            for location in entry.knownLocations {
                #expect(!script.contains(location.replacingOccurrences(of: "~/", with: "$HOME/")), "\(entry.kind): \(location)")
            }
        }
    }
}
