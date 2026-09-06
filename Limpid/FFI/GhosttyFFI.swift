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

    /// The pty device the surface's shell is attached to
    /// (`/dev/ttys016`), or `nil` when libghostty cannot report one.
    ///
    /// This is what lets us ask tmux which session a pane is showing:
    /// tmux names its clients by tty, so the two meet here. libghostty
    /// hands back a copy it allocated, so the caller frees it — the
    /// `defer` is unconditional because `ghostty_string_free` returns
    /// early on the null pointer an unavailable name comes back as.
    static func surfaceTTYName(_ surface: ghostty_surface_t) -> String? {
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr, name.len > 0 else { return nil }
        // Failable rather than `String(decoding:)`: a device path that
        // is not valid UTF-8 is not a tty we can hand to tmux, and
        // replacement characters would only push the failure further on.
        let bytes = UnsafeRawBufferPointer(start: ptr, count: Int(name.len))
        guard let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Complete a clipboard read request with a single `text/plain`
    /// representation.
    ///
    /// libghostty takes the payload by pointer and borrows it only for
    /// the duration of the call, so the MIME string, the data, and both
    /// structs stay on the stack until it returns.
    static func completeClipboardRequest(
        surface: ghostty_surface_t,
        text: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        "text/plain".withCString { mime in
            text.withCString { data in
                var content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: data,
                    len: text.utf8.count
                )
                withUnsafePointer(to: &content) { contents in
                    var payload = ghostty_clipboard_complete_s(
                        contents: contents,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: confirmed,
                        remember: false
                    )
                    withUnsafePointer(to: &payload) { ptr in
                        ghostty_surface_complete_clipboard_request(surface, ptr, state)
                    }
                }
            }
        }
    }

    /// The first text-like representation carried by a clipboard
    /// confirmation payload, or an empty string when it holds none.
    ///
    /// The payload is only valid for the duration of the callback that
    /// received it, so this has to run synchronously inside that frame.
    /// See `GhosttyApp.confirmReadClipboardCallback` for what deferring
    /// it costs.
    static func clipboardText(
        from confirm: UnsafePointer<ghostty_clipboard_confirm_s>
    ) -> String {
        let payload = confirm.pointee
        guard let contents = payload.contents else { return "" }
        for index in 0..<payload.contents_len {
            let content = contents[index]
            guard let mime = content.mime, let data = content.data,
                  String(cString: mime).hasPrefix("text/")
            else { continue }
            let bytes = UnsafeRawBufferPointer(start: data, count: content.len)
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        return ""
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
