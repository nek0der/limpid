// RustApprovalHost.swift
// Limpid — ownership-safe Swift wrapper around the opaque approval C ABI.

import Foundation
import LimpidRustBridge

final class RustApprovalService {
    fileprivate let handle: OpaquePointer

    init(maximumRecords: Int) throws {
        guard let handle = limpid_approval_service_create_v1(maximumRecords) else {
            throw AgentIntegrationError.rustFailure(Int32(LIMPID_APPROVAL_INTERNAL.rawValue))
        }
        self.handle = handle
    }

    deinit {
        limpid_approval_service_free_v1(handle)
    }

    func requesterSession(runID: UUID) throws -> RustApprovalSession {
        var bytes = runID.uuid
        let handle = withUnsafeBytes(of: &bytes) { buffer in
            limpid_approval_session_create_requester_v1(
                self.handle,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        guard let handle else {
            throw AgentIntegrationError.rustFailure(Int32(LIMPID_APPROVAL_INVALID_UUID.rawValue))
        }
        return RustApprovalSession(service: self, handle: handle)
    }

    func controllerSession() throws -> RustApprovalSession {
        guard let handle = limpid_approval_session_create_controller_v1(handle) else {
            throw AgentIntegrationError.rustFailure(Int32(LIMPID_APPROVAL_INTERNAL.rawValue))
        }
        return RustApprovalSession(service: self, handle: handle)
    }
}

final class RustApprovalSession {
    // The Rust session retains the shared Arc, but keeping the Swift owner alive
    // also guarantees that no foreign handle is freed out of ABI order.
    private let service: RustApprovalService
    private let handle: OpaquePointer

    fileprivate init(service: RustApprovalService, handle: OpaquePointer) {
        self.service = service
        self.handle = handle
    }

    deinit {
        limpid_approval_session_free_v1(handle)
    }

    func exchange(_ request: Data) throws -> Data {
        var output = limpid_approval_bytes_v1(data: nil, len: 0)
        let status = request.withUnsafeBytes { buffer in
            limpid_approval_session_exchange_v1(
                handle,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count,
                &output
            )
        }
        guard status == LIMPID_APPROVAL_OK.rawValue else {
            throw AgentIntegrationError.rustFailure(status)
        }
        guard output.len <= AgentIntegrationConfiguration.maximumXPCResponseBytes,
              output.len == 0 || output.data != nil
        else {
            if let data = output.data {
                limpid_approval_bytes_free_v1(data, output.len)
            }
            throw AgentIntegrationError.invalidResponse
        }
        guard let data = output.data else { return Data() }
        defer { limpid_approval_bytes_free_v1(data, output.len) }
        return Data(bytes: data, count: output.len)
    }
}
