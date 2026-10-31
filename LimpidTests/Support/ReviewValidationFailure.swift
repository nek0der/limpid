// ReviewValidationFailure.swift
// Limpid — the one error the review's terminal probe scenario throws.

import Foundation

/// `scripts/validate-review-core.sh` compiles the probe scenario on its own,
/// without Swift Testing, so its checks report through this error.
struct ReviewValidationFailure: Error {
    let message: String
}
