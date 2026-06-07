// GhosttyFFI.swift
// Limpid — Swift-friendly wrapper around libghostty's C ABI; the only
// place in the app allowed to call `ghostty_*` symbols directly.

import Foundation
import GhosttyKit

/// Thin wrapper around libghostty's C ABI.
///
/// All C API access lives here. Upper layers must not call `ghostty_*`
/// symbols directly — extend this enum with a Swift-friendly signature
/// instead.
enum GhosttyFFI {
    /// Returns the embedded libghostty version string (e.g. "1.3.1").
    static func version() -> String {
        let info = ghostty_info()
        guard let cstr = info.version else { return "unknown" }
        let bytes = UnsafeBufferPointer(start: cstr, count: Int(info.version_len))
        let data = Data(bytes.map { UInt8(bitPattern: $0) })
        return String(bytes: data, encoding: .utf8) ?? "unknown"
    }

    /// Build mode libghostty was compiled with.
    static func buildMode() -> String {
        switch ghostty_info().build_mode {
        case GHOSTTY_BUILD_MODE_DEBUG: "debug"
        case GHOSTTY_BUILD_MODE_RELEASE_SAFE: "release-safe"
        case GHOSTTY_BUILD_MODE_RELEASE_FAST: "release-fast"
        case GHOSTTY_BUILD_MODE_RELEASE_SMALL: "release-small"
        default: "unknown"
        }
    }
}
