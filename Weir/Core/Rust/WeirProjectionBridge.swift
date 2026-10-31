// WeirProjectionBridge.swift
// Weir — Swift entry point for the application-side rules in Rust.

import Foundation
import WeirRustBridge

/// A projection call that could not be completed. The status is the C ABI's
/// own code, which is more use in a log than a re-worded message: every value
/// it can take is documented beside the function that returned it.
enum WeirProjectionError: Error {
    case rust(Int32)
}

/// What the adapter needs of the rules' memory between passes. A protocol
/// so a test can stand in for the engine and make a pass fail.
protocol ProjectionPassing: Sendable {
    func pass(input: Data, now: Data) throws -> WeirProjectionPass
    func commit(_ proposal: UInt64) throws
    /// How many turns a change of the retention limits deletes, from what
    /// was committed (`weir_projection_engine_turns_taken_v1`).
    func turnsTaken(change: Data, now: Data) throws -> Int
}

/// What one projection pass returned.
struct WeirProjectionPass {
    /// `{ "projection": ..., "commands": [...] }`.
    let body: Data
    /// What `WeirProjectionBridge.Engine.commit(_:)` names to keep this
    /// pass's state.
    let proposal: UInt64
}

/// Calls the projection, launch, and terminate rules.
///
/// Each call hands Rust the JSON it needs and takes ownership of the JSON it
/// returns. What the rules remember between passes stays on the Rust side,
/// in an `Engine`: its shape is a private matter for the rules, and handing
/// it across on every pass cost more than the pass itself once a person had
/// kept thousands of turns.
enum WeirProjectionBridge {
    /// The rules' memory between passes, for one adapter.
    ///
    /// A pass proposes what to remember and `commit(_:)` keeps it, which
    /// the caller does once it has read the answer: a pass whose answer
    /// could not be used leaves the memory as it was. A new engine
    /// remembers nothing, as the first pass after launch finds it.
    ///
    /// `@unchecked Sendable` because the handle is the only state and never
    /// changes after `init`, and every call on it goes through a mutex on
    /// the Rust side. A commit names the pass whose answer it read, and is
    /// refused when another pass's commit replaced the state that pass was
    /// made from. That does not cover a pass whose input was read before
    /// another commit but reached the rules after it: the adapter drops
    /// such an answer itself. It passes the engine off the main actor for
    /// the pass and commits on the main actor.
    final class Engine: ProjectionPassing, @unchecked Sendable {
        /// Owned by this object from `init` to `deinit`; Rust releases it.
        /// Imported as implicitly unwrapped, and never null: the Rust side
        /// returns a fresh allocation, and an allocation that fails aborts
        /// there rather than returning.
        private let handle: OpaquePointer

        init() {
            handle = weir_projection_engine_create_v1()
        }

        deinit {
            weir_projection_engine_free_v1(handle)
        }

        /// Reduces the records the watcher found into what to show and what
        /// to do, and proposes what to remember.
        func pass(input: Data, now: Data) throws -> WeirProjectionPass {
            var proposal: UInt64 = 0
            let body = try WeirProjectionBridge.call { pointers in
                WeirProjectionBridge.withBytes(now) { nowBuffer in
                    weir_projection_engine_pass_v1(
                        handle,
                        pointers.input,
                        pointers.inputCount,
                        nowBuffer.baseAddress,
                        nowBuffer.count,
                        pointers.out,
                        pointers.outCount,
                        &proposal
                    )
                }
            } input: { input }
            return WeirProjectionPass(body: body, proposal: proposal)
        }

        /// Remembers what `proposal`'s pass proposed. Throws when another
        /// commit replaced the state it was made from (or it was this one),
        /// or later passes pushed it out, and remembers nothing.
        func commit(_ proposal: UInt64) throws {
            let status = weir_projection_engine_commit_v1(handle, proposal)
            guard status == Int32(WEIR_PROJECTION_OK.rawValue) else {
                throw WeirProjectionError.rust(status)
            }
        }

        /// How many turns the sweep takes under `change`'s `to` limits that
        /// it keeps under its `from` limits, as a pass made now would choose
        /// them, deleting none. The sweep's own rule, so the count Advanced
        /// asks with is what a pass deletes.
        func turnsTaken(change: Data, now: Data) throws -> Int {
            var count: UInt64 = 0
            let status = WeirProjectionBridge.withBytes(change) { changeBuffer in
                WeirProjectionBridge.withBytes(now) { nowBuffer in
                    weir_projection_engine_turns_taken_v1(
                        handle,
                        changeBuffer.baseAddress,
                        changeBuffer.count,
                        nowBuffer.baseAddress,
                        nowBuffer.count,
                        &count
                    )
                }
            }
            guard status == Int32(WEIR_PROJECTION_OK.rawValue) else {
                throw WeirProjectionError.rust(status)
            }
            return Int(clamping: count)
        }
    }

    /// The providers this build has, as `{ "<id>": <descriptor>, ... }`.
    static func providers() throws -> Data {
        try call { pointers in
            weir_projection_providers_v1(pointers.out, pointers.outCount)
        } input: { Data() }
    }

    /// What each provider needs installed, as `{ "<id>": <recipe>, ... }`.
    static func installRecipes() throws -> Data {
        try call { pointers in
            weir_projection_install_recipes_v1(pointers.out, pointers.outCount)
        } input: { Data() }
    }

    /// How the files in each provider's directories are named, as
    /// `{ "runRecordSuffix", "sessionHintSuffix", "cwdEventSuffix",
    /// "worktreeEventsDirectory", "worktreeEventSuffix", "lockSuffix" }`.
    static func recordLayout() throws -> Data {
        try call { pointers in
            weir_projection_record_layout_v1(pointers.out, pointers.outCount)
        } input: { Data() }
    }

    /// The check commands a project gets until it sets its own, as a JSON
    /// array; the hook classifies commands with the same list.
    static func checkDefaults() throws -> Data {
        try call { pointers in
            weir_projection_check_defaults_v1(pointers.out, pointers.outCount)
        } input: { Data() }
    }

    /// Decides what to restore or retire before the interface is built.
    static func onLaunch(input: Data, now: String) throws -> Data {
        try lifecycle(input: input, now: now, weir_projection_on_launch_v1)
    }

    /// Records what Weir is about to kill and what would bring it back.
    static func onTerminate(input: Data, now: String) throws -> Data {
        try lifecycle(input: input, now: now, weir_projection_on_terminate_v1)
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
            defer { weir_approval_bytes_free_v1(out, outCount) }
            guard status == Int32(WEIR_PROJECTION_OK.rawValue) else {
                throw WeirProjectionError.rust(status)
            }
            return Data(bytes: out, count: outCount)
        }
        throw WeirProjectionError.rust(status)
    }

    /// Scopes a byte buffer to one call. An empty value yields a null
    /// pointer, which the call reports rather than reads.
    private static func withBytes<T>(
        _ data: Data,
        _ body: (UnsafeBufferPointer<UInt8>) -> T
    ) -> T {
        guard !data.isEmpty else {
            return body(UnsafeBufferPointer<UInt8>(start: nil, count: 0))
        }
        return data.withUnsafeBytes { buffer in
            body(buffer.bindMemory(to: UInt8.self))
        }
    }
}
