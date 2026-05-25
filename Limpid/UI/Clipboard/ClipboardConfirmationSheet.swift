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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(LimpidFont.title)
                    Text(message)
                        .font(LimpidFont.body)
                        .foregroundStyle(LimpidColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                Text(request.contents)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 200)
            .background(LimpidColor.l3Background)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
        .padding(20)
        .frame(minWidth: 460)
    }

    private var title: String {
        switch request.kind {
        case .osc52Read: String(localized: "Allow clipboard read?")
        case .osc52Write: String(localized: "Allow clipboard write?")
        case .unsafePaste: String(localized: "Paste this text?")
        }
    }

    private var message: String {
        switch request.kind {
        case .osc52Read:
            String(
                localized: """
                The terminal is requesting to read the contents of your clipboard. \
                Only allow this if you recognise the program that issued the request.
                """
            )
        case .osc52Write:
            String(localized: "The terminal is requesting to replace your clipboard with the text shown below.")
        case .unsafePaste:
            String(localized: "The text you are about to paste looks like it may execute commands. Review it carefully before allowing.")
        }
    }

    private var allowLabel: String {
        switch request.kind {
        case .osc52Read, .osc52Write: String(localized: "Allow")
        case .unsafePaste: String(localized: "Paste")
        }
    }

    private var denyLabel: String {
        switch request.kind {
        case .osc52Read, .osc52Write: String(localized: "Deny")
        case .unsafePaste: String(localized: "Cancel")
        }
    }
}
