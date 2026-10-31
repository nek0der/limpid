// WeirPaths.swift
// Weir — branches data directory + app identity off the build's
// bundle id so the dmg-installed Release ("com.nekoder.Weir") and a
// Debug build running out of DerivedData ("com.nekoder.Weir.dev")
// can coexist on the same Mac without trampling each other's
// state.json, notifications.json, or scrollback dumps.

import Foundation

enum WeirPaths {
    /// Bundle identifier of the *currently running* binary. Falls back
    /// to the Release id when the bundle dictionary is missing.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.nekoder.Weir"
    }

    /// `true` when the running binary is the Xcode test host. Used to
    /// move the data directory out of `~/Library` and to arm
    /// `TestWriteGuard`, so a test that forgets to inject
    /// `init(directory:)` cannot reach the user's real data.
    /// `Bundle.main.bundleIdentifier` is the host app's id during tests,
    /// not the test bundle's, so it cannot tell.
    static var isRunningInTests: Bool {
        isTestHostByEnvironment || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
    }

    /// The variables Xcode sets on the test host before it starts. The
    /// XCTest classes are loaded only once the test bundle is injected, so
    /// the host app's launch could ask before they exist and save into the
    /// real folder; the environment is there from the first instruction.
    static let isTestHostByEnvironment: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }()

    /// `true` when the running binary is a Debug build (suffix `.dev`).
    /// Drives both the data directory name and Sparkle's auto-check
    /// gate — we don't want a Debug build to auto-update itself out
    /// from under the Xcode runner.
    static var isDevBuild: Bool {
        bundleID.hasSuffix(".dev")
    }

    /// Folder name under `~/Library/Application Support/` where the
    /// session snapshot (`state.json`), notification history
    /// (`notifications.json`), scrollback dumps, review drafts
    /// (`reviews/`), and `settings.json`
    /// live. Different per build so a Release crash can't corrupt the
    /// in-progress Debug session and vice versa.
    static var applicationSupportDirectoryName: String {
        isDevBuild ? "Weir Dev" : "Weir"
    }

    /// Absolute URL of the per-build Application Support directory.
    /// Created on demand by the caller (`SecureFileWrite.ensureUserOnlyDirectory`).
    /// Under the test host it is a folder of this process in the temporary
    /// directory instead: the host app runs its whole launch during a test
    /// run and saves its session, and `TestWriteGuard` refuses a
    /// `SecureFileWrite` change inside `~/Library`. A fresh folder per run
    /// also keeps one run's saved session from being restored into the next.
    static func applicationSupportDirectory() -> URL {
        if isRunningInTests {
            return testRunDirectory
        }
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    /// Where the test host keeps what it would keep in Application Support.
    /// Fixed for the process so every store and the host app agree on it.
    /// Named by a UUID rather than the process id, which the system reuses,
    /// so no run finds an earlier run's session.
    private static let testRunDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Weir Tests \(UUID().uuidString)", isDirectory: true)
}
