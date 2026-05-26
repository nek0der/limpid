// SurfaceView+Environment.swift
// Limpid — `ghostty_env_var_s` array construction for `SurfaceView`.
// Lives outside `SurfaceView.swift` so the host file stays under the
// SwiftLint file-length warning band; the actual call site is in
// `createSurface()`.

import AppKit
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "surface.env")

extension SurfaceView {
    /// Materialize `extraEnvironment` into a strdup'd `ghostty_env_var_s`
    /// array on `config`. Pointers are stashed on self so they outlive
    /// the `ghostty_surface_new` call and get freed in deinit alongside
    /// the cwd / scrollback buffers. If any strdup fails we abandon the
    /// whole injection rather than ship a partially-populated array.
    func applyExtraEnvironment(into config: inout ghostty_surface_config_s) {
        guard !extraEnvironment.isEmpty else { return }
        let count = extraEnvironment.count
        let buf = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: count)
        for (i, (key, value)) in extraEnvironment.enumerated() {
            guard let kBuf = strdup(key), let vBuf = strdup(value) else {
                log.error("strdup(env_var) returned NULL — skipping env injection")
                for j in 0..<i {
                    free(UnsafeMutableRawPointer(mutating: buf[j].key))
                    free(UnsafeMutableRawPointer(mutating: buf[j].value))
                }
                buf.deallocate()
                envKeyBuffers.removeAll()
                envValueBuffers.removeAll()
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
