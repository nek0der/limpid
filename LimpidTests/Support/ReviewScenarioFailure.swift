// ReviewScenarioFailure.swift
// Limpid — the one error the review scenarios throw.

import Foundation

/// Shared by the scenarios that run in the test target and by the one that
/// runs from `scripts/validate-review-core.sh`, which compiles the two sets
/// separately.
struct ReviewValidationFailure: Error {
    let message: String
}
