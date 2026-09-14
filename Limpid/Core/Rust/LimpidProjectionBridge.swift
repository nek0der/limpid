// LimpidProjectionBridge.swift
// Limpid — Swift entry point for the application-side rules in Rust.

import Foundation
import LimpidRustBridge

/// A projection call that could not be completed. The status is the C ABI's
/// own code, which is more use in a log than a re-worded message: every value
/// it can take is documented beside the function that returned it.
enum LimpidProjectionError: Error {
    case rust(Int32)
}

/// Calls the projection, launch, and terminate rules.
///
/// Each call hands Rust the JSON it needs and takes ownership of the JSON it
/// returns. The projection state travels as opaque bytes: we store what one
/// call produced and hand it to the next without looking inside, so its shape
/// stays a private matter for the rules.
enum LimpidProjectionBridge {
    /// Reduces the records the watcher found into what to show and what to do.
    /// Pass the previous call's state, or nil on the first call after launch.
    static func project(state: Data?, input: Data, now: Data) throws -> Data {
        try call { pointers in
            withBytes(state) { stateBuffer in
                withBytes(now) { nowBuffer in
                    limpid_projection_project_v1(
                        stateBuffer.baseAddress,
                        stateBuffer.count,
                        pointers.input,
                        pointers.inputCount,
                        nowBuffer.baseAddress,
                        nowBuffer.count,
                        pointers.out,
                        pointers.outCount
                    )
                }
            }
        } input: { input }
    }

    /// The providers this build has, as `{ "<id>": <descriptor>, ... }`.
    static func providers() throws -> Data {
        try call { pointers in
            limpid_projection_providers_v1(pointers.out, pointers.outCount)
        } input: { Data() }
    }

    /// Decides what to restore or retire before the interface is built.
    static func onLaunch(input: Data, now: String) throws -> Data {
        try lifecycle(input: input, now: now, limpid_projection_on_launch_v1)
    }

    /// Records what Limpid is about to kill and what would bring it back.
    static func onTerminate(input: Data, now: String) throws -> Data {
        try lifecycle(input: input, now: now, limpid_projection_on_terminate_v1)
    }

    private typealias LifecycleCall = (
        UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>
    ) -> Int32

    private static func lifecycle(input: Data, now: String, _ body: @escaping LifecycleCall) throws -> Data {
        let nowBytes = Data(now.utf8)
        return try call { pointers in
            withBytes(nowBytes) { nowBuffer in
                body(
                    pointers.input,
                    pointers.inputCount,
                    nowBuffer.baseAddress,
                    nowBuffer.count,
                    pointers.out,
                    pointers.outCount
                )
            }
        } input: { input }
    }

    /// The input pointer pair one call receives plus the output slots it fills.
    private struct Pointers {
        let input: UnsafePointer<UInt8>?
        let inputCount: Int
        let out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
        let outCount: UnsafeMutablePointer<Int>
    }

    /// Runs one call and takes ownership of its output buffer. The free is in a
    /// `defer` before the status is inspected, because the bytes belong to us
    /// whatever the status turned out to be.
    private static func call(
        _ body: (Pointers) -> Int32,
        input: () -> Data
    ) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let input = input()
        let status = withUnsafeMutablePointer(to: &out) { outPointer in
            withUnsafeMutablePointer(to: &outCount) { outCountPointer in
                input.withUnsafeBytes { inputBuffer in
                    body(Pointers(
                        input: inputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        inputCount: inputBuffer.count,
                        out: outPointer,
                        outCount: outCountPointer
                    ))
                }
            }
        }
        if let out {
            defer { limpid_approval_bytes_free_v1(out, outCount) }
            guard status == Int32(LIMPID_PROJECTION_OK.rawValue) else {
                throw LimpidProjectionError.rust(status)
            }
            return Data(bytes: out, count: outCount)
        }
        throw LimpidProjectionError.rust(status)
    }

    /// Scopes a byte buffer to one call. An empty value yields a null pointer,
    /// which is how "no state yet" reaches the first call after launch.
    private static func withBytes<T>(
        _ data: Data?,
        _ body: (UnsafeBufferPointer<UInt8>) -> T
    ) -> T {
        guard let data, !data.isEmpty else {
            return body(UnsafeBufferPointer<UInt8>(start: nil, count: 0))
        }
        return data.withUnsafeBytes { buffer in
            body(buffer.bindMemory(to: UInt8.self))
        }
    }
}
