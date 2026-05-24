// LimpidPaths.swift
// Limpid — branches data directory + app identity off the build's
// bundle id so the dmg-installed Release ("dev.limpid.Limpid") and a
// Debug build running out of DerivedData ("dev.limpid.Limpid.dev")
// can coexist on the same Mac without trampling each other's
// session.json, notifications.json, or scrollback dumps.

import Foundation

enum LimpidPaths {
    /// Bundle identifier of the *currently running* binary. Falls back
    /// to the Release id when the bundle dictionary is missing.
    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "dev.limpid.Limpid"
    }

    /// `true` when the running binary is the Xcode test host. Used to
    /// route data directory lookups into a sandboxed name so a test
    /// that forgets to inject `init(directory:)` doesn't reach into
    /// the user's real Application Support folder. Detected via the
    /// XCTest framework class — `Bundle.main.bundleIdentifier` is
    /// the host app's id during tests, not the test bundle's.
    static var isRunningInTests: Bool {
        NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
    }

    /// `true` when the running binary is a Debug build (suffix `.dev`).
    /// Drives both the data directory name and Sparkle's auto-check
    /// gate — we don't want a Debug build to auto-update itself out
    /// from under the Xcode runner.
    static var isDevBuild: Bool {
        bundleID.hasSuffix(".dev")
    }

    /// Folder name under `~/Library/Application Support/` where the
    /// session snapshot, notification history, scrollback dumps, and
    /// settings.json live. Different per build so a Release crash
    /// can't corrupt the in-progress Debug session and vice versa;
    /// tests route into a separate sandbox so a missed
    /// `init(directory:)` injection can't trash production data.
    static var applicationSupportDirectoryName: String {
        if isRunningInTests { return "Limpid Tests Stray" }
        return isDevBuild ? "Limpid Dev" : "Limpid"
    }

    /// Absolute URL of the per-build Application Support directory.
    /// Created on demand by the caller (`SecureFileWrite.ensureUserOnlyDirectory`).
    static func applicationSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }
}
