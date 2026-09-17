// TmuxSurfaceReportsTests.swift
// Limpid — the store keeps each tmux leaf's and mirror tab's reports without a mirror, and only its mirrors are observable.

import CoreGraphics
import Foundation
import Observation
import os
import Testing
@testable import Limpid

@MainActor
@Suite("tmux surface reports")
struct TmuxSurfaceReportsTests {
    private static let binding = TmuxBinding(socketPath: "/tmp/limpid-none/sock", sessionID: "$0", sessionName: "t")
    private static let ref = TmuxPaneRef(binding: binding, windowID: "@1", paneID: "%0")
    private static let cellSize = CellSize(width: 8, height: 16)
    private static let areaSize = CGSize(width: 640, height: 384)

    /// A mirror tab with one `.tmux` leaf whose channel the surface took.
    private struct MirrorTab {
        let session: WindowSession
        let store: TmuxConnectionStore
        let tabID: UUID
        let leafID: UUID
    }

    private func makeMirrorTab() throws -> MirrorTab {
        let (session, tab, leafID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.paneSources[leafID] = .tmux(Self.ref)
        }
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        store.reconcile(tabs: session.tabs)
        _ = try #require(store.channel(paneID: leafID))
        return MirrorTab(session: session, store: store, tabID: tab.id, leafID: leafID)
    }

    private func report(to store: TmuxConnectionStore, leafID: UUID, tabID: UUID) {
        store.cellSizeChanged(Self.cellSize, paneID: leafID)
        store.mirrorGridResized(columns: 80, rows: 24, paneID: leafID)
        store.areaSizeChanged(Self.areaSize, tabID: tabID)
    }

    @Test("reports for a leaf and a tab with no mirror are recorded")
    func reportsWithoutMirror_areRecorded() throws {
        let fixture = try makeMirrorTab()
        let (store, tabID, leafID) = (fixture.store, fixture.tabID, fixture.leafID)
        defer { store.reconcile(tabs: []) }
        #expect(store.mirror(for: tabID) == nil)

        report(to: store, leafID: leafID, tabID: tabID)

        #expect(store.surfaceReports.cellSizes == [leafID: Self.cellSize])
        #expect(store.surfaceReports.grids == [leafID: TmuxWindowMirror.Grid(columns: 80, rows: 24)])
        #expect(store.surfaceReports.areaSizes == [tabID: Self.areaSize])
    }

    @Test("a local pane's reports are not recorded")
    func localPane_isNotRecorded() {
        let (session, _, leafID) = WindowSessionFixture.withLooseTab()
        let store = TmuxConnectionStore(tmuxExecutable: nil)
        defer { store.reconcile(tabs: []) }
        store.reconcile(tabs: session.tabs)

        store.cellSizeChanged(Self.cellSize, paneID: leafID)
        store.mirrorGridResized(columns: 80, rows: 24, paneID: leafID)

        #expect(store.surfaceReports == TmuxSurfaceReports())
    }

    @Test("a leaf that left the tab takes its reports with it, and the tab keeps its area")
    func removedLeaf_forgetsItsReports() throws {
        let fixture = try makeMirrorTab()
        let (session, store, tabID, leafID) = (fixture.session, fixture.store, fixture.tabID, fixture.leafID)
        defer { store.reconcile(tabs: []) }
        report(to: store, leafID: leafID, tabID: tabID)

        session.update(tabID) { $0.paneSources[leafID] = .local }
        store.reconcile(tabs: session.tabs)

        #expect(store.surfaceReports.cellSizes.isEmpty)
        #expect(store.surfaceReports.grids.isEmpty)
        #expect(store.surfaceReports.areaSizes == [tabID: Self.areaSize])
    }

    @Test("a closed tab takes its area and its leaves' reports with it")
    func removedTab_forgetsItsReports() throws {
        let fixture = try makeMirrorTab()
        let (store, tabID, leafID) = (fixture.store, fixture.tabID, fixture.leafID)
        report(to: store, leafID: leafID, tabID: tabID)

        store.reconcile(tabs: [])

        #expect(store.surfaceReports == TmuxSurfaceReports())
    }

    @Test("registering and dropping a mirror is observed, and the reports are not")
    func mirrors_areTheOnlyObservedState() throws {
        let fixture = try makeMirrorTab()
        let (session, store, tabID, leafID) = (fixture.session, fixture.store, fixture.tabID, fixture.leafID)
        defer { store.reconcile(tabs: []) }
        let connection = TmuxServerConnection(
            executable: "/usr/bin/false",
            target: .init(socketPath: Self.binding.socketPath, sessionID: Self.binding.sessionID)
        )
        let mirror = TmuxWindowMirror(
            tabID: tabID,
            windowID: "@1",
            sessionName: "t",
            windowName: "w",
            connection: connection,
            session: session,
            registry: RecordingSurfaceRegistry(),
            secureInput: nil,
            channelForPane: { store.channel(paneID: $0) },
            surfaceReports: { store.surfaceReports }
        )

        let isReportChangeObserved = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.surfaceReports
            _ = store.connections
        } onChange: {
            isReportChangeObserved.withLock { $0 = true }
        }
        report(to: store, leafID: leafID, tabID: tabID)
        #expect(!isReportChangeObserved.withLock { $0 })
        // Control: the record did change, so the silence above is not from
        // nothing having changed.
        #expect(store.surfaceReports.areaSizes[tabID] == Self.areaSize)

        let isRegisterObserved = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.mirror(for: tabID)
        } onChange: {
            isRegisterObserved.withLock { $0 = true }
        }
        store.register(mirror)
        #expect(isRegisterObserved.withLock { $0 })
        #expect(store.mirror(for: tabID) === mirror)

        let isDropObserved = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.mirror(for: tabID)
        } onChange: {
            isDropObserved.withLock { $0 = true }
        }
        store.reconcile(tabs: [])
        #expect(isDropObserved.withLock { $0 })
        #expect(store.mirror(for: tabID) == nil)
    }
}
