// StatusBandView.swift
// Limpid — the 26pt band along the window's bottom: where the pane in use is, and what runs in it.

import SwiftUI

/// Display only. It stands on the window's ground, under the
/// surfaces, whose lower edges set it apart. When the two sides do not
/// fit, the path gives way first and loses its left end, so the pane's own
/// name stays in sight; only when the details alone are too wide does the
/// folder among them lose its middle.
struct StatusBandView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionState.self) private var attention
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.locale) private var locale

    var body: some View {
        let model = StatusBandModel(
            StatusBandModel.input(
                session: session,
                window: window,
                attention: attention,
                gridSize: gridSize(ofPane:),
                locale: locale
            ),
            locale: locale
        )
        HStack(spacing: LimpidLayout.Supervision.statusBandSpacing) {
            Text(Self.path(model.crumbs))
                .lineLimit(1)
                .supervisionTruncation(.breadcrumb)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            // Each fact on its own, set apart by space rather than dots.
            HStack(spacing: LimpidLayout.Supervision.statusBandSpacing) {
                ForEach(Array(model.details.enumerated()), id: \.offset) { _, detail in
                    Text(verbatim: detail.text)
                        .font(detail.isFolder ? .supervisionCode(beside: Self.size) : .supervision(Self.size))
                        .lineLimit(1)
                        .supervisionTruncation(detail.isFolder ? .path : .name)
                        .layoutPriority(detail.isFolder ? 0 : 1)
                }
            }
            .layoutPriority(1)
        }
        .font(.supervision(Self.size))
        .foregroundStyle(SupervisionTokens.muted.color)
        .padding(.horizontal, LimpidLayout.Supervision.statusBandInset)
        .frame(height: LimpidLayout.Supervision.statusBarHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.spokenLabel))
    }

    /// The band's words.
    private static let size = LimpidFont.Supervision.Size.meta

    /// The path as one line, so it is cut as one: the branch or folder in
    /// the code face, as everywhere a name Git gave is drawn.
    private static func path(_ crumbs: [StatusBandModel.Crumb]) -> AttributedString {
        crumbs.enumerated().reduce(into: AttributedString()) { line, entry in
            if entry.offset > 0 {
                line += AttributedString(StatusBandModel.crumbSeparator)
            }
            var crumb = AttributedString(entry.element.text)
            if entry.element.isCode {
                crumb.font = .supervisionCode(beside: size)
            }
            line += crumb
        }
    }

    /// Read live from the pane's surface. Reading the two counters first is
    /// what draws the band again when a resize or a font change moves the
    /// grid, since the surface itself is not observed.
    private func gridSize(ofPane paneID: UUID) -> TerminalGridSize? {
        _ = session.terminalGridGeneration
        _ = session.cellSizeGeneration
        return registry.view(for: paneID)?.gridSize
    }
}
