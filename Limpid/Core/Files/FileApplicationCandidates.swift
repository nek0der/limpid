// FileApplicationCandidates.swift
// Limpid — the apps Settings offers for opening files: the installed editors in one order.

import Foundation
import UniformTypeIdentifiers

/// One app the "Open Files With" menu offers.
struct FileApplicationCandidate: Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String
    /// Where the app is, for its icon; nil for a chosen app that is gone.
    let url: URL?

    var id: String {
        bundleIdentifier
    }

    var application: FileApplication {
        FileApplication(bundleIdentifier: bundleIdentifier, lastKnownDisplayName: name)
    }
}

/// The menu's order, kept apart from how the apps are found so it can be
/// tested: each app once, by name as Finder sorts names, without Limpid
/// itself, and with the chosen app always present, even when it is no
/// longer installed, so the menu shows what is saved.
enum FileApplicationCandidates {
    static func ordered(
        _ found: [FileApplicationCandidate],
        chosen: FileApplication?,
        excluding ownBundleIdentifier: String?
    ) -> [FileApplicationCandidate] {
        var seen = Set<String>()
        var apps = found.filter { app in
            app.bundleIdentifier != ownBundleIdentifier && seen.insert(app.bundleIdentifier).inserted
        }
        if let chosen, !seen.contains(chosen.bundleIdentifier) {
            apps.append(FileApplicationCandidate(
                bundleIdentifier: chosen.bundleIdentifier,
                name: chosen.lastKnownDisplayName,
                url: nil
            ))
        }
        return apps.sorted { left, right in
            switch left.name.localizedStandardCompare(right.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: left.bundleIdentifier < right.bundleIdentifier
            }
        }
    }

    /// The kinds of file an editor opens: what a terminal path or a review
    /// file is, as far as Launch Services tells.
    static let editedTypes: [UTType] = [.sourceCode, .plainText]
}
