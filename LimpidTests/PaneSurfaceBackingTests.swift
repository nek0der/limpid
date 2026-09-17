// PaneSurfaceBackingTests.swift
// Limpid — pins that only a local pane is given a process of its own.

import Foundation
import Testing
@testable import Limpid

/// The factory itself needs a live `GhosttyApp`, so we pin the decision it
/// is built on instead.
@MainActor
@Suite("Pane surface backing")
struct PaneSurfaceBackingTests {
    private let paneID = UUID()

    private var tmuxSource: PaneIOSource {
        .tmux(TmuxPaneRef(
            binding: TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work"),
            windowID: "@2",
            paneID: "%7"
        ))
    }

    @Test("a local pane starts its own process")
    func local_ownsProcess() {
        let backing = PaneHostRepresentable.surfaceBacking(for: .local, paneID: paneID, tmuxStore: nil)
        #expect(backing == .ownProcess)
    }

    @Test("an unavailable pane reads its leaf's channel, not a shell")
    func unavailable_withStore_getsLeafChannel() throws {
        let store = TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let backing = PaneHostRepresentable.surfaceBacking(for: .unavailable, paneID: paneID, tmuxStore: store)
        let channel = try #require(store.channel(paneID: paneID))
        #expect(backing == .channel(channel))
    }

    @Test("a tmux pane with no live mirror reads its leaf's channel")
    func tmux_withoutMirror_getsLeafChannel() throws {
        let store = TmuxConnectionStore(registry: RecordingSurfaceRegistry(), secureInput: nil, tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let backing = PaneHostRepresentable.surfaceBacking(for: tmuxSource, paneID: paneID, tmuxStore: store)
        let channel = try #require(store.channel(paneID: paneID))
        #expect(backing == .channel(channel))
    }

    @Test("without a store a pane that is not local gets no surface")
    func notLocal_withoutStore_getsNoSurface() {
        for source in [tmuxSource, .unavailable] {
            let backing = PaneHostRepresentable.surfaceBacking(for: source, paneID: paneID, tmuxStore: nil)
            #expect(backing == .noSurface)
        }
    }
}
