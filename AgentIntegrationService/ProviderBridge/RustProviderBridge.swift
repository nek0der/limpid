// RustProviderBridge.swift
// Weir — ownership-safe Swift wrapper around the provider translation C ABI.
//
// Lives outside `Shared/` because the probe executables compile `Shared/`
// without linking the Rust bridge; only the Hook Helper and the app do.

import Dispatch
import Foundation
import WeirRustBridge

enum RustProviderBridge {
    /// Translates a provider hook payload into the neutral approval request,
    /// returned as the JSON document the Rust model serializes. `nil` means
    /// the payload is valid but is not a permission request.
    static func approvalRequest(provider: String, payload: Data) throws -> Data? {
        try call(provider: provider, input: payload, notApproval: true) { pointers in
            weir_provider_approval_request_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                pointers.out, pointers.outCount
            )
        }
    }

    /// Renders a decision with the request it answers. Only an answer needs
    /// the request; it echoes the provider's tool input back with the answers.
    static func approvalOutput(provider: String, requestJSON: Data, decisionJSON: Data) throws -> Data? {
        try requestJSON.withUnsafeBytes { requestBuffer -> Data? in
            let requestPointer = requestBuffer.bindMemory(to: UInt8.self).baseAddress
            return try call(provider: provider, input: decisionJSON, notApproval: false) { pointers in
                weir_provider_approval_output_v2(
                    pointers.provider, pointers.providerCount,
                    requestPointer, requestBuffer.count,
                    pointers.input, pointers.inputCount,
                    pointers.out, pointers.outCount
                )
            }
        }
    }

    /// Returns the names `provider`'s process has, as its descriptor in the
    /// Rust registry lists them, so a process search follows the descriptor
    /// rather than a copy of it. The set is empty for a provider this build
    /// does not have.
    static func processNames(provider: String) throws -> Set<String> {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = weir_projection_providers_v1(&out, &outCount)
        guard let out else { throw AgentIntegrationError.rustFailure(status) }
        // The bytes belong to us until the matching free, whatever the status
        // turned out to be.
        defer { weir_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(WEIR_PROJECTION_OK.rawValue) else {
            throw AgentIntegrationError.rustFailure(status)
        }
        let body = Data(bytes: out, count: outCount)
        guard let registry = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw AgentIntegrationError.invalidResponse }
        guard let descriptor = registry[provider] else { return [] }
        guard let names = (descriptor as? [String: Any])?["processNames"] as? [String]
        else { throw AgentIntegrationError.invalidResponse }
        return Set(names)
    }

    /// A turn that failed, as the provider's crate reads it from a line of its
    /// transcript.
    struct TurnFailureReport {
        /// The hook payload to report.
        var payload: [String: Any]
        /// When the line says it was written; `nil` when it does not say.
        let writtenAt: Date?
        /// The message that names when a usage limit resets, for the host to
        /// read in the time zone the provider ran in.
        let usageLimitMessage: String?
        /// The payload key for that reset.
        let messageResetKey: String
    }

    /// The report for `line` when it is a turn that failed, else `nil`. A line
    /// with no time of its own was written no later than `readAt`.
    static func turnFailureReport(
        provider: String,
        line: Data,
        transcriptPath: String,
        sessionID: String,
        readAt: Date
    ) throws -> TurnFailureReport? {
        let path = Array(transcriptPath.utf8)
        let session = Array(sessionID.utf8)
        let body = try call(provider: provider, input: line, notApproval: false) { pointers in
            weir_provider_turn_failure_report_v1(
                pointers.provider, pointers.providerCount,
                pointers.input, pointers.inputCount,
                path, path.count,
                session, session.count,
                UInt64(max(0, readAt.timeIntervalSince1970)),
                pointers.out, pointers.outCount
            )
        }
        guard let body else { throw AgentIntegrationError.invalidResponse }
        let object = try JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        if object is NSNull {
            return nil
        }
        guard let report = object as? [String: Any],
              let payload = report["payload"] as? [String: Any],
              let messageResetKey = report["message_reset_key"] as? String
        else { throw AgentIntegrationError.invalidResponse }
        return TurnFailureReport(
            payload: payload,
            writtenAt: (report["written_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            usageLimitMessage: report["usage_limit_message"] as? String,
            messageResetKey: messageResetKey
        )
    }

    /// Which hook entry point `runHook` invokes.
    enum HookKind {
        case lifecycle
        case worktree

        /// The `WEIR_HOOK_KIND_*` constant the C ABI expects.
        var abiValue: UInt32 {
            switch self {
            case .lifecycle: UInt32(WEIR_HOOK_KIND_LIFECYCLE)
            case .worktree: UInt32(WEIR_HOOK_KIND_WORKTREE)
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
    /// point it at a scratch directory. `observationClock` supplies this
    /// boot's monotonic nanoseconds and can be fixed by a test. Never opens
    /// the approval service.
    static func runHook(
        provider: String,
        kind: HookKind,
        payload: Data,
        environment: [String: String],
        observationClock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws -> HookOutcome {
        var environment = environment
        environment["WEIR_HOOK_OBSERVED_ORDER"] = String(observationClock())
        let environmentJSON = try JSONSerialization.data(withJSONObject: environment)
        let body = try environmentJSON.withUnsafeBytes { environmentBuffer in
            try call(provider: provider, input: payload, notApproval: false) { pointers in
                weir_hook_run_v1(
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
    /// `notApproval` says whether `WEIR_PROVIDER_NOT_APPROVAL` is a valid
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
            defer { weir_approval_bytes_free_v1(out, outCount) }
            guard status == Int32(WEIR_PROVIDER_OK.rawValue) else {
                throw AgentIntegrationError.rustFailure(status)
            }
            return Data(bytes: out, count: outCount)
        }
        switch status {
        case Int32(WEIR_PROVIDER_OK.rawValue):
            // Success with an empty body: delegate.
            return nil
        case Int32(WEIR_PROVIDER_NOT_APPROVAL.rawValue) where notApproval:
            return nil
        default:
            throw AgentIntegrationError.rustFailure(status)
        }
    }
}
