// PaneIOSource.swift
// Limpid — where a pane's bytes come from: its own pty, or a pane of a tmux window mirrored over control mode.

import Foundation

/// One pane of one tmux window, addressed through the server binding the
/// rest of Limpid already persists. Composed rather than copied so the
/// generation check (`serverPID` / `serverStartedAt`) lives in one type.
struct TmuxPaneRef: Codable, Equatable {
    var binding: TmuxBinding
    /// `@N`
    var windowID: String
    /// `%N`
    var paneID: String
}

/// What drives a pane's surface. Absent from `Tab.paneSources` means
/// `.local`, so an ordinary tab stores nothing.
///
/// Decoding is hand-written so an unknown kind lands on `.unavailable`
/// rather than on `.local`: a build that does not know a future source
/// must show an inert pane, not start a login shell in its place, which
/// is the accident the dormant-pane rule exists to prevent.
enum PaneIOSource: Equatable {
    case local
    case tmux(TmuxPaneRef)
    /// A source this build cannot read. The pane gets no surface and no
    /// process, only a card saying so.
    case unavailable

    var isMirror: Bool {
        if case .tmux = self {
            return true
        }
        return false
    }
}

extension PaneIOSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case tmux
    }

    private enum Kind: String, Codable {
        case local
        case tmux
        case unavailable
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: raw) {
        case .local:
            self = .local
        case .tmux:
            self = try .tmux(container.decode(TmuxPaneRef.self, forKey: .tmux))
        case .unavailable, nil:
            self = .unavailable
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case let .tmux(ref):
            try container.encode(Kind.tmux, forKey: .kind)
            try container.encode(ref, forKey: .tmux)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }
}
