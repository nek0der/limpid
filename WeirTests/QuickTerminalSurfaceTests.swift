// QuickTerminalSurfaceTests.swift
// Weir — the quick terminal's surface, freed after its shell exits.

import AppKit
import Foundation
import Testing
@testable import Weir

@Suite("QuickTerminal surface")
@MainActor
struct QuickTerminalSurfaceTests {

    // MARK: - Surface lifecycle

    /// The quick terminal's surface has to be freed after its shell exits:
    /// otherwise every exit leaks a libghostty surface and a
    /// `liveViewsByPointer` entry. The view is retained by the controller,
    /// the hosting view's representable, and the scroll host's subview
    /// list, so dropping only the controller's reference is not enough.
    ///
    /// Needs the host app's `GhosttyApp` (a process-wide singleton); the
    /// surface it mounts starts a real shell, which the view's `deinit`
    /// frees. The panel is never ordered on screen.
    ///
    /// Async on purpose. SwiftUI's update pass, the representable's
    /// deferred `createSurface`, and AppKit's own deferred view work are
    /// main-queue blocks; a synchronous test body occupies the main queue,
    /// so they would never run, and the references they hold would never be
    /// released. Sleeping hands the main thread back to the app's run loop
    /// instead.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func handleSurfaceExit_releasesTheSurfaceView() async throws {
        try await withTempDir { @Sendable directory in
            try await Self.exerciseSurfaceExit(settingsDirectory: directory)
        }
    }

    /// Mounts the quick terminal's surface, ends its shell, and checks the
    /// view is freed. Needs the host app's `GhosttyApp`, which only exists
    /// when libghostty started.
    private static func exerciseSurfaceExit(settingsDirectory directory: URL) async throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let controller = QuickTerminalController(
            settingsStore: SettingsStore(directory: directory),
            reduceTransparencyResolver: ReduceTransparencyResolver(),
            clipboard: ClipboardConfirmationCoordinator(),
            secureInputManager: SecureInputManager(),
            surfaceFactory: {
                PaneHostRepresentable.makeSurfaceView(
                    ghosttyApp: ghosttyApp,
                    environment: AppState.quickTerminalEnvironment
                )
            }
        )
        weak var probe: SurfaceView?
        autoreleasepool {
            controller.panel.setFrame(NSRect(x: 0, y: 0, width: 640, height: 400), display: false)
            controller.prepareSurface()
            probe = controller.surfaceView
        }
        #expect(probe != nil)

        // Let SwiftUI mount the representable so the hierarchy holds the
        // view the way it does on screen.
        await Self.waitUntil { probe?.window != nil }
        try autoreleasepool {
            let view = try #require(probe)
            #expect(view.window === controller.panel, "the surface was never mounted in the panel")
            #expect(view.surface != nil, "libghostty never created the surface")
            #expect(controller.handleSurfaceExit(view))
            #expect(controller.surfaceView == nil)
            #expect(!controller.handleSurfaceExit(view), "a second exit for the same view is not ours")
        }

        await Self.waitUntil { probe == nil }
        #expect(probe == nil, "the quick terminal's SurfaceView outlived its shell")
        withExtendedLifetime(controller) {}
    }

    /// Poll `condition` every 20 ms for up to ten seconds, yielding the
    /// main thread to the run loop between checks. The ceiling only
    /// matters on a loaded machine; a passing run returns within a few
    /// polls.
    private static func waitUntil(_ condition: () -> Bool) async {
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
            autoreleasepool(invoking: condition)
        }
    }
}
