// WorktreeFixture+Failure.swift
// Weir — the error a worktree pipeline threw, for the suites that check how it failed.

import Foundation

extension WorktreeFixture {
    /// The error `body` threw, as `E`; nil when it returned, or threw
    /// something else. A test then matches the case it expects rather than
    /// spelling out a do/catch each time.
    @MainActor
    static func failure<E: Error>(_: E.Type, of body: () async throws -> some Any) async -> E? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? E
        }
    }
}
