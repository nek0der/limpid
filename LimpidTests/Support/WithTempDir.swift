// WithTempDir.swift
// Limpid — scoped temporary directory helper for tests that need to write to
// disk without touching the user's home. The directory is created
// before `body` runs and removed afterwards, even if the body throws.

import Foundation

/// Runs `body` in the caller's isolation, so a main-actor test can hand it
/// main-actor state.
func withTempDir<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("limpid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("limpid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
