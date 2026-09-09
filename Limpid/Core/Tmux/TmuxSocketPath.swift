// TmuxSocketPath.swift
// Limpid — canonical filesystem identity shared by every tmux boundary.

import Foundation

/// We keep persisted paths as strings, but compare physical absolute paths.
/// Foundation's URL standardization may shorten an existing `/private/tmp`
/// path to `/tmp`. Mixing that with a manual prefix expansion makes repeated
/// normalization alternate between two values. POSIX realpath gives us one
/// representation, including for user-defined directory symlinks.
struct TmuxSocketPath: Hashable {
    let value: String

    init?(_ path: String) {
        guard path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0) else { return nil }
        var components = path.split(separator: "/").map(String.init)
        var missingSuffix: [String] = []
        while true {
            let candidate = "/" + components.joined(separator: "/")
            if let physical = Self.resolve(candidate) {
                var result = physical.split(separator: "/").map(String.init)
                // A socket may not exist during restore or after detach.
                // Resolve the nearest existing ancestor and retain its suffix
                // so creating/removing the socket does not change its key.
                for component in missingSuffix.reversed() {
                    switch component {
                    case ".": continue
                    case "..": if !result.isEmpty {
                            result.removeLast()
                        }
                    default: result.append(component)
                    }
                }
                self.value = "/" + result.joined(separator: "/")
                return
            }
            guard let component = components.popLast() else { return nil }
            missingSuffix.append(component)
        }
    }

    private static func resolve(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return buffer.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return nil }
            return String(validatingCString: base)
        }
    }
}
