// RustProviderBridge.swift
// Limpid — ownership-safe Swift wrapper around the provider translation C ABI.
//
// Lives outside `Shared/` because the probe executables compile `Shared/`
// without linking the Rust bridge; only the Hook Helper and the app do.

import Foundation
import LimpidRustBridge

enum RustProviderBridge {
    /// Translates a provider hook payload into the neutral approval request,
    /// returned as the JSON document the Rust model serializes. `nil` means
    /// the payload is valid but is not a permission request.
    static func approvalRequest(provider: String, payload: Data) throws -> Data? {
        try call(provider: provider, input: payload, notApproval: true) { pointers in
            limpid_provider_approval_request_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                pointers.out, pointers.outCount
            )
        }
    }

    /// Renders a neutral decision document (`{"decision":"allow_once"}`, …)
    /// as the bytes the provider's hook must print. `nil` means delegate:
    /// print nothing and let the provider's native flow decide.
    static func approvalOutput(provider: String, decisionJSON: Data) throws -> Data? {
        try call(provider: provider, input: decisionJSON, notApproval: false) { pointers in
            limpid_provider_approval_output_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                pointers.out, pointers.outCount
            )
        }
    }

    /// Which hook entry point `runHook` invokes.
    enum HookKind {
        case lifecycle
        case worktree

        /// The `LIMPID_HOOK_KIND_*` constant the C ABI expects.
        var abiValue: UInt32 {
            switch self {
            case .lifecycle: UInt32(LIMPID_HOOK_KIND_LIFECYCLE)
            case .worktree: UInt32(LIMPID_HOOK_KIND_WORKTREE)
            }
        }
    }

    /// The outcome the hook runtime reports for one call.
    struct HookOutcome: Equatable {
        let outcome: String
        let exitCode: Int32
        let message: String?
    }

    /// Runs one lifecycle or worktree hook call in-process. `environment` is
    /// what the hook runtime reads the shim's variables from, so a test can
    /// point it at a scratch directory. Never opens the approval service.
    static func runHook(
        provider: String,
        kind: HookKind,
        payload: Data,
        environment: [String: String]
    ) throws -> HookOutcome {
        let environmentJSON = try JSONSerialization.data(withJSONObject: environment)
        let body = try environmentJSON.withUnsafeBytes { environmentBuffer in
            try call(provider: provider, input: payload, notApproval: false) { pointers in
                limpid_hook_run_v1(
                    pointers.provider, pointers.providerCount,
                    kind.abiValue,
                    pointers.input, pointers.inputCount,
                    environmentBuffer.bindMemory(to: UInt8.self).baseAddress, environmentBuffer.count,
                    pointers.out, pointers.outCount
                )
            }
        }
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let outcome = object["outcome"] as? String,
              let exitCode = object["exit_code"] as? Int
        else { throw AgentIntegrationError.invalidResponse }
        return HookOutcome(outcome: outcome, exitCode: Int32(exitCode), message: object["message"] as? String)
    }

    /// The input pointer-length pairs one ABI call receives, plus the output
    /// slots it fills.
    private struct Pointers {
        let provider: UnsafePointer<UInt8>?
        let providerCount: Int
        let input: UnsafePointer<UInt8>?
        let inputCount: Int
        let out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
        let outCount: UnsafeMutablePointer<Int>
    }

    /// Runs one translation call and takes ownership of its output buffer.
    /// `notApproval` says whether `LIMPID_PROVIDER_NOT_APPROVAL` is a valid
    /// outcome for this call (it is only for request translation).
    private static func call(
        provider: String,
        input: Data,
        notApproval: Bool,
        _ body: (Pointers) -> Int32
    ) throws -> Data? {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let providerBytes = Array(provider.utf8)
        // Every pointer is scoped to the call: the buffers stay alive for the
        // duration of `body`, and the output slots are read only afterwards.
        let status = withUnsafeMutablePointer(to: &out) { outPointer in
            withUnsafeMutablePointer(to: &outCount) { outCountPointer in
                providerBytes.withUnsafeBufferPointer { providerBuffer in
                    input.withUnsafeBytes { inputBuffer in
                        body(Pointers(
                            provider: providerBuffer.baseAddress,
                            providerCount: providerBuffer.count,
                            input: inputBuffer.bindMemory(to: UInt8.self).baseAddress,
                            inputCount: inputBuffer.count,
                            out: outPointer,
                            outCount: outCountPointer
                        ))
                    }
                }
            }
        }
        if let out {
            // The bytes belong to us until the matching free, whatever the
            // status turned out to be.
            defer { limpid_approval_bytes_free_v1(out, outCount) }
            guard status == Int32(LIMPID_PROVIDER_OK.rawValue) else {
                throw AgentIntegrationError.rustFailure(status)
            }
            return Data(bytes: out, count: outCount)
        }
        switch status {
        case Int32(LIMPID_PROVIDER_OK.rawValue):
            // Success with an empty body: delegate.
            return nil
        case Int32(LIMPID_PROVIDER_NOT_APPROVAL.rawValue) where notApproval:
            return nil
        default:
            throw AgentIntegrationError.rustFailure(status)
        }
    }
}
