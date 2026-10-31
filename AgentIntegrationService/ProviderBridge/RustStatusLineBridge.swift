// RustStatusLineBridge.swift
// Weir — Swift wrapper around the status line relay's C ABI, for the Hook Helper.

import Foundation
import WeirRustBridge

/// The status line calls of the Rust bridge: the relay itself and the setting
/// the shim launches the provider with. Only the Hook Helper makes them; the
/// app reads the record the relay writes.
enum RustStatusLineBridge {
    /// Runs the status line relay on one input: keeps its usage, and returns
    /// the person's own status line command, or `nil` when they have none.
    /// Keeping the usage never fails the call; finding their command does
    /// not depend on it.
    static func command(provider: String, input: Data, environment: [String: String]) throws -> String? {
        // The provider writes JSON, which is UTF-8. Input that is not still
        // has a status line to run: it is looked up as for a session with no
        // project (an empty document), and only the usage goes unread.
        let text = String(bytes: input, encoding: .utf8) ?? "{}"
        let request: [String: Any] = ["provider": provider, "input": text, "environment": environment]
        let answer = try call(JSONSerialization.data(withJSONObject: request), weir_status_line_run_v1)
        return answer["command"] as? String
    }

    /// The status line setting the provider is launched with: the person's
    /// own as it stands for `workingDirectory`, with `relayCommand` in its
    /// place. `nil` when they have none, and the slot stays empty.
    static func setting(
        provider: String,
        environment: [String: String],
        workingDirectory: String,
        relayCommand: String
    ) throws -> [String: Any]? {
        let request: [String: Any] = [
            "provider": provider,
            "environment": environment,
            "workingDirectory": workingDirectory,
            "relayCommand": relayCommand
        ]
        let answer = try call(JSONSerialization.data(withJSONObject: request), weir_status_line_setting_v1)
        switch answer["statusLine"] {
        case let setting as [String: Any]: return setting
        case is NSNull: return nil
        default: throw AgentIntegrationError.invalidResponse
        }
    }

    private typealias Function = (
        UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int>?
    ) -> Int32

    private static func call(_ request: Data, _ function: Function) throws -> [String: Any] {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = request.withUnsafeBytes { buffer in
            function(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &out, &outCount)
        }
        guard let out else { throw AgentIntegrationError.rustFailure(status) }
        // The bytes are ours whatever the status turned out to be.
        defer { weir_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(WEIR_USAGE_OK.rawValue) else {
            throw AgentIntegrationError.rustFailure(status)
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(bytes: out, count: outCount)) as? [String: Any]
        else { throw AgentIntegrationError.invalidResponse }
        return object
    }
}
