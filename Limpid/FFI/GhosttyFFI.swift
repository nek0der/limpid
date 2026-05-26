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
/// Opaque carrier for `ghostty_surface_config_s`. Lets Core / UI layers
/// pass an inherited config around without depending on the C struct
/// directly. Only `GhosttyFFI` and the AppKit surface bridge unwrap it.
struct InheritedSurfaceConfig: @unchecked Sendable {
    var raw: ghostty_surface_config_s
}

enum GhosttyFFI {
    /// Returns the embedded libghostty version string (e.g. "1.3.1").
    static func version() -> String {
        let info = ghostty_info()
        guard let cstr = info.version else { return "unknown" }
        let bytes = UnsafeBufferPointer(start: cstr, count: Int(info.version_len))
        let data = Data(bytes.map { UInt8(bitPattern: $0) })
        return String(bytes: data, encoding: .utf8) ?? "unknown"
    }

    /// Ask libghostty for a `surface_config_s` that inherits the source
    /// surface's environment (cwd, command, font, scroll history) for a
    /// new sibling. Used when libghostty fires `NEW_SPLIT` so the new
    /// pane starts in the same directory as the originating pane.
    /// The result is wrapped in `InheritedSurfaceConfig` so layers above
    /// FFI never need to import `GhosttyKit` just to pass the value
    /// around.
    static func inheritedConfig(
        from surface: ghostty_surface_t,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT
    ) -> InheritedSurfaceConfig {
        InheritedSurfaceConfig(raw: ghostty_surface_inherited_config(surface, context))
    }

    /// Fire one of libghostty's named binding actions against the
    /// given surface. The wrapped C function understands the same
    /// action grammar as the user's keybind config — `scroll_to_top`,
    /// `scroll_to_bottom`, `scroll_to_row:42`, `jump_to_prompt:-3`,
    /// etc. Returns `true` when libghostty recognised and handled
    /// the action; `false` for unknown strings.
    ///
    /// Used by the prompt-history sidebar to scroll a terminal back
    /// to the line of a previously submitted prompt (paired with the
    /// OSC 133;A markers the hook emits on `UserPromptSubmit`).
    @discardableResult
    static func bindingAction(_ surface: ghostty_surface_t, action: String) -> Bool {
        let bytes = Array(action.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cstr in
                ghostty_surface_binding_action(surface, cstr, UInt(buf.count))
            }
        }
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
