// LimpidRustBridge.swift
// Limpid — Typed Swift access to the Rust core ABI boundary.

import LimpidRustBridge

enum LimpidRustRuntime {
    static var abiVersion: UInt32 {
        limpid_rust_abi_version()
    }
}

enum LimpidRustTitleResolver {
    /// Must match the portable protocol limit enforced by Rust.
    private static let outputCapacity = 4096

    static func resolve(
        providerSessionTitle: String?,
        providerGeneratedTitle: String?,
        firstPrompt: String?
    ) -> String? {
        var output = [UInt8](repeating: 0, count: outputCapacity)
        var outputLength = 0

        let result = withOptionalUTF8(providerSessionTitle) { providerSessionPointer, providerSessionLength in
            withOptionalUTF8(providerGeneratedTitle) { providerGeneratedPointer, providerGeneratedLength in
                withOptionalUTF8(firstPrompt) { firstPromptPointer, firstPromptLength in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        limpid_resolve_title_v1(
                            providerSessionPointer,
                            providerSessionLength,
                            providerGeneratedPointer,
                            providerGeneratedLength,
                            firstPromptPointer,
                            firstPromptLength,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard result == LIMPID_TITLE_RESOLVE_OK.rawValue,
              outputLength <= output.count
        else { return nil }
        return String(bytes: output[..<outputLength], encoding: .utf8)
    }

    private static func withOptionalUTF8<Result>(
        _ value: String?,
        _ body: (UnsafePointer<UInt8>?, Int) -> Result
    ) -> Result {
        guard let value else { return body(nil, 0) }
        return Array(value.utf8).withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}
