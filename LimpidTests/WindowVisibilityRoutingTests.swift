// WindowVisibilityRoutingTests.swift
// Limpid — pane reports and window presence combined into the terminals' visible set.

import AppKit
import Foundation
import Testing
@testable import Limpid

@Suite(.hostsWindows)
@MainActor
struct WindowVisibilityRoutingTests {
    @Test func aReport_reachesTheTerminals() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        let pane = UUID()

        PaneVisibilityReporter(windowID: registry.primary.id, registry: registry)
            .report(PaneAreaDisplay(leafIDs: [pane], zoomedLeafID: nil, review: .closed))

        #expect(recorder.applied.last == [pane])
    }

    @Test func anOffScreenWindow_putsItsPanesToSleepAndGetsThemBack() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        let pane = UUID()
        registry.didReportVisibility(window: registry.primary.id, paneIDs: [pane])

        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: false)
        #expect(recorder.applied.last == [])

        // The pane area does not report again when the window comes back;
        // the registry kept its last report.
        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: true)
        #expect(recorder.applied.last == [pane])
    }

    @Test func aReportWhileOffScreen_waitsForTheWindow() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        let pane = UUID()

        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: false)
        registry.didReportVisibility(window: registry.primary.id, paneIDs: [pane])
        #expect(recorder.applied.last == [])

        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: true)
        #expect(recorder.applied.last == [pane])
    }

    @Test func aWindowGoingOffScreen_leavesTheOtherWindowsPanesAwake() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        let other = registry.addWindow(WindowID()).id
        let mine = UUID()
        let theirs = UUID()
        registry.didReportVisibility(window: registry.primary.id, paneIDs: [mine])
        registry.didReportVisibility(window: other, paneIDs: [theirs])
        #expect(recorder.applied.last == [mine, theirs])

        registry.windowScreenPresenceChanged(other, isOnScreen: false)

        #expect(recorder.applied.last == [mine])
    }

    @Test func aReporterOutsideAWindow_reportsNowhere() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder

        PaneVisibilityReporter().report(PaneAreaDisplay(leafIDs: [UUID()], zoomedLeafID: nil, review: .closed))

        #expect(recorder.applied.isEmpty)
    }

    @Test func occlusionSync_reportsAWindowNotYetShownAsOffScreen() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        registry.didReportVisibility(window: registry.primary.id, paneIDs: [UUID()])
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

        let sync = WindowOcclusionSync(windowID: registry.primary.id, registry: registry, window: window)

        #expect(recorder.applied.last == [])
        withExtendedLifetime(sync) {}
    }

    @Test func aDisplay_reportsDrawingAndSeenSeparately() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        let zoomed = UUID()
        let sibling = UUID()
        let display = PaneAreaDisplay(leafIDs: [zoomed, sibling], zoomedLeafID: zoomed, review: .closed)

        PaneVisibilityReporter(windowID: registry.primary.id, registry: registry).report(display)

        // The zoom hides its sibling from the person, not from drawing.
        #expect(recorder.applied.last == [zoomed, sibling])
        #expect(registry.attention.attendedPanes == [zoomed])
    }

    @Test func anOffScreenWindow_isNotSeenEither() {
        let registry = WindowRegistry(primaryID: WindowID())
        let pane = UUID()
        registry.appActivityChanged(isActive: true)
        registry.didReportDisplay(window: registry.primary.id, rendered: [pane], attended: [pane])
        #expect(registry.attention.isSeen(pane))

        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: false)

        #expect(!registry.attention.isSeen(pane))
    }

    @Test func wakingAPane_doesNotMakeItSeen() {
        let registry = WindowRegistry(primaryID: WindowID())
        let recorder = OcclusionRecorder()
        registry.occlusion = recorder
        registry.appActivityChanged(isActive: true)
        let pane = UUID()

        PaneVisibilityReporter(windowID: registry.primary.id, registry: registry).wake([pane])

        #expect(recorder.applied.last == [pane])
        #expect(!registry.attention.isSeen(pane))
    }

    @Test func appFacts_reachTheAttentionValue() {
        let registry = WindowRegistry(primaryID: WindowID())
        registry.appActivityChanged(isActive: true)
        registry.voiceOverChanged(isRunning: true)
        #expect(registry.attention.isAppActive)
        #expect(registry.attention.isVoiceOverRunning)
    }

    @Test func aWindowBackOnScreen_isSeenAgainWithoutANewReport() {
        let registry = WindowRegistry(primaryID: WindowID())
        let pane = UUID()
        registry.appActivityChanged(isActive: true)
        registry.didReportDisplay(window: registry.primary.id, rendered: [pane], attended: [pane])
        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: false)

        registry.windowScreenPresenceChanged(registry.primary.id, isOnScreen: true)

        #expect(registry.attention.isSeen(pane))
    }

    @Test func oneWindowOffScreen_leavesTheOthersPanesSeen() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID()).id
        let mine = UUID()
        let theirs = UUID()
        registry.appActivityChanged(isActive: true)
        registry.didReportDisplay(window: registry.primary.id, rendered: [mine], attended: [mine])
        registry.didReportDisplay(window: other, rendered: [theirs], attended: [theirs])

        registry.windowScreenPresenceChanged(other, isOnScreen: false)

        #expect(registry.attention.attendedPanes == [mine])
    }

    /// A window the registry does not list: one never listed, or one
    /// closed, whose view can report once more as it goes.
    enum UnlistedWindow: CaseIterable, Sendable {
        case neverListed
        case closed
    }

    /// The registry, with `window` gone from it or never in it.
    private static func registry(
        with window: UnlistedWindow,
        recorder: OcclusionRecorder
    ) throws -> (registry: WindowRegistry, unlisted: WindowID) {
        let session = WorkspaceSession()
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.occlusion = recorder
        switch window {
        case .neverListed:
            return (registry, WindowID())
        case .closed:
            let id = WorkspaceSessionFixture.addWindow(to: session)
            try registry.addWindow(#require(session.selection(id)))
            registry.didReportVisibility(window: id, paneIDs: [UUID()])
            registry.close(id, in: session)
            recorder.applied = []
            return (registry, id)
        }
    }

    /// Its panes must not count as drawn or seen.
    @Test(arguments: UnlistedWindow.allCases)
    func aReportFromAWindowNotListed_isDropped(_ window: UnlistedWindow) throws {
        let recorder = OcclusionRecorder()
        let (registry, unlisted) = try Self.registry(with: window, recorder: recorder)
        let mine = UUID()
        registry.appActivityChanged(isActive: true)
        registry.didReportDisplay(window: registry.primary.id, rendered: [mine], attended: [mine])

        registry.didReportDisplay(window: unlisted, rendered: [UUID()], attended: [UUID()])
        registry.didReportVisibility(window: unlisted, paneIDs: [UUID()])

        #expect(registry.visibility.union == [mine])
        #expect(registry.attention.attendedPanes == [mine])
        #expect(recorder.applied.last == [mine])
    }

    @Test(arguments: UnlistedWindow.allCases)
    func aScreenPresenceReportFromAWindowNotListed_isDropped(_ window: UnlistedWindow) throws {
        let recorder = OcclusionRecorder()
        let (registry, unlisted) = try Self.registry(with: window, recorder: recorder)
        let pane = UUID()

        registry.windowScreenPresenceChanged(unlisted, isOnScreen: false)
        registry.windowScreenPresenceChanged(unlisted, isOnScreen: true)
        registry.windowScreenPresenceChanged(unlisted, isOnScreen: false)
        #expect(recorder.applied.isEmpty)

        // Listed later under the same ID, the window is not held off
        // screen by what was said while it was not listed.
        registry.addWindow(unlisted)
        registry.didReportVisibility(window: unlisted, paneIDs: [pane])
        #expect(recorder.applied.last == [pane])
    }

    @Test func reportedVisibility_reachesTheUnion() {
        let registry = WindowRegistry(primaryID: WindowID())
        let pane = UUID()

        registry.didReportVisibility(window: registry.primary.id, paneIDs: [pane])
        #expect(registry.visibility.union == [pane])

        registry.didReportVisibility(window: registry.primary.id, paneIDs: [])
        #expect(registry.visibility.union.isEmpty)
    }
}
