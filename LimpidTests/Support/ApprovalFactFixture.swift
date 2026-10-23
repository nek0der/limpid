// ApprovalFactFixture.swift
// Limpid — an approval or question item's request facts, for tests that need one.

import Foundation
@testable import Limpid

extension ApprovalFact {
    /// A request, with a fresh key unless one is given: Claude's held
    /// approval unless said otherwise. `supportsNativeAnswer` defaults to what
    /// Limpid can answer, so a Codex question is never answerable here.
    /// `deadline` is the service's, `nil` for a request with none.
    static func test(
        key: ApprovalKey = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID()),
        isQuestion: Bool = false,
        provider: AgentKind = .claude,
        supportsNativeAnswer: Bool? = nil,
        state: ApprovalRequestState = .held,
        deadline: ServiceDeadline? = nil
    ) -> ApprovalFact {
        ApprovalFact(
            key: key,
            provider: provider,
            isQuestion: isQuestion,
            supportsNativeAnswer: supportsNativeAnswer ?? !(provider == .codex && isQuestion),
            state: state,
            deadline: deadline
        )
    }
}
