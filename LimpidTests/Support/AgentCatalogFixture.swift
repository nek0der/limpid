// AgentCatalogFixture.swift
// Limpid — real folders and stand-in agents for the catalog's search and the shims that follow it.

import Foundation
import Testing
@testable import Limpid

/// What the catalog suites share: the entries limited to the home folder,
/// stand-in executables on disk, and the shims in the source tree.
enum AgentCatalogFixture {
    /// The catalog's entries with the locations under the home folder only:
    /// what this machine has under /opt/homebrew is not the test's.
    static let homeEntries = AgentCatalog.entries.map { entry in
        AgentCatalogEntry(
            kind: entry.kind,
            displayName: entry.displayName,
            executables: entry.executables,
            knownLocations: entry.knownLocations.filter { $0.hasPrefix("~/") }
        )
    }

    static func makeExecutable(_ url: URL, script: String = "#!/bin/sh\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func installedOnDisk(paths: [String], home: URL) -> [AgentKind] {
        AgentCatalog.installations(
            searchPaths: paths,
            home: home.path,
            entries: homeEntries,
            isExecutable: AgentCatalog.isExecutableFile,
            isShimDirectory: AgentCatalog.isShimDirectory,
            contentsOfDirectory: AgentCatalog.contentsOfDirectory
        )
        .map(\.kind)
    }

    /// A folder of `Limpid/Resources` in the source tree.
    static func shimFolder(_ name: String) throws -> URL {
        try #require(RepoFixture.limpidRoot).appendingPathComponent("Limpid/Resources/\(name)")
    }

    /// `kind`'s shim in the source tree.
    static func shim(for kind: AgentKind) throws -> URL {
        try shimFolder("\(kind.rawValue)-shim").appendingPathComponent(kind.launchCommand)
    }
}
