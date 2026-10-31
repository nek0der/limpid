// AgentProjectionAdapterTests.swift
// Weir — what the adapter has to tell the rules, and what it must not.
//
// The rules read only what this process hands them. A field the adapter does
// not fill is not an error on the other side, it is a fact the rules never
// learn, so the cases here are the ones where staying silent would look like
// a decision.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("AgentProjectionAdapter")
struct AgentProjectionAdapterTests {
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"

    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WorkspaceSession
        let state: URL
        let intents: AgentResumeIntentStore
        let recordURL: URL
    }

    /// One pane holding one run whose process is gone, which is the shape the
    /// sweep retires unless something says otherwise.
    private func harness(in root: URL, paneID: UUID, writesFiles: Bool = true) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record = AgentStateRecordFixture(
            runId: Self.run,
            revision: 4,
            stateEpisodeToken: "4",
            paneId: paneID.uuidString,
            state: "finished",
            updatedAt: "2026-09-14T12:00:00Z",
            pid: "4242"
        )
        let recordURL = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run))
        try AgentRecordFixtures.write(record, to: state)

        let intents = AgentResumeIntentStore(
            directory: root.appendingPathComponent("resume-intents", isDirectory: true)
        )
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let adapter = ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            resumeIntents: intents,
            writesFiles: writesFiles,
            processStatus: { _ in .dead }
        )
        return Harness(
            adapter: adapter,
            session: session,
            state: state,
            intents: intents,
            recordURL: recordURL
        )
    }

    @Test("a run an intent has claimed survives the sweep")
    func resumeIntent_keepsTheRecordTheRestoreNeeds() throws {
        try withTempDir { root in
            let paneID = UUID()
            let harness = try harness(in: root, paneID: paneID)
            try harness.intents.save(AgentResumeIntent(
                runID: Self.run,
                paneID: paneID,
                sessionID: "session-1",
                ownerRunID: nil,
                pid: "4242",
                createdAt: Date()
            ))

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            // The intent is the only evidence that Weir killed this run at
            // quit rather than losing it. Retiring the record now would take
            // away what the restore rebuilds from.
            #expect(harness.adapter.lastFailure == nil)
            #expect(FileManager.default.fileExists(atPath: harness.recordURL.path))
        }
    }

    @Test("the same run with no intent is retired")
    func withoutAnIntent_theDeadRunIsRetired() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            // The contrast is the point: without this the case above would
            // pass even if the sweep never ran.
            #expect(harness.adapter.lastFailure == nil)
            #expect(!FileManager.default.fileExists(atPath: harness.recordURL.path))
        }
    }

    @Test("a run that may not write leaves every record where it is")
    func anAdapterThatMayNotWrite_retiresNothing() throws {
        // Demo mode: a pass keeps only the records of the panes it sees, and
        // a demo window shows none of the person's.
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID(), writesFiles: false)

            harness.adapter.prepareForLaunch()
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())
            harness.adapter.refresh()
            harness.adapter.prepareForTermination()

            #expect(FileManager.default.fileExists(atPath: harness.recordURL.path))
        }
    }

    @Test("a run that may not write creates no directory to watch")
    func anAdapterThatMayNotWrite_watchesNothing() throws {
        // Watching creates the directories, and these would be the person's.
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let adapter = AgentProjectionAdapter(
                directories: ["claude": AgentDirectories(state: state, sessions: sessions, cwdEvents: nil)],
                descriptors: AgentProviderRegistry.descriptors.filter { $0.key == "claude" },
                resumeIntents: AgentResumeIntentStore(
                    directory: root.appendingPathComponent("resume-intents", isDirectory: true),
                    writesFiles: false
                ),
                writesFiles: false
            )

            adapter.startWatching()
            defer { adapter.stopWatching() }

            #expect(!FileManager.default.fileExists(atPath: state.path))
            #expect(!FileManager.default.fileExists(atPath: sessions.path))
        }
    }

    @Test("the first pass after launch lists the stop of a dead run nothing claimed, then retires it, hint and all")
    func launch_leavesADeadRunNothingClaimedToTheFirstPass() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "running",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242"
            )
            try AgentRecordFixtures.write(record, to: state)
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z",
                runId: Self.run
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)

            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .dead }
            )
            let attention = AttentionState()
            adapter.prepareForLaunch()
            let recordURL = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run))
            // No kill marker and no intent means Weir did not stop this run,
            // so nothing says it should come back. It died at work, though,
            // and no pass has shown that yet: the launch leaves it for the
            // first pass, which lists the stop a live death would have
            // rather than retiring it before anyone saw it.
            #expect(adapter.lastFailure == nil)
            #expect(FileManager.default.fileExists(atPath: recordURL.path))
            #expect(FileManager.default.fileExists(atPath: hintURL.path))

            adapter.bootstrap(into: session, attention: attention)

            // The first pass shows the run stopped once, with its session
            // still at hand for the stop ledger, and retires the record and
            // the hint it owned, for every provider alike. The restored pane
            // gets no resume candidate from that hint: it types a resume
            // from the candidates, and this run is the stop's to resume, not
            // the relaunch's. The pid is what decides, not the pane.
            #expect(adapter.lastFailure == nil)
            #expect(attention.allRuntimes.map(\.badge.stopReason) == [AgentBadge.processExitedReason])
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
            let tab = session.activeTab(in: session.primaryWindowID)
            #expect(tab?.agentSessions[.claude]?[pane]?.sessionId == "S")
            #expect(tab?.agentResumeCandidates[pane] == nil)
        }
    }

    /// "Start New Conversation" ends the stopped session for good, by its
    /// hint. A hook holding the hint's lock at that moment leaves it on
    /// disk: the ended session is kept from the rules until the hint can
    /// go, so it is neither shown as the pane's again nor resumed by the
    /// next launch, and the deletion is tried again until it lands.
    @Test("a hint ended while a hook held it is kept from the rules, and deleted once free")
    func aForgottenHint_whileItsLockIsHeld_isKeptFromTheRules_thenDeleted() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z"
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)
            let adapter = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, processStatus: { _ in .dead }
            )
            adapter.bootstrap(into: session, attention: AttentionState())
            @MainActor func paneSession() -> String? {
                session.activeTab(in: session.primaryWindowID)?.agentSessions[.claude]?[pane]?.sessionId
            }
            #expect(paneSession() == "S")

            do {
                let held = try AgentRecordFixtures.HeldLock(on: hintURL)
                withExtendedLifetime(held) {
                    adapter.forgetSession("S", of: .claude, inPane: pane)
                    #expect(FileManager.default.fileExists(atPath: hintURL.path))
                    #expect(adapter.forgottenHints == [.init(provider: "claude", pane: pane, sessionID: "S")])
                    adapter.refresh()
                    #expect(adapter.lastFailure == nil)
                    #expect(paneSession() == nil)
                    #expect(session.activeTab(in: session.primaryWindowID)?.agentResumeCandidates[pane] == nil)
                }
            }

            // The hook let go: the next pass deletes the hint.
            adapter.refresh()
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(adapter.forgottenHints.isEmpty)
            #expect(paneSession() == nil)
        }
    }

    /// A hint the person ended a session by that is still on disk at quit
    /// (a hook held its lock past the quit's waits, or the file could not
    /// be removed) is kept in the adapter's file: the next launch keeps it
    /// from the rules and deletes it once it can, and the file goes with
    /// the last one. A removal that failed is tried again, not settled.
    @Test("an ended session's hint left at quit is kept from the next launch's rules, and deleted then")
    func aForgottenHint_leftAtQuit_isKeptAcrossARelaunch() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z"
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)
            let fileURL = root.appendingPathComponent(AgentForgottenHintFile.fileName)
            let forgotten = [AgentForgottenHint(provider: "claude", pane: pane, sessionID: "S")]

            // The removal fails: the folder will not let the file go.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessions.path)
            let quitting = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, forgottenHintsURL: fileURL, processStatus: { _ in .dead }
            )
            quitting.forgetSession("S", of: .claude, inPane: pane)
            quitting.prepareForTermination()
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessions.path)
            #expect(quitting.forgottenHints == forgotten, "a failed removal is tried again, not settled")
            #expect(FileManager.default.fileExists(atPath: hintURL.path))
            #expect(AgentForgottenHintFile.read(fileURL) == forgotten)

            // The next launch, with a hook holding the lock.
            let relaunched = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, forgottenHintsURL: fileURL, processStatus: { _ in .dead }
            )
            do {
                let held = try AgentRecordFixtures.HeldLock(on: hintURL)
                withExtendedLifetime(held) {
                    #expect(relaunched.forgottenHints == forgotten)
                    relaunched.bootstrap(into: session, attention: AttentionState())
                    #expect(relaunched.lastFailure == nil)
                    #expect(session.activeTab(in: session.primaryWindowID)?.agentSessions[.claude]?[pane] == nil)
                }
            }

            relaunched.refresh()
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(relaunched.forgottenHints.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path), "nothing waits: the file is gone")
        }
    }

    /// The ended session's hint stays (a hook holds its lock), and the
    /// folder its file lives in will not take the write. The list does not
    /// change again, but the write is tried again: by the next pass, and at
    /// quit, so the next launch still keeps the session from the rules.
    @Test("an ended session's hint whose save failed is saved by the next pass, and at quit")
    func aForgottenHint_whoseSaveFailed_isSavedOnceTheFolderTakesIt() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let kept = root.appendingPathComponent("kept", isDirectory: true)
            for directory in [state, sessions, kept] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z"
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)
            let forgotten = [AgentForgottenHint(provider: "claude", pane: pane, sessionID: "S")]
            let held = try AgentRecordFixtures.HeldLock(on: hintURL)
            defer { withExtendedLifetime(held) {} }
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path)
            }

            // By the next pass.
            let fileURL = kept.appendingPathComponent(AgentForgottenHintFile.fileName)
            let adapter = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, forgottenHintsURL: fileURL, processStatus: { _ in .dead }
            )
            adapter.bootstrap(into: session, attention: AttentionState())
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: kept.path)
            adapter.forgetSession("S", of: .claude, inPane: pane)
            #expect(adapter.forgottenHints == forgotten)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path), "the folder would not take it")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path)
            adapter.refresh()
            #expect(adapter.forgottenHints == forgotten, "the hook still holds the hint")
            #expect(AgentForgottenHintFile.read(fileURL) == forgotten)

            // At quit, with no pass between.
            let quitURL = root.appendingPathComponent("quit", isDirectory: true)
            try FileManager.default.createDirectory(at: quitURL, withIntermediateDirectories: true)
            let quitFileURL = quitURL.appendingPathComponent(AgentForgottenHintFile.fileName)
            let quitting = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, forgottenHintsURL: quitFileURL, processStatus: { _ in .dead }
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: quitURL.path)
            quitting.forgetSession("S", of: .claude, inPane: pane)
            #expect(!FileManager.default.fileExists(atPath: quitFileURL.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quitURL.path)
            quitting.prepareForTermination()
            #expect(AgentForgottenHintFile.read(quitFileURL) == forgotten)
        }
    }

    /// `~/.codex` linked to a dotfiles folder: the rules read the memory
    /// agent's directories against the target as well, which only we can
    /// resolve. A home that does not exist, or is no link, adds nothing.
    @Test("a provider's symlinked default home is resolved for the rules")
    func resolvedHomes_followTheDefaultHomesLink() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home", isDirectory: true)
            let target = root.appendingPathComponent("dotfiles/.codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: home.appendingPathComponent(".codex"), withDestinationURL: target
            )
            let physicalHome = try #require(realpath(home.path, nil))
            defer { free(physicalHome) }
            let physicalTarget = try #require(realpath(target.path, nil))
            defer { free(physicalTarget) }

            let resolved = AgentProjectionInput.resolvedHomes(of: ["codex", "claude"], under: home.path)
            #expect(resolved == ["codex": String(cString: physicalTarget)])
            // Under a home written as it is on disk, a real `.claude` is no link.
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
            )
            let physical = AgentProjectionInput.resolvedHomes(of: ["claude"], under: String(cString: physicalHome))
            #expect(physical.isEmpty)
        }
    }

    @Test("the projection's recorded pid reaches the runtime as a process id")
    func projectedPID_becomesTheRuntimeProcessID() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "finished",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242"
            )
            try AgentRecordFixtures.write(record, to: state)
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .alive }
            )
            let attention = AttentionState()

            adapter.bootstrap(into: session, attention: attention)

            // The cache panel types a command only when this pid is what the
            // pane has in front, so a pid lost on the way in would quietly
            // fall back to matching names.
            #expect(adapter.lastFailure == nil)
            let runtime = try #require(attention.runtimesByKind[.claude]?.first)
            #expect(runtime.processID == 4242)
        }
    }

    @Test("a pass names the tab by its conversation")
    func apply_remembersTheConversationName() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "running",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242",
                firstPrompt: "Append a line to notes.txt",
                sessionId: "S"
            )
            try AgentRecordFixtures.write(record, to: state)
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .alive }
            )

            adapter.bootstrap(into: session, attention: AttentionState())

            #expect(adapter.lastFailure == nil)
            #expect(session.tab(tab.id)?.conversationName?.name == "Append a line to notes.txt")
            #expect(session.tab(tab.id)?.conversationName?.conversationID == "S")
        }
    }

    @Test("a tab restored without a name is named by the badges it was saved with")
    func apply_namesARestoredTabFromItsSavedBadges() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            // The tab as a file from before conversation names holds it:
            // the badge of a run that has since ended, and no name.
            var saved = try #require(session.tab(tab.id))
            saved.agentBadges[.claude] = [pane: AgentBadge(
                state: .finished,
                updatedAt: Date(timeIntervalSince1970: 0),
                firstPrompt: "Run sleep 15 with a timer",
                conversationID: "S"
            )]
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            object.removeValue(forKey: "conversationName")
            let restored = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(restored.conversationName == nil)
            session.update(tab.id) { $0 = restored }
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .dead }
            )

            adapter.bootstrap(into: session, attention: AttentionState())

            // No record is left, so the pass clears the badge; the name
            // read from it stays. An empty map, not none: a pass writes the
            // map only when the badge it saw there differs.
            #expect(adapter.lastFailure == nil)
            let after = try #require(session.tab(tab.id))
            #expect(after.agentBadges[.claude] == [:])
            #expect(after.conversationName?.name == "Run sleep 15 with a timer")
        }
    }

    @Test("a lock file beside the worktree events is not read as an event")
    func worktreeEvents_ignoreWhatIsNotAnEvent() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())
            let events = try AgentRecordFixtures.worktreeEvents(in: harness.state)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            // The first pass only takes note of what is already there, so the
            // files have to arrive after it for this to reach the rule that
            // consumes them.
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            let event = try "1757000000-1-a-create" + AgentRecordFixtures.layout().worktreeEventSuffix
            let lock = try AgentRecordFixtures.lockURL(for: events.appendingPathComponent(event))
            let planted: Set = [lock.lastPathComponent, ".\(event).tmp.42"]
            for name in planted {
                try Data("{}".utf8).write(to: events.appendingPathComponent(name))
            }
            harness.adapter.refresh()

            // Consuming either of these would delete it and, for the lock
            // file, create another one under a longer name every pass. Compare
            // the names rather than the count: deleting both and leaving two
            // new lock files behind would keep the count the same.
            #expect(harness.adapter.lastFailure == nil)
            let left = try Set(FileManager.default.contentsOfDirectory(atPath: events.path))
            #expect(left == planted, "left: \(left.sorted())")
        }
    }

    @Test("the sweep follows the records: a provider with none does not set the pace")
    func sweepInterval_followsTheRecordsThePassRead() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())

            // The one record on disk is Claude's, so Claude's declared cadence
            // is the one the sweep takes.
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())
            #expect(harness.adapter.lastFailure == nil)
            #expect(harness.adapter.sweepInterval == 30)

            // That pass retired the record (its process is dead and nothing
            // claimed it). With nothing left to ask about, there is no sweep
            // to run until a hook writes again.
            #expect(!FileManager.default.fileExists(atPath: harness.recordURL.path))
            harness.adapter.refresh()
            #expect(harness.adapter.sweepInterval == nil)
        }
    }

    @Test("watching a fresh install creates the directories the hooks write into")
    func startWatching_createsTheDirectoriesThatDoNotExistYet() throws {
        try withTempDir { root in
            // Nothing has run an agent on this machine yet, so none of the
            // record directories are there to open a descriptor on.
            let state = root.appendingPathComponent("codex-agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("codex-sessions", isDirectory: true)
            // Kept out of the provider's state directory so the store's own
            // setup does not create it before the watcher gets there.
            let adapter = ProjectionFixture.adapter(
                state: state,
                sessions: sessions,
                resumeIntents: AgentResumeIntentStore(
                    directory: root.appendingPathComponent("resume-intents", isDirectory: true)
                )
            )
            #expect(!FileManager.default.fileExists(atPath: state.path))

            adapter.startWatching()
            defer { adapter.stopWatching() }

            for directory in try [
                state,
                sessions,
                AgentRecordFixtures.worktreeEvents(in: state)
            ] {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: directory.path,
                    isDirectory: &isDirectory
                )
                #expect(exists && isDirectory.boolValue, "missing: \(directory.path)")
            }
        }
    }

    // MARK: - Records a hook holds

    /// A run's record in the version 2 shape an older hook wrote.
    private func olderRunRecord(paneID: UUID, runID: String, pid: String) -> AgentStateRecordFixture {
        AgentStateRecordFixture(
            schemaVersion: 2,
            runId: runID,
            revision: 1,
            paneId: paneID.uuidString,
            state: "running",
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: nil,
            pid: pid,
            lastPrompt: nil
        )
    }

    /// A hook may be rewriting a dead run's resume hint when the sweep
    /// comes to retire the run. The sweep leaves both the hint and the
    /// record while the hook holds the hint's lock, so the next pass can
    /// still retire them together, and retires both once the lock is free.
    @Test("a dead run whose hint a hook holds keeps its record until the lock is free")
    func aDeadRunsHintHeldByAHook_isRetiredWithItsRecordOnceFree() throws {
        try withTempDir { directory in
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let paneID = UUID(), runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(olderRunRecord(paneID: paneID, runID: runID, pid: "2147483646"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ), to: hints)
            let hintURL = try hints.appendingPathComponent(AgentRecordFixtures.hintFileName(paneID.uuidString))
            let projection = ProjectionFixture.adapter(state: states, sessions: hints)
            do {
                let held = try AgentRecordFixtures.HeldLock(on: hintURL)
                withExtendedLifetime(held) {
                    projection.bootstrap(into: session)
                    #expect(AgentRecordFixtures.records(in: states).count == 1)
                    #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) != nil)
                }
            }
            projection.refresh()
            #expect(AgentRecordFixtures.records(in: states).isEmpty)
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) == nil)
        }
    }

    /// Quitting records the intent to resume a live run even while a hook
    /// holds its record's lock, leaving the record itself for the hook; the
    /// next launch resumes the run from that intent.
    @Test("a quit while a hook holds a live run's record still keeps its resume")
    func aQuitWhileAHookHoldsTheRecord_stillKeepsTheResume() throws {
        try withTempDir { directory in
            let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
            let runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(olderRunRecord(paneID: paneID, runID: runID, pid: "12345"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ), to: hints)
            var status = AgentProcessStatus.alive
            let intents = AgentResumeIntentStore(
                directory: states.appendingPathComponent("resume-intents", isDirectory: true)
            )
            let projection = ProjectionFixture.adapter(
                state: states, sessions: hints,
                resumeIntents: intents, processStatus: { _ in status }
            )
            projection.bootstrap(into: session)
            let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(runID))
            do {
                let held = try AgentRecordFixtures.HeldLock(on: recordURL)
                withExtendedLifetime(held) {
                    projection.prepareForTermination()
                    #expect(intents.record(runID: runID) != nil)
                    #expect(AgentRecordFixtures.records(in: states).first?.killedByWeirAt == nil)
                }
            }
            status = .dead
            projection.prepareForLaunch()
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: hints) != nil)
            #expect(AgentRecordFixtures.records(in: states).first?.resumeAttemptedAt != nil)
            #expect(intents.record(runID: runID) == nil)
        }
    }

    /// Retiring a dead run of a pane leaves the resume hint a newer run of
    /// it wrote.
    @Test func cleanupOldRun_preservesNewRunsResumeHint() throws {
        try withTempDir { directory in
            let states = directory.appendingPathComponent("states")
            let sessions = directory.appendingPathComponent("sessions")
            let paneID = UUID()
            var old = olderRunRecord(paneID: paneID, runID: UUID().uuidString, pid: "2147483646")
            old.state = "idle"
            var current = old
            current.runId = UUID().uuidString
            current.pid = String(getpid())
            try AgentRecordFixtures.write(old, to: states)
            try AgentRecordFixtures.write(current, to: states)
            let hint = AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: current.updatedAt,
                runId: current.runId
            )
            try AgentRecordFixtures.write(hint, to: sessions)
            let projection = ProjectionFixture.adapter(state: states, sessions: sessions)
            projection.prepareForLaunch()
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: sessions) == hint)
            #expect(AgentRecordFixtures.records(in: states).map(\.storageID) == [current.storageID])
        }
    }
}
