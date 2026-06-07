// StringPathExtensions.swift
// Limpid — Small path-shape helpers we reach for from a couple of
// places that compare URL paths (Swift's URL Codable round-trips
// project roots as `file:///path/` with a trailing slash, while shim
// payloads hand us `/path` without). Kept here rather than buried in
// `LimpidApp.swift` so the per-file length budget doesn't keep
// drifting.

import Foundation

extension String {
    /// Drops trailing `/` characters while keeping a single `/` if the
    /// path collapses to root. Used to normalize project rootURL paths
    /// (which Swift's URL Codable likes to round-trip with a trailing
    /// slash) before comparing with hook-supplied paths (which have
    /// none).
    var trimmedTrailingSlash: String {
        var s = self
        while s.count > 1, s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
