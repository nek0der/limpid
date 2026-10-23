// AgentCatalog.swift
// Limpid — the agents a workspace can start, in the order the new worktree sheet lists them, and which are installed.

import Foundation

/// One agent a workspace can start: what the sheet calls it and the
/// commands it runs as. Its badge is the one every row draws for its
/// `kind` (`SessionAgentBadge`).
struct AgentCatalogEntry: Equatable, Sendable {
    let kind: AgentKind
    /// The product's name, the same in every language.
    let displayName: String
    /// The names looked up on the `PATH`: the first is what a pane types
    /// (`AgentKind.launchCommand`).
    let executables: [String]
    /// Where else the agent may be when no `PATH` searched has it, in the
    /// order they are tried: the usual install folders, then where the
    /// version managers put what they install. A path may start with `~/`,
    /// and one of its components may be `*` (nvm's version folder). The
    /// agent's shim is handed this list (`AgentCatalog.knownLocationsEnvironment`)
    /// rather than keeping one of its own, so an agent the sheet offers is
    /// one a pane can start.
    let knownLocations: [String]

    var id: String {
        kind.rawValue
    }

    /// The variable a pane's shell carries `knownLocations` in: the name
    /// the agent's shim reads.
    var knownLocationsVariable: String {
        "LIMPID_\(kind.rawValue.uppercased())_KNOWN_LOCATIONS"
    }

    /// The variable in which a staged launch names the executable the new
    /// worktree sheet found (`AgentInstallation`). The shim takes it when the
    /// pane's own `PATH` has no agent, before the known locations: the
    /// pane's `PATH`, which a `.nvmrc`, a mise pin or direnv sets by
    /// folder, still chooses first. Not `LIMPID_REAL_*`, which overrides
    /// the search outright.
    var foundExecutableVariable: String {
        "LIMPID_FOUND_\(kind.rawValue.uppercased())"
    }
}

/// An agent detection found, and the executable it found
/// (`AgentCatalog.installations`).
struct AgentInstallation: Equatable, Hashable, Sendable {
    let kind: AgentKind
    /// Absolute, and as found rather than with its links resolved: an
    /// npm install's `bin/codex` is a link into `lib/`, and the folder it
    /// is found in is the one that holds its `node`.
    let executable: String
}

/// The agents a workspace can start: a list, so the sheet's
/// menu and the detection walk entries rather than switching on two cases.
/// A third agent is one more entry here, with its `AgentKind` case and its
/// shim.
enum AgentCatalog {
    /// In the order the new worktree sheet's menu lists them.
    static let entries: [AgentCatalogEntry] = [
        AgentCatalogEntry(
            kind: .claude,
            displayName: "Claude",
            executables: ["claude"],
            knownLocations: ["~/.claude/local/claude", "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                + managerLocations(of: "claude")
        ),
        AgentCatalogEntry(
            kind: .codex,
            displayName: "Codex",
            executables: ["codex"],
            knownLocations: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]
                + managerLocations(of: "codex")
        )
    ]

    /// Where the version managers that a `.zshrc` turns on put a global
    /// install: for a person who has not opened a pane in this build yet,
    /// whose `PATH` the pane record would otherwise carry, and for an
    /// install no `PATH` has, such as one under an nvm version the
    /// `.zshrc` does not turn on.
    static func managerLocations(of name: String) -> [String] {
        [
            "~/.nvm/versions/node/*/bin/\(name)",
            "~/.local/share/mise/shims/\(name)",
            "~/.asdf/shims/\(name)",
            "~/.volta/bin/\(name)",
            "~/.bun/bin/\(name)",
            "~/Library/pnpm/\(name)"
        ]
    }

    /// The entry for `kind`. Every case has one (`AgentCatalogTests`); the
    /// fallback names the agent by its identifier rather than by nothing.
    static func entry(for kind: AgentKind) -> AgentCatalogEntry {
        entries.first { $0.kind == kind }
            ?? AgentCatalogEntry(kind: kind, displayName: kind.rawValue, executables: [kind.launchCommand], knownLocations: [])
    }

    /// The file a Limpid shim directory holds beside the agent's name. A
    /// `PATH` that has one (a pane's, or Limpid opened from its own pane)
    /// would find the shim, which is there whether or not the agent is.
    static let shimMarker = "limpid-hook"

    /// The variable a pane's shell is given the pane `PATH` record's path
    /// in (`claude-shim/zdotdir/.zshrc` writes it).
    static let panePathRecordVariable = "LIMPID_PANE_PATH_RECORD"

    /// Returns where the `PATH` the last shell of a pane of `projectID`
    /// ended up with is kept, under `directory` (Limpid's Application Support
    /// folder; a test gives a temporary one). That `PATH` is the one an
    /// agent started in a pane is found on: the shell has read the
    /// person's `.zshrc`, where nvm, mise, asdf and the like add theirs,
    /// which a login shell (`-lc`) never reads.
    ///
    /// We keep one record per project, never one for every pane: a `.zshrc` can put
    /// the pane's own folders on its `PATH` (`$PWD/bin`, direnv's
    /// `node_modules/.bin`), and what one project's folder holds must
    /// never be what the sheet starts as the agent in another. A scratch
    /// pane, in no project, records none.
    static func panePathRecordURL(in directory: URL, project projectID: UUID) -> URL {
        directory.appendingPathComponent("pane-path-\(projectID.uuidString).txt", isDirectory: false)
    }

    /// The `PATH` in the record at `url`, `nil` when there is none yet.
    static func recordedPanePath(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The agents installed, in the catalog's order, each with the
    /// executable found: the first on `searchPaths` (each a `PATH`, in
    /// order) outside a Limpid shim directory, else at the first of the
    /// entry's known locations that has one, as its shim tries them, else
    /// the first on `fallbackPaths`. The file system comes in as closures,
    /// so a test can give its own.
    static func installations(
        searchPaths: [String],
        fallbackPaths: [String] = [],
        home: String,
        entries: [AgentCatalogEntry] = entries,
        isExecutable: (String) -> Bool,
        isShimDirectory: (String) -> Bool,
        contentsOfDirectory: (String) -> [String]
    ) -> [AgentInstallation] {
        var seen: Set<String> = []
        var groups: [[String]] = []
        for paths in [searchPaths, fallbackPaths] {
            var directories: [String] = []
            for path in paths {
                for directory in path.split(separator: ":").map(String.init)
                    where directory.hasPrefix("/") && !seen.contains(directory) && !isShimDirectory(directory)
                {
                    seen.insert(directory)
                    directories.append(directory)
                }
            }
            groups.append(directories)
        }
        var found: [AgentInstallation] = []
        for entry in entries {
            // The candidates in the order they are tried: the first PATHs,
            // then the known locations, then the fallback PATHs.
            var candidates = groups[0].flatMap { directory in
                entry.executables.map { (directory as NSString).appendingPathComponent($0) }
            }
            for location in entry.knownLocations {
                candidates += expanded(location, home: home, contentsOfDirectory: contentsOfDirectory)
            }
            candidates += groups[1].flatMap { directory in
                entry.executables.map { (directory as NSString).appendingPathComponent($0) }
            }
            if let executable = candidates.first(where: isExecutable) {
                found.append(AgentInstallation(kind: entry.kind, executable: executable))
            }
        }
        return found
    }

    /// Returns the agents installed now, looked up on the login shell's
    /// `PATH` (read once a launch, by `LoginShellPath`), at the known
    /// locations, and on the `PATH` the last shell of a pane of the sheet's
    /// project had (`panePathRecord`, `panePathRecordURL(in:project:)`). We
    /// run it each time the sheet opens: an agent installed since shows once a pane has
    /// opened after the install, or at once when it went into a folder
    /// already on one of those `PATH`s or a known location.
    ///
    /// The sheet's launch hands the executable found here to the new pane's
    /// shim, which starts it when that pane's own `PATH` has no agent
    /// (`AgentCatalogEntry.foundExecutableVariable`). The pane's `PATH`
    /// comes last for that reason: it can hold the project's own folders
    /// (direnv's `node_modules/.bin`, a mise install for the project),
    /// which go after any CLI installed for everything. Of the panes'
    /// `PATH`s, only the sheet's project's is read, so no other project's
    /// pane folders are searched.
    static func detectInstallations(panePathRecord: URL?) async -> [AgentInstallation] {
        let paneLaunchPath = panePathRecord.flatMap(recordedPanePath(at:))
        // `nil` when the wait was canceled or no `PATH` could be read; the
        // app's own `PATH` is then the best there is.
        let loginPath = await (try? LoginShellPath.shared.path()) ?? ProcessInfo.processInfo.environment["PATH"]
        return installations(
            searchPaths: [loginPath].compactMap(\.self),
            fallbackPaths: [paneLaunchPath].compactMap(\.self),
            home: NSHomeDirectory(),
            isExecutable: isExecutableFile,
            isShimDirectory: isShimDirectory,
            contentsOfDirectory: contentsOfDirectory
        )
    }

    /// An executable regular file, as `command -v` takes it: a folder named
    /// `claude` is not the agent, whatever its permissions.
    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func isShimDirectory(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(shimMarker))
    }

    static func contentsOfDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Each entry's known locations as its shim reads them from a pane's
    /// environment: one a line, in order, with `~/` made `home` as
    /// detection makes it. A `*` is left for the shim's shell to expand at
    /// launch, so an nvm version installed after the pane opened is found
    /// too.
    static func knownLocationsEnvironment(home: String, entries: [AgentCatalogEntry] = entries) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in entries {
            environment[entry.knownLocationsVariable] = entry.knownLocations
                .map { homeExpanded($0, home: home) }
                .joined(separator: "\n")
        }
        return environment
    }

    /// `location` with a leading `~/` made the home folder.
    static func homeExpanded(_ location: String, home: String) -> String {
        location.hasPrefix("~/")
            ? (home as NSString).appendingPathComponent(String(location.dropFirst(2)))
            : location
    }

    /// `location` as the paths it names: `~/` made the home folder, and a
    /// `*` component each entry of the folder before it, newest version
    /// first (v22.3.0 before v18.20.0), the order the shim tries them in
    /// (`limpid_expand_location`).
    static func expanded(_ location: String, home: String, contentsOfDirectory: (String) -> [String]) -> [String] {
        let path = homeExpanded(location, home: home)
        guard let star = path.range(of: "/*/") else { return [path] }
        let parent = String(path[..<star.lowerBound])
        let rest = String(path[star.upperBound...])
        return contentsOfDirectory(parent)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(parent)/\($0)/\(rest)" }
    }
}
