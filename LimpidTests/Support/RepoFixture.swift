// RepoFixture.swift
// Shared helper: locates the Limpid repo root the test bundle was built
// from, and gates smoke tests that rely on `git` + a real `.git`
// directory being present.

import Foundation

/// Anchors smoke-test discovery to the source tree the test bundle was
/// compiled from instead of the runner's CWD. Without this, tests fall
/// back to `NSHomeDirectory()` when the host is run under sandboxed CI.
enum RepoFixture {
    /// Walk up from this file until a `.git` directory is found.
    /// Returns nil when the build was unpacked without source (e.g.
    /// shipped test bundles).
    static let limpidRoot: URL? = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
        }
        return nil
    }()

    /// True when the test host can shell out to `git` against a real
    /// working copy. Smoke tests should `XCTSkipUnless(hasLocalRepo)`.
    static var hasLocalRepo: Bool {
        limpidRoot != nil
    }
}
