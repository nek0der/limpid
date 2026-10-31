// PRState.swift
// Weir — the states of a pull request the app tells apart.

import Foundation

/// Subset of forge states we render distinctly. Draft-vs-open is a
/// boolean flag on the parent (`PRInfo.isDraft`) rather than its own case
/// because both forges model it that way.
///
/// GitLab's `locked` maps to `.open`: it means the discussion is
/// locked, not that the request is finished.
package enum PRState {
    case open
    case closed
    case merged
}
