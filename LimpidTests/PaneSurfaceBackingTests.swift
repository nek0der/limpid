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
    private let tabID = UUID()

    private var tmuxSource: PaneIOSource {
        .tmux(TmuxPaneRef(
            binding: TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work"),
            windowID: "@2",
            paneID: "%7"
        ))
    }

    @Test("a local pane starts its own process")
    func local_ownsProcess() {
        let backing = PaneHostRepresentable.surfaceBacking(for: .local, paneID: paneID, tabID: tabID, tmuxStore: nil)
        #expect(backing == .ownProcess)
    }

    @Test("an unavailable pane reads the dormant descriptor, not a shell")
    func unavailable_withStore_getsDormantDescriptor() throws {
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let backing = PaneHostRepresentable.surfaceBacking(for: .unavailable, paneID: paneID, tabID: tabID, tmuxStore: store)
        let dormant = try #require(store.dormantSink(paneID: paneID))
        #expect(backing == .descriptor(dormant.surfaceFd))
    }

    @Test("a tmux pane with no live mirror reads the dormant descriptor")
    func tmux_withoutMirror_getsDormantDescriptor() throws {
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        let backing = PaneHostRepresentable.surfaceBacking(for: tmuxSource, paneID: paneID, tabID: tabID, tmuxStore: store)
        let dormant = try #require(store.dormantSink(paneID: paneID))
        #expect(backing == .descriptor(dormant.surfaceFd))
    }

    @Test("without a store a pane that is not local gets no surface")
    func notLocal_withoutStore_getsNoSurface() {
        for source in [tmuxSource, .unavailable] {
            let backing = PaneHostRepresentable.surfaceBacking(for: source, paneID: paneID, tabID: tabID, tmuxStore: nil)
            #expect(backing == .noSurface)
        }
    }
}
