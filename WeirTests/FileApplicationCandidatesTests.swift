// FileApplicationCandidatesTests.swift
// Weir — the "Open Files With" menu lists each installed editor once, by name, with the saved choice always in it.

import Foundation
import Testing
@testable import Weir

struct FileApplicationCandidatesTests {
    private func app(_ id: String, _ name: String) -> FileApplicationCandidate {
        FileApplicationCandidate(bundleIdentifier: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    @Test func eachAppOnce_byName_withoutWeir() {
        let found = [
            app("dev.zed.Zed", "Zed"),
            app("com.microsoft.VSCode", "Visual Studio Code"),
            app("com.apple.TextEdit", "TextEdit"),
            // The same app listed for both kinds of file.
            app("dev.zed.Zed", "Zed"),
            app("com.nekoder.weir.app", "Weir"),
            app("com.sublimetext.4", "sublime Text")
        ]

        let names = FileApplicationCandidates.ordered(found, chosen: nil, excluding: "com.nekoder.weir.app").map(\.name)

        #expect(names == ["sublime Text", "TextEdit", "Visual Studio Code", "Zed"])
    }

    @Test func theChosenApp_isListed_evenWhenItIsGone() throws {
        let chosen = FileApplication(bundleIdentifier: "com.example.Gone", lastKnownDisplayName: "Gone Editor")

        let list = FileApplicationCandidates.ordered([app("dev.zed.Zed", "Zed")], chosen: chosen, excluding: nil)

        let gone = try #require(list.first)
        #expect(gone.name == "Gone Editor")
        #expect(gone.url == nil)
        #expect(list.map(\.bundleIdentifier) == ["com.example.Gone", "dev.zed.Zed"])
    }

    @Test func theChosenApp_isNotListedTwice_whenInstalled() {
        let chosen = FileApplication(bundleIdentifier: "dev.zed.Zed", lastKnownDisplayName: "Zed (old name)")

        let list = FileApplicationCandidates.ordered([app("dev.zed.Zed", "Zed")], chosen: chosen, excluding: nil)

        #expect(list.map(\.name) == ["Zed"])
        // What is saved is the same shape as before: an identifier and a name.
        #expect(list[0].application == FileApplication(bundleIdentifier: "dev.zed.Zed", lastKnownDisplayName: "Zed"))
    }
}
