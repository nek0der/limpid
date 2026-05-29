// ConflictModal.swift
// Limpid — the conflict detail sheet (spec §8 / §8.x). Both entry points
// (sidebar ⚠ and the party bar) land here. Designed to stay readable
// even with many files / parties:
//   - header names the parties + file count
//   - 2 parties → symmetric cards, 3+ → a vertical list
//   - confirmed (L2) files on top, potential (L1) below and dimmed,
//     folded past a small cap
//   - pre-alpha actions: compare files (side-by-side) and ignore
// When several conflicts are visible, a header link switches between
// them so one sheet covers the lot.

import SwiftUI

/// Identifiable wrapper so a file path can drive `.sheet(item:)`.
private struct ComparePath: Identifiable {
    let path: String
    var id: String {
        path
    }
}

struct ConflictModal: View {
    let entryConflictID: ConflictID

    @Environment(ConflictDetector.self) private var detector
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: ConflictID
    @State private var comparePath: ComparePath?
    @State private var showAllPotential = false

    /// Potential files shown before the "show more" fold.
    private static let potentialFoldLimit = 5

    init(conflictID: ConflictID) {
        entryConflictID = conflictID
        _currentID = State(initialValue: conflictID)
    }

    /// Look up by id against ALL conflicts (not just visible) so the
    /// sheet keeps rendering an ignored conflict the user is toggling.
    private var conflict: Conflict? {
        detector.conflicts.first { $0.id == currentID }
    }

    private var otherConflicts: [Conflict] {
        detector.visibleConflicts.filter { $0.id != currentID }
    }

    var body: some View {
        Group {
            if let conflict {
                content(for: conflict)
            } else {
                resolvedState
            }
        }
        .frame(width: 460)
        .frame(minHeight: 300)
        .sheet(item: $comparePath) { item in
            ConflictDiffView(path: item.path, parties: conflict?.parties ?? [])
        }
    }

    // MARK: - Populated state

    private func content(for conflict: Conflict) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if !otherConflicts.isEmpty {
                    Button {
                        if let next = otherConflicts.first { currentID = next.id }
                    } label: {
                        Label(
                            String(localized: "\(otherConflicts.count) more conflicts"),
                            systemImage: "rectangle.on.rectangle"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // Close affordance — the sheet had no dismiss otherwise
                // (ignore only toggles). Escape also dismisses via
                // `.cancelAction`.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            header(for: conflict)
            parties(for: conflict)
            fileList(for: conflict)
            Spacer(minLength: 0)
            actions(for: conflict)
        }
        .padding(20)
    }

    private func header(for conflict: Conflict) -> some View {
        let branches = conflict.parties
            .map { $0.branch.isEmpty ? String(localized: "(detached)") : $0.branch }
            .joined(separator: " ⟷ ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LimpidColor.warning)
                Text(branches)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(2)
            }
            Text(fileCountText(for: conflict))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func fileCountText(for conflict: Conflict) -> String {
        if conflict.confirmedCount > 0 {
            return String(localized: "\(conflict.fileCount) files · \(conflict.confirmedCount) real conflicts")
        }
        return String(localized: "\(conflict.fileCount) files")
    }

    // MARK: - Parties

    @ViewBuilder
    private func parties(for conflict: Conflict) -> some View {
        if conflict.parties.count == 2 {
            HStack(spacing: 10) {
                partyCard(conflict.parties[0])
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                partyCard(conflict.parties[1])
            }
        } else {
            VStack(spacing: 6) {
                ForEach(conflict.parties, id: \.workTreeID) { party in
                    partyRow(party)
                }
            }
        }
    }

    private func partyCard(_ party: ConflictParty) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(party.branch.isEmpty ? String(localized: "(detached)") : party.branch)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
            lastEdited(party)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(LimpidColor.rowHoverFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func partyRow(_ party: ConflictParty) -> some View {
        HStack {
            Text(party.branch.isEmpty ? String(localized: "(detached)") : party.branch)
                .font(.system(size: 13, weight: .medium, design: .rounded))
            Spacer()
            lastEdited(party)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LimpidColor.rowHoverFill, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Clock icon + relative time = when this worktree last touched one
    /// of the conflicting files (freshness — which side is active now).
    private func lastEdited(_ party: ConflictParty) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 9))
            Text(party.lastTouched, style: .relative)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .help("Last edited a conflicting file")
    }

    // MARK: - File list

    private func fileList(for conflict: Conflict) -> some View {
        // Confirmed (real) first, then potential — each freshest-first.
        let confirmed = conflict.paths
            .filter { $0.level == .confirmed }
            .sorted { $0.lastTouched > $1.lastTouched }
        let potential = conflict.paths
            .filter { $0.level == .potential }
            .sorted { $0.lastTouched > $1.lastTouched }
        let shownPotential = showAllPotential ? potential : Array(potential.prefix(Self.potentialFoldLimit))
        let hiddenCount = potential.count - shownPotential.count

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(confirmed) { fileRow($0) }
            ForEach(shownPotential) { fileRow($0) }
            if hiddenCount > 0 {
                Button {
                    showAllPotential = true
                } label: {
                    Label(String(localized: "Show \(hiddenCount) more"), systemImage: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private func fileRow(_ file: ConflictPath) -> some View {
        Button {
            comparePath = ComparePath(path: file.path)
        } label: {
            HStack(spacing: 8) {
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Potential (L1-only) files read as the softer signal.
                    .opacity(file.level == .confirmed ? 1 : 0.6)
                Spacer(minLength: 6)
                if file.level == .confirmed {
                    Text("conflict")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LimpidColor.error)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    // MARK: - Actions

    private func actions(for conflict: Conflict) -> some View {
        HStack(spacing: 10) {
            if conflict.status == .ignored {
                Button(String(localized: "Stop ignoring")) {
                    detector.unignore(conflict.id)
                }
            } else {
                Button(String(localized: "Ignore conflict")) {
                    detector.ignore(conflict.id)
                }
            }
            Spacer()
            if let first = conflict.paths.first {
                Button(String(localized: "Compare files")) {
                    comparePath = ComparePath(path: first.path)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Resolved fallback

    private var resolvedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(LimpidColor.success)
            Text("This conflict was resolved.")
                .font(.system(size: 13))
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
