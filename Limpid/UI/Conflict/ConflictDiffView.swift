// ConflictDiffView.swift
// Limpid — the "compare files" view reached from the conflict modal. A
// deliberately simple side-by-side: each party's copy of the file shown
// raw in its own monospace column. No line-level diff alignment or
// highlighting (that's a later step) — this just answers "what does each
// side currently have?" by reading both files off disk (Limpid-only, no
// external tool).

import SwiftUI

struct ConflictDiffView: View {
    let path: String
    let parties: [ConflictParty]
    @Environment(\.dismiss) private var dismiss

    /// Cap so a huge file can't stall the sheet; we only need a preview.
    private static let maxPreviewBytes = 256 * 1024

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(parties.enumerated()), id: \.element.workTreeID) { index, party in
                    column(for: party)
                    if index < parties.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func column(for party: ConflictParty) -> some View {
        VStack(spacing: 0) {
            Text(party.branch.isEmpty ? String(localized: "(detached)") : party.branch)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LimpidColor.rowHoverFill)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(contents(of: party))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Read this side's copy of the file, with friendly fallbacks for
    /// missing / binary / oversized content.
    private func contents(of party: ConflictParty) -> String {
        let url = party.rootURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            return String(localized: "(file not available in this worktree)")
        }
        if data.count > Self.maxPreviewBytes {
            return String(localized: "(file too large to preview)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return String(localized: "(binary file)")
        }
        return text
    }
}
