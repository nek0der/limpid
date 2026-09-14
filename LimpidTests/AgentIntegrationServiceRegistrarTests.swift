// AgentIntegrationServiceRegistrarTests.swift
// Limpid — registration decisions and crash-recovery marker coverage.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent integration service registration")
struct AgentIntegrationServiceRegistrarTests {
    private let current = AgentIntegrationServiceArtifact(
        serviceExecutableSHA256: "service-current",
        launchAgentPropertyListSHA256: "plist-current"
    )
    private let previous = AgentIntegrationServiceArtifact(
        serviceExecutableSHA256: "service-previous",
        launchAgentPropertyListSHA256: "plist-previous"
    )

    @Test("maps every service status to a fail-closed action")
    func decision_allStatuses() {
        #expect(action(.notRegistered, running: nil) == .register)
        #expect(action(.enabled, running: current) == .keep)
        #expect(action(.enabled, running: previous) == .replace)
        #expect(action(.enabled, running: nil) == .replace)
        #expect(action(.enabled, running: current, registered: previous) == .replace)
        let beforeRegistration = AgentIntegrationRegistrationMarker(
            phase: .replacing,
            artifact: current,
            appVersion: "2"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .response(current),
            marker: beforeRegistration
        ) == .replace)
        let afterRegistration = AgentIntegrationRegistrationMarker(
            phase: .registered,
            artifact: current,
            appVersion: "2"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .response(current),
            marker: afterRegistration
        ) == .keep)
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: afterRegistration
        ) == .retry)
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: beforeRegistration
        ) == .replace)
        let previousMarker = AgentIntegrationRegistrationMarker(
            phase: .ready,
            artifact: previous,
            appVersion: "1"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .enabled,
            bundledArtifact: current,
            runningArtifact: .unavailable,
            marker: previousMarker
        ) == .replace)
        #expect(action(.requiresApproval, running: nil) == .awaitApproval)
        #expect(action(.notFound, running: nil) == .register)
        #expect(action(.unknown, running: nil) == .failUnknown)
    }

    @Test("registers when Background Task Management has no record yet")
    func decision_notFoundBeforeFirstRegistrationRegisters() {
        // macOS reports `.notFound` for an agent that has never been registered
        // on this machine, not `.notRegistered`. A stale marker from an earlier
        // install must not turn that first registration into a failure either.
        let staleMarker = AgentIntegrationRegistrationMarker(
            phase: .ready,
            artifact: previous,
            appVersion: "1"
        )
        #expect(AgentIntegrationRegistrationDecision.action(
            status: .notFound,
            bundledArtifact: current,
            runningArtifact: .notApplicable,
            marker: staleMarker
        ) == .register)
    }

    @Test("fingerprints both executable and launch agent property list")
    func artifact_changeInEitherInputChangesIdentity() throws {
        try withTempDir { dir in
            let contents = dir.appendingPathComponent("Contents", isDirectory: true)
            let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
            let launchAgents = contents
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            let executable = executables.appendingPathComponent("AgentIntegrationService")
            let propertyList = launchAgents.appendingPathComponent(AgentIntegrationConfiguration.plistName)
            try Data("service-a".utf8).write(to: executable)
            try Data("plist-a".utf8).write(to: propertyList)
            let first = try AgentIntegrationServiceArtifact.bundled(in: dir)

            try Data("service-b".utf8).write(to: executable)
            let executableChanged = try AgentIntegrationServiceArtifact.bundled(in: dir)
            #expect(executableChanged != first)

            try Data("service-a".utf8).write(to: executable)
            try Data("plist-b".utf8).write(to: propertyList)
            let propertyListChanged = try AgentIntegrationServiceArtifact.bundled(in: dir)
            #expect(propertyListChanged != first)
        }
    }

    @Test("persists each registration phase atomically")
    func marker_roundTripsAndRejectsCorruption() throws {
        try withTempDir { dir in
            let store = AgentIntegrationRegistrationMarkerStore(
                fileURL: dir.appendingPathComponent("nested/service-registration.json")
            )
            let replacing = AgentIntegrationRegistrationMarker(
                phase: .replacing,
                artifact: current,
                appVersion: "2"
            )
            try store.write(replacing)
            #expect(store.load() == replacing)

            let registered = AgentIntegrationRegistrationMarker(
                phase: .registered,
                artifact: current,
                appVersion: "2"
            )
            try store.write(registered)
            #expect(store.load() == registered)

            let ready = AgentIntegrationRegistrationMarker(
                phase: .ready,
                artifact: current,
                appVersion: "2"
            )
            try store.write(ready)
            #expect(store.load() == ready)

            try Data("invalid".utf8).write(to: store.fileURL, options: .atomic)
            #expect(store.load() == nil)
        }
    }

    @Test("helper-side identity matches only its containing app artifact")
    func artifact_matchUsesContainingAppBundle() throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Limpid.app", isDirectory: true)
            let executableDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let launchAgentDirectory = app
                .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: executableDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: launchAgentDirectory,
                withIntermediateDirectories: true
            )
            try Data("service".utf8).write(
                to: executableDirectory.appendingPathComponent("AgentIntegrationService")
            )
            try Data("plist".utf8).write(
                to: launchAgentDirectory.appendingPathComponent(
                    AgentIntegrationConfiguration.plistName
                )
            )
            let helper = executableDirectory.appendingPathComponent("AgentIntegrationHookHelper")
            let artifact = try AgentIntegrationServiceArtifact.bundled(in: app)

            #expect(try AgentIntegrationServiceArtifact.matchesBundle(
                artifact,
                containing: helper
            ))
            #expect(try !AgentIntegrationServiceArtifact.matchesBundle(
                previous,
                containing: helper
            ))
            #expect(try !AgentIntegrationServiceArtifact.matchesBundle(
                nil,
                containing: helper
            ))
        }
    }

    @Test("decodes an older bootstrap without artifact identity")
    func bootstrap_oldServiceOmitsArtifact() throws {
        let data = Data(#"{"role":"controller","serviceProcessID":42}"#.utf8)
        let bootstrap = try JSONDecoder().decode(AgentIntegrationSessionBootstrap.self, from: data)
        #expect(bootstrap.role == .controller)
        #expect(bootstrap.serviceProcessID == 42)
        #expect(bootstrap.serviceArtifact == nil)
    }

    @Test("keeps a dismissed issue hidden until retry, recovery, or a different failure")
    func issuePresentation_dismissesOnlyTheCurrentReason() {
        var presentation = AgentIntegrationIssuePresentation()
        let reconciliation = AgentIntegrationServiceIssue(
            reason: .reconciliationFailed,
            diagnostic: "first failure"
        )

        presentation.present(reconciliation)
        #expect(presentation.issue == reconciliation)

        presentation.dismiss()
        presentation.present(AgentIntegrationServiceIssue(
            reason: .reconciliationFailed,
            diagnostic: "automatic retry failed"
        ))
        #expect(presentation.issue == nil)

        let approval = AgentIntegrationServiceIssue(
            reason: .requiresApproval,
            diagnostic: nil
        )
        presentation.present(approval)
        #expect(presentation.issue == approval)

        presentation.dismiss()
        presentation.reset()
        presentation.present(reconciliation)
        #expect(presentation.issue == reconciliation)
    }

    private func action(
        _ status: AgentIntegrationRegistrationStatus,
        running: AgentIntegrationServiceArtifact?,
        registered: AgentIntegrationServiceArtifact? = nil
    ) -> AgentIntegrationRegistrationAction {
        let marker = (registered ?? (status == .enabled ? current : nil)).map {
            AgentIntegrationRegistrationMarker(phase: .ready, artifact: $0, appVersion: "2")
        }
        return AgentIntegrationRegistrationDecision.action(
            status: status,
            bundledArtifact: current,
            runningArtifact: status == .enabled ? .response(running) : .notApplicable,
            marker: marker
        )
    }
}
