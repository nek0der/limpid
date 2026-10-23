// NewSessionSettingsTests.swift
// Limpid — what the new worktree sheet remembers of each project, what an earlier build kept, and how a file it cannot read is kept.

import Foundation
import Testing
@testable import Limpid

@Suite(.tags(.persistence))
struct NewSessionSettingsTests {
    private static let app = URL(fileURLWithPath: "/tmp/work/app")

    @Test func theSheet_remembersWhatOpened_theFetch_andEachProjectsBoxes() throws {
        var settings = NewSessionSettings()
        let other = URL(fileURLWithPath: "/tmp/work/other")
        settings.remember(
            NewWorktreeChoices(open: .agent(.codex), fetches: true, copiesIgnoredFiles: false, runsSetup: true),
            forProjectAt: Self.app
        )
        settings.remember(NewWorktreeChoices(open: .shell, fetches: false, copiesIgnoredFiles: true, runsSetup: false), forProjectAt: other)
        #expect(settings.memory(forProjectAt: Self.app) == NewWorktreeProjectMemory(
            open: "codex",
            copiesIgnoredFiles: false,
            runsSetup: true
        ))
        #expect(settings.memory(forProjectAt: other) == NewWorktreeProjectMemory(
            open: "shell",
            copiesIgnoredFiles: true,
            runsSetup: false
        ))
        // What opened last anywhere, and the fetch, are the last remembered.
        #expect(settings.lastOpen == "shell")
        #expect(!settings.fetchesBeforeCreate)
        // The same folder by another spelling is the same project.
        #expect(settings.memory(forProjectAt: URL(fileURLWithPath: "/tmp/work/./app")) != nil)
        #expect(settings.memory(forProjectAt: URL(fileURLWithPath: "/tmp/work/new")) == nil)

        var decoded = LimpidSettings.default
        decoded.newSession = settings
        let roundTripped = try JSONDecoder().decode(LimpidSettings.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped.newSession == settings)
    }

    /// The fetch is on until turned off, and a file that never turned it
    /// off does not gain the key.
    @Test func theFetch_isOnByDefault_andWrittenOnlyOnceOff() throws {
        let fresh = try LimpidSettingsJSON.object(.default)
        #expect((fresh["newSession"] as? [String: Any])?["fetchesBeforeCreate"] == nil)
        #expect(LimpidSettings.default.newSession.fetchesBeforeCreate)
        var off = LimpidSettings.default
        off.newSession.fetchesBeforeCreate = false
        let written = try LimpidSettingsJSON.object(off)
        #expect((written["newSession"] as? [String: Any])?["fetchesBeforeCreate"] as? Bool == false)
        #expect(try !LimpidSettingsJSON.decode(written).newSession.fetchesBeforeCreate)
    }

    /// What an earlier build kept (the agent and the location) is read to
    /// start from, and written back untouched, so going back a build finds
    /// it as it left it.
    @Test func anEarlierBuildsAgentAndLocation_areKept_asTheyWereWritten() throws {
        var object = try LimpidSettingsJSON.object(.default)
        object["newSession"] = ["lastAgent": "codex", "projects": ["/tmp/work/app": ["agent": "claude", "location": "projectFolder"]]]
        var settings = try LimpidSettingsJSON.decode(object)
        #expect(settings.newSession.rememberedOpen(forProjectAt: Self.app) == [nil, nil, "claude", "codex"])
        settings.newSession.remember(
            NewWorktreeChoices(open: .nothing, fetches: true, copiesIgnoredFiles: true, runsSetup: true),
            forProjectAt: Self.app
        )
        #expect(settings.newSession.rememberedOpen(forProjectAt: Self.app) == ["nothing", "nothing", "claude", "codex"])
        let written = try LimpidSettingsJSON.object(settings)
        let newSession = written["newSession"] as? [String: Any]
        #expect(newSession?["lastAgent"] as? String == "codex")
        let project = (newSession?["projects"] as? [String: Any])?["/tmp/work/app"] as? [String: Any]
        #expect(project?["agent"] as? String == "claude")
        #expect(project?["location"] as? String == "projectFolder")
        #expect(project?["open"] as? String == "nothing")
    }

    @Test func aProjectsChoicesThatDoNotRead_dropOnlyThemselves() throws {
        var object = try LimpidSettingsJSON.object(.default)
        object["newSession"] = [
            "lastOpen": "codex",
            "projects": [
                "/tmp/bad": "not an object",
                "/tmp/wrong": ["open": 3],
                "/tmp/good": ["open": "shell", "runsSetup": false]
            ]
        ]
        let settings = try LimpidSettingsJSON.decode(object)
        #expect(settings.newSession.lastOpen == "codex")
        #expect(settings.newSession.projects == ["/tmp/good": NewWorktreeProjectMemory(open: "shell", runsSetup: false)])
    }

    /// A choice a later build added reads back as it was written, and
    /// keys it added are kept; what this build opens with is
    /// `WorktreeOpenChoice.initial`'s call.
    @Test func aLaterBuildsChoice_andKeys_areKept() throws {
        var object = try LimpidSettingsJSON.object(.default)
        object["newSession"] = ["lastOpen": "gemini", "laterTop": true, "projects": ["/tmp/app": ["open": "gemini", "laterKey": 1]]]
        let later = try LimpidSettingsJSON.decode(object).newSession
        #expect(later.lastOpen == "gemini")
        #expect(later.projects["/tmp/app"]?.open == "gemini")
        let written = try LimpidSettingsJSON.object(LimpidSettingsJSON.decode(object))
        let newSession = written["newSession"] as? [String: Any]
        #expect(newSession?["laterTop"] as? Bool == true)
        let projects = newSession?["projects"] as? [String: Any]
        #expect((projects?["/tmp/app"] as? [String: Any])?["laterKey"] as? Int == 1)
        #expect(WorktreeOpenChoice.initial(
            remembered: later.rememberedOpen(forProjectAt: URL(fileURLWithPath: "/tmp/app")),
            installed: [.claude]
        )
            == .agent(.claude))
    }
}
