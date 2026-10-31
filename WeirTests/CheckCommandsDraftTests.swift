// CheckCommandsDraftTests.swift
// Weir — the test command list as Project Settings edits it, and the defaults behind it.

import Foundation
import Testing
@testable import Weir

@Suite("Test commands")
struct CheckCommandsDraftTests {
    private let defaults = ["make test*", "cargo test"]

    private func draft(_ commands: [String]?) -> CheckCommandsDraft {
        CheckCommandsDraft(commands: commands, defaults: defaults)
    }

    @Test func aProjectOnTheDefaults_showsThemAndKeepsFollowingThem() {
        let list = draft(nil)

        #expect(list.rows.map(\.text) == ["make test*", "cargo test"])
        // Saved as nil, so a later build's defaults reach it.
        #expect(list.commands() == nil)
        #expect(!list.differsFromDefaults())
    }

    @Test func adding_appendsAnEmptyRowThatCountsOnceTyped() {
        var list = draft(nil)
        let row = list.add()

        #expect(list.rows.last == CheckCommandsDraft.Row(id: row, text: ""))
        list.setText("  just   check  ", of: row)
        #expect(list.commands() == ["make test*", "cargo test", "just check"])
    }

    @Test func removing_dropsTheRow() {
        var list = draft(nil)
        list.remove(list.rows[0].id)

        #expect(list.commands() == ["cargo test"])
        #expect(list.differsFromDefaults())
    }

    @Test func anEmptyRow_isMarkedAndNotSaved_exceptWhileTypedIn() {
        var list = draft(["cargo test"])
        let row = list.add()

        #expect(list.problem(of: row) == .empty)
        #expect(list.problem(of: row, editing: row) == nil)
        #expect(list.commands() == ["cargo test"])
    }

    @Test func aSecondCopy_isMarkedAndNotSaved_theFirstStays() {
        var list = draft(["cargo test"])
        let copy = list.add()
        list.setText("cargo  test", of: copy)

        #expect(list.problem(of: list.rows[0].id) == nil)
        #expect(list.problem(of: copy) == .duplicate)
        #expect(list.commands() == ["cargo test"])
    }

    @Test func aStarBeforeTheEnd_isMarkedAndNotSaved() {
        var list = draft([])
        let inner = list.add()
        list.setText("make *test", of: inner)
        let trailing = list.add()
        list.setText("make test*", of: trailing)

        #expect(list.problem(of: inner) == .misplacedWildcard)
        #expect(list.problem(of: trailing) == nil)
        #expect(list.commands() == ["make test*"])
    }

    @Test func restoringDefaults_bringsBackTheDefaultsAndSavesNil() {
        var list = draft(["just check"])
        list.add()
        list.restoreDefaults()

        #expect(list.rows.map(\.text) == defaults)
        #expect(list.commands() == nil)
        #expect(!list.differsFromDefaults())
    }

    @Test func onlyAnEditThatChangesWhatIsSaved_saves() {
        // Stored in another order than the defaults: loading it saves
        // nothing, though saving it would write nil.
        let loaded = draft(["cargo test", "make test*"])
        var edited = loaded
        edited.add()
        #expect(CheckCommandsDraft.save(from: loaded, to: edited) == .nothing, "an empty row saves nothing")

        let typed = edited
        edited.setText("just check", of: edited.rows[2].id)
        #expect(CheckCommandsDraft.save(from: typed, to: edited) == .commands(["cargo test", "make test*", "just check"]))
    }

    @Test func theDefaultsInAnotherOrder_areStillTheDefaults() {
        #expect(draft(["cargo test", "make test*"]).commands() == nil)
    }

    @Test func nilAndAnEmptyList_areToldApart() {
        // Nil follows the defaults; an empty list shows no tests.
        #expect(draft(nil).rows.count == 2)
        #expect(draft([]).rows.isEmpty)
        var list = draft(nil)
        for row in list.rows {
            list.remove(row.id)
        }
        #expect(list.commands() == [])
        #expect(list.differsFromDefaults())
    }

    @Test func eachRow_isNormalized() {
        var list = draft([])
        let row = list.add()
        list.setText("swift test --filter \u{201C}Turn\u{201D}", of: row)

        let typed = list.commands(normalizing: CommandLineText.sanitizeSmartPunctuation)
        #expect(typed == ["swift test --filter \"Turn\""])
    }

    @Test func theDefaults_comeFromTheHook() throws {
        // The same list the hook classifies with, not a copy kept here.
        let hooks = try JSONDecoder().decode([String].self, from: WeirProjectionBridge.checkDefaults())
        #expect(AgentProviderRegistry.checkDefaults == hooks)
        #expect(AgentProviderRegistry.checkDefaults.contains("cargo test"))
        #expect(AgentProviderRegistry.checkDefaults.contains("make test*"))
    }
}

/// A project's test commands and a turn's last check, as the files keep them.
@Suite("Test commands on disk")
struct CheckCommandsPersistenceTests {
    @Test func aStateWrittenBeforeChecks_readsAsTheDefaults() throws {
        let json = #"""
        {"id":"\#(UUID().uuidString)","name":"r","rootURL":"file:///tmp/r","worktrees":[],"isExpanded":true}
        """#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.checkCommands == nil)
    }

    @Test func anEmptyList_staysEmptyThroughASave() throws {
        // Distinct from nil: no checks, not the defaults.
        var project = Project(name: "r", rootURL: URL(fileURLWithPath: "/tmp/r"))
        project.checkCommands = []
        let data = try PersistenceCoders.makeEncoder().encode(project)

        #expect(try JSONDecoder().decode(Project.self, from: data).checkCommands == [])
    }

    @Test func aTurnsLastCheck_isRead() throws {
        let json = #"""
        {"turnId":"T","conversation":{"provider":"claude","conversationId":"s","isFallback":false},
         "runId":"R","paneId":"P","displayNumber":7,"startedAt":"2026-10-12T00:00:00Z",
         "phase":"finished","changes":{"kind":"unchanged"},"hasPrompt":true,
         "lastCheck":{"command":"make test-swift FILTER=Turn","exitCode":0,"isFiltered":true}}
        """#
        let turn = try JSONDecoder().decode(TurnSummary.self, from: Data(json.utf8))

        #expect(turn.lastCheck == CheckSummary(command: "make test-swift FILTER=Turn", isFiltered: true, exitCode: 0))
    }
}
