// SurfaceView+Environment.swift
// Limpid — `ghostty_env_var_s` array construction for `SurfaceView`.
// Lives outside `SurfaceView.swift` so the host file stays under the
// SwiftLint file-length warning band; the actual call site is in
// `createSurface()`.

import AppKit
import GhosttyKit
import OSLog

private let log = Logger.limpid("surface.env")

extension SurfaceView {
    /// Materialize `extraEnvironment` into a strdup'd `ghostty_env_var_s`
    /// array on `config`. Pointers are stashed on self so they outlive
    /// the `ghostty_surface_new` call and get freed in deinit alongside
    /// the cwd / scrollback buffers. If any strdup fails we abandon the
    /// whole injection rather than ship a partially-populated array.
    func applyExtraEnvironment(into config: inout ghostty_surface_config_s) {
        // Reset any buffers a prior `createSurface` attempt installed
        // before re-running the strdup loop. `PaneHostView.updateNSView`
        // retries `createSurface` whenever the first call returned
        // `surface == nil`, so without this pre-clear (a) the prior
        // `envVarsBuffer` was overwritten without being deallocated,
        // and (b) the per-pair strdups stacked into
        // `envKeyBuffers` / `envValueBuffers` until the abandon path
        // erased them with `removeAll()` and the underlying mallocs
        // were stranded permanently. Mirrors the cwd / scrollback
        // reset already performed at the top of `createSurface`.
        for buf in envKeyBuffers {
            free(buf)
        }
        envKeyBuffers.removeAll()
        for buf in envValueBuffers {
            free(buf)
        }
        envValueBuffers.removeAll()
        if let existing = envVarsBuffer {
            existing.deallocate()
            envVarsBuffer = nil
        }
        guard !extraEnvironment.isEmpty else { return }
        let count = extraEnvironment.count
        let buf = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: count)

        /// Free the pairs stored so far, drop the buffer, and bail rather than
        /// ship a partially-populated array. The per-pair arrays are
        /// already empty from the pre-clear above, so `abandon` only
        /// needs to wind back this call's strdups + buffer.
        func abandon(storedPairs i: Int) {
            for j in 0..<i {
                free(UnsafeMutableRawPointer(mutating: buf[j].key))
                free(UnsafeMutableRawPointer(mutating: buf[j].value))
            }
            buf.deallocate()
            envKeyBuffers.removeAll()
            envValueBuffers.removeAll()
        }

        for (i, (key, value)) in extraEnvironment.enumerated() {
            guard let kBuf = strdup(key) else {
                log.error("strdup(env key) returned NULL — skipping env injection")
                abandon(storedPairs: i)
                return
            }
            // The key succeeded; if the value's strdup fails we must free the
            // key here — `abandon` only covers the fully-stored pairs (0..<i).
            guard let vBuf = strdup(value) else {
                free(kBuf)
                log.error("strdup(env value) returned NULL — skipping env injection")
                abandon(storedPairs: i)
                return
            }
            envKeyBuffers.append(kBuf)
            envValueBuffers.append(vBuf)
            buf[i] = ghostty_env_var_s(key: UnsafePointer(kBuf), value: UnsafePointer(vBuf))
        }
        envVarsBuffer = buf
        config.env_vars = buf
        config.env_var_count = count
    }
}
