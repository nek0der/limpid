// SetupCommandsDraftTests.swift
// Limpid — a setup step's timeout and cwd from state.json survive Project Settings' text editor.

import Foundation
import Testing
@testable import Limpid

struct SetupCommandsDraftTests {
    private let steps: [BootstrapItem] = [
        .shorthand("npm ci"),
        .detailed(BootstrapDetail(cmd: "make db", timeout: 900, cwd: "services/db")),
        .shorthand("cp .env.example .env")
    ]

    @Test func theTextAndBack_isTheSameSteps() throws {
        let text = SetupCommandsDraft.text(for: steps)

        #expect(text == "npm ci\nmake db\ncp .env.example .env")
        #expect(SetupCommandsDraft.items(from: text, previous: steps) == steps)
        // And through a save, as state.json holds them.
        let saved = try JSONDecoder().decode(
            [BootstrapItem].self,
            from: JSONEncoder().encode(SetupCommandsDraft.items(from: text, previous: steps))
        )
        #expect(saved[1].timeout == 900)
        #expect(saved[1].cwd == "services/db")
    }

    @Test func aDetailedLineEditedInPlace_keepsItsTimeoutAndCwd() {
        let edited = SetupCommandsDraft.items(from: "npm ci\nmake db-seed\ncp .env.example .env", previous: steps)

        #expect(edited[1] == .detailed(BootstrapDetail(cmd: "make db-seed", timeout: 900, cwd: "services/db")))
    }

    @Test func aDetailedLineMoved_keepsItsSettings_andNewLinesArePlain() {
        let moved = SetupCommandsDraft.items(from: "make db\nnpm ci\nnpm run build", previous: steps)

        #expect(moved == [
            .detailed(BootstrapDetail(cmd: "make db", timeout: 900, cwd: "services/db")),
            .shorthand("npm ci"),
            .shorthand("npm run build")
        ])
    }

    @Test func settingsLostWithTheLineCountUnchanged_areCounted() {
        // The detailed line removed and another added: as many lines as
        // before, and the edit does not keep its settings on another line.
        let after = SetupCommandsDraft.items(from: "npm ci\ncp .env.example .env\nnpm run build", previous: steps)

        #expect(after.count == steps.count)
        #expect(SetupCommandsDraft.droppedDetailCount(before: steps, after: after) == 1)
        #expect(SetupCommandsDraft.droppedDetailCount(before: steps, after: steps) == 0)
    }

    @Test func theNoteUnderTheEditor_namesEachLinesSettings() {
        let details = SetupCommandsDraft.details(of: steps)

        #expect(details == [.init(line: 2, timeoutSeconds: 900, cwd: "services/db")])
        let english = SetupCommandsDraft.description(of: details[0]).resolved(in: Locale(identifier: "en"))
        #expect(english == "Line 2: times out after 900 s, runs in services/db")
    }
}
