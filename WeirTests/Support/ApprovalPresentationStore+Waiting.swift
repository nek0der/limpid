// ApprovalPresentationStore+Waiting.swift
// Weir — waits for an approval decision the store sends off the main actor.

@testable import Weir

extension ApprovalPresentationStore {
    /// The sender runs off the main actor and the store clears its resolving
    /// state only after hopping back, so a single yield does not guarantee
    /// the decision task has finished.
    func waitUntilResolved(_ request: ApprovalPresentation) async {
        await pollUntil { !resolvingIDs.contains(request.id) }
    }
}
