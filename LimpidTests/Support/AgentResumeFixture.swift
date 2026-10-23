// AgentResumeFixture.swift
// Limpid — a pane the resume builders would resume, so a test can take one guard away at a time.

import Foundation
@testable import Limpid

/// A pane set up as a restore leaves one the projection named a resume
/// candidate for: a remembered session for each provider, and each one in
/// `Tab.agentResumeCandidates`.
///
/// The builders return nil for a provider the projection did not name
/// before any other guard is reached, so a test that sets up the session
/// but not the candidate passes whether or not the guard it is about is
/// there. Starting from a pane that would resume, a test changes the one
/// thing its guard is about and the nil it sees is that guard's.
@MainActor
enum AgentResumeFixture {
    /// A session id the strict resume accepts.
    static let sessionID = "0f4e1b52-3a8f-4d43-9b7e-6c2a1d9e8f10"

    /// Records a session for each of `providers` on `paneID` and names each
    /// one a resume candidate there.
    static func stage(
        _ providers: Set<AgentKind>,
        on tab: inout Tab,
        paneID: UUID,
        sessionID: String = sessionID,
        cwd: String? = nil
    ) {
        for provider in providers {
            tab.agentSessions[provider, default: [:]][paneID] = AgentSessionInfo(sessionId: sessionID, cwd: cwd)
        }
        tab.agentResumeCandidates[paneID, default: []].formUnion(providers)
    }

    /// A single-pane loose tab whose pane would resume each of `providers`.
    static func tab(
        _ providers: Set<AgentKind>,
        sessionID: String = sessionID,
        cwd: String? = nil
    ) -> (tab: Tab, paneID: UUID) {
        let paneID = UUID()
        var tab = Tab(title: "t", splitTree: SplitTree(leafID: paneID), container: .loose)
        stage(providers, on: &tab, paneID: paneID, sessionID: sessionID, cwd: cwd)
        return (tab, paneID)
    }
}
