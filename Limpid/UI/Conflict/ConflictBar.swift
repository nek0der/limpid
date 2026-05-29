// ConflictBar.swift
// Limpid — the "party bar" (spec §8 / §8.x): a one-line summary shown
// across the tabs + pane region (NOT the tree) when the worktree the
// user is currently in is a party to a conflict. Width carries meaning —
// it's about *this* worktree, so it stops at the tree's edge (the tree
// is the third-person overview; the bar is the first-person warning).
// Tapping it opens the conflict modal (wired in the modal step).

import SwiftUI

extension Notification.Name {
    /// Posted when the user asks to see a conflict's detail (from the
    /// party bar, or later the sidebar ⚠). `object` is the
    /// `ConflictID.raw` string. Observed by the modal host.
    static let limpidShowConflictRequested = Notification.Name("dev.limpid.showConflictRequested")
}

/// Which one-liner the bar shows. Kept separate from the localized text
/// so the *selection* logic is pure and locale-independent (testable).
enum ConflictBarFormat: Equatable {
    /// One opponent, one file — name the file.
    case oneFile(opponent: String, file: String)
    /// One opponent, more files than the threshold — collapse to a count.
    case manyFiles(opponent: String, count: Int)
    /// Several opponents — list them (with a trailing "+N" folded in).
    case manyOpponents(joined: String)
    /// One opponent, no file info (degenerate) — name just the opponent.
    case oneOpponentNoFile(opponent: String)
}

struct ConflictBarSummary: Equatable {
    /// The conflict a tap opens. When several conflicts involve the
    /// active worktree, this is the first; the modal offers the rest.
    let primaryConflictID: ConflictID
    let format: ConflictBarFormat
}

extension ConflictBarSummary {
    /// Build the bar summary for the active container, or nil when there
    /// is nothing to show (not in a worktree, or no visible conflict).
    @MainActor
    static func make(activeContainer: ContainerID, detector: ConflictDetector) -> ConflictBarSummary? {
        guard let activeID = activeWorktreeID(for: activeContainer) else { return nil }
        let involving = detector.conflicts(involving: activeID)
        guard let primary = involving.first else { return nil }

        // Opponents = every other party across all conflicts the active
        // worktree is in, de-duplicated, first-seen order.
        var opponents: [String] = []
        var seen: Set<WorktreeID> = []
        for conflict in involving {
            for party in conflict.parties where party.workTreeID != activeID {
                if seen.insert(party.workTreeID).inserted {
                    opponents.append(party.branch.isEmpty ? "…" : party.branch)
                }
            }
        }
        guard let format = format(
            opponents: opponents,
            fileCount: primary.fileCount,
            threshold: detector.barFileCountThreshold,
            firstFile: primary.paths.first?.path
        ) else { return nil }
        return ConflictBarSummary(primaryConflictID: primary.id, format: format)
    }

    /// `WorktreeID` of the worktree the active container represents.
    /// `.loose` / `.group` have no worktree → no bar.
    static func activeWorktreeID(for container: ContainerID) -> WorktreeID? {
        switch container {
        case let .project(pid): ConflictWorktreeBridge.id(forProject: pid)
        case let .worktree(_, wid): ConflictWorktreeBridge.id(forWorktree: wid)
        case .loose, .group: nil
        }
    }

    /// Pure format selection (spec §8.x). Returns nil when there are no
    /// opponents.
    static func format(
        opponents: [String],
        fileCount: Int,
        threshold: Int,
        firstFile: String?
    ) -> ConflictBarFormat? {
        guard !opponents.isEmpty else { return nil }
        if opponents.count > 1 {
            let shown = opponents.prefix(2)
            let extra = opponents.count - shown.count
            var joined = shown.joined(separator: ", ")
            if extra > 0 { joined += ", +\(extra)" }
            return .manyOpponents(joined: joined)
        }
        let opponent = opponents[0]
        if fileCount > threshold {
            return .manyFiles(opponent: opponent, count: fileCount)
        }
        if let firstFile, !firstFile.isEmpty {
            return .oneFile(opponent: opponent, file: (firstFile as NSString).lastPathComponent)
        }
        return .oneOpponentNoFile(opponent: opponent)
    }
}

struct ConflictBar: View {
    /// Band height; ThreePaneLayout reserves the same inset in the
    /// columns so content sits below rather than under the bar.
    static let height: CGFloat = 30

    let summary: ConflictBarSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LimpidColor.warning)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LimpidColor.warning.opacity(0.14)
                .background(.regularMaterial)
        }
        .overlay(alignment: .bottom) {
            LimpidColor.chromeHairline.frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NotificationCenter.default.post(
                name: .limpidShowConflictRequested,
                object: summary.primaryConflictID.raw
            )
        }
        .help(text)
    }

    private var text: String {
        switch summary.format {
        case let .oneFile(opponent, file):
            String(localized: "Conflicting with \(opponent) in \(file)")
        case let .manyFiles(opponent, count):
            String(localized: "Conflicting with \(opponent) in \(count) files")
        case let .manyOpponents(joined):
            String(localized: "Conflicting with \(joined)")
        case let .oneOpponentNoFile(opponent):
            String(localized: "Conflicting with \(opponent)")
        }
    }
}
