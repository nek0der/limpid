// ClipboardConfirmationSheet.swift
// Limpid — modal sheet asking the user to allow or deny an OSC 52
// clipboard read / write (or an unsafe paste). The shell can request
// these at any time, so the copy stresses *what the terminal is
// trying to do* rather than what the user just did.

import SwiftUI

struct ClipboardConfirmationSheet: View {
    let request: PendingClipboardRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    private var preview: String {
        String(request.contents.unicodeScalars.prefix(8192))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceL) {
            HStack(alignment: .top, spacing: LimpidLayout.Supervision.spaceM) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(SupervisionTokens.waiting.color)
                    .font(.supervision(.symbolHero))
                VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceXS) {
                    Text(title)
                        .font(LimpidFont.title)
                    Text(message)
                        .font(LimpidFont.body)
                        .foregroundStyle(LimpidColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                Text(verbatim: preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LimpidLayout.Supervision.spaceS)
            }
            .frame(minHeight: 80, maxHeight: 200)
            .background(LimpidColor.terminalColumnBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if preview.utf8.count < request.contents.utf8.count {
                Text("Preview shortened. Allowing sends the entire text.")
                    .font(LimpidFont.caption)
                    .foregroundStyle(LimpidColor.secondaryText)
            }

            HStack {
                Spacer()
                Button(role: .cancel) {
                    onDeny()
                } label: {
                    Text(denyLabel)
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onAllow()
                } label: {
                    Text(allowLabel)
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(LimpidLayout.Supervision.spaceXL)
        .frame(minWidth: 460)
    }

    private var title: LocalizedStringResource {
        switch request.kind {
        case .osc52Read: "Allow clipboard read?"
        case .osc52Write: "Allow clipboard write?"
        case .unsafePaste: "Paste this text?"
        }
    }

    private var message: LocalizedStringResource {
        switch request.kind {
        case .osc52Read:
            """
            The terminal is requesting to read the contents of your clipboard. \
            Allow this only if you recognize the program that asked.
            """
        case .osc52Write:
            "The terminal is requesting to replace your clipboard with the text shown below."
        case .unsafePaste:
            "The text you are about to paste looks like it may execute commands. Review it carefully before allowing."
        }
    }

    private var allowLabel: LocalizedStringResource {
        switch request.kind {
        case .osc52Read, .osc52Write: "Allow"
        case .unsafePaste: "Paste"
        }
    }

    private var denyLabel: LocalizedStringResource {
        switch request.kind {
        case .osc52Read, .osc52Write: "Deny"
        case .unsafePaste: "Cancel"
        }
    }
}
