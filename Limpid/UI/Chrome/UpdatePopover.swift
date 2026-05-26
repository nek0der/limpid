// UpdatePopover.swift
// Limpid — bubble shown when the L3 chrome shippingbox is tapped.
// The body switches between several child views based on the
// updater's current `UpdateState` so the same popover carries the
// user from "found an update" all the way through "installing → done"
// without ever handing off to Sparkle's standard modal alert.
//
// Each child view owns its action closures (Skip / Later / Install /
// Cancel / Retry / Dismiss). Those wrap the Sparkle reply /
// acknowledgement / cancellation handlers embedded in the
// `UpdateState` enum cases.

import Sparkle
import SwiftUI

struct UpdatePopover: View {
    let updater: SPUUpdater
    let dismiss: () -> Void
    /// Caller-supplied width. The chrome popover uses a fixed 340pt
    /// bubble; the Settings pane lets the form column size it.
    var width: CGFloat? = 340

    @Environment(UpdateStateModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .idle:
                EmptyView()
            case let .checking(cancel):
                CheckingView(cancel: cancel)
            case let .available(item, reply):
                AvailableView(item: item, reply: reply, dismiss: dismiss)
            case let .downloading(item, expected, received, cancel):
                DownloadingView(
                    item: item,
                    expected: expected,
                    received: received,
                    cancel: cancel
                )
            case let .extracting(progress):
                ExtractingView(progress: progress)
            case let .readyToInstall(item, reply):
                ReadyToInstallView(item: item, reply: reply, dismiss: dismiss)
            case .installing:
                InstallingView()
            case .installed:
                // Driver already fired the ack and owns the auto-
                // dismiss timer; the view is decorative only.
                InstalledView()
            case let .notFound(acknowledgement):
                NotFoundView(acknowledgement: acknowledgement, dismiss: dismiss)
            case let .error(error, acknowledgement):
                ErrorView(
                    error: error,
                    acknowledgement: acknowledgement,
                    retry: {
                        updater.checkForUpdates()
                    },
                    dismiss: dismiss
                )
            }
        }
        .frame(width: width)
    }
}

// MARK: - Building blocks

/// Reusable metadata block (version / size / date) used by Available
/// and ReadyToInstall states.
private struct UpdateMetadata: View {
    let item: SUAppcastItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Version", value: item.displayVersion)
            if let size = formattedSize {
                row("Size", value: size)
            }
            if let date = formattedDate {
                row("Release Date", value: date)
            }
        }
        .font(.system(size: 12))
    }

    private func row(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var formattedSize: String? {
        let bytes = item.contentLength
        guard bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var formattedDate: String? {
        guard let date = item.date else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }
}

/// Footer link to the appcast item's release-notes URL, shared by
/// states that surface an appcast item.
private struct ReleaseNotesLink: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Divider()
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 13))
                Text("View Release Notes", comment: "Update popover: open release notes")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - State views

private struct CheckingView: View {
    let cancel: OneShot<Void>

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Checking for updates…", comment: "Update popover: in-progress check")
                .font(.system(size: 13))
            Spacer(minLength: 0)
            Button("Cancel") { cancel.call() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }
}

private struct AvailableView: View {
    let item: SUAppcastItem
    let reply: OneShot<SPUUserUpdateChoice>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Update available", comment: "Update popover title")
                    .font(.system(size: 16, weight: .semibold))
                UpdateMetadata(item: item)
                HStack(spacing: 8) {
                    Button {
                        reply.call(.skip)
                        dismiss()
                    } label: {
                        Text("Skip", comment: "Update popover: skip this version")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        reply.call(.dismiss)
                        dismiss()
                    } label: {
                        Text("Later", comment: "Update popover: remind me later")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button {
                        reply.call(.install)
                        // Don't close — the same popover keeps the
                        // user company through download / extract /
                        // installing as the state machine advances.
                    } label: {
                        Text("Install and Restart", comment: "Update popover: install + relaunch")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            if let notes = item.releaseNotesURL {
                ReleaseNotesLink(url: notes)
            }
        }
    }
}

private struct DownloadingView: View {
    let item: SUAppcastItem
    let expected: UInt64?
    let received: UInt64
    let cancel: OneShot<Void>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading \(item.displayVersion)", comment: "Update popover: downloading header")
                .font(.system(size: 13, weight: .semibold))
            if let expected, expected > 0 {
                ProgressView(value: Double(received), total: Double(expected))
                Text(progressText(received: received, expected: expected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { cancel.call() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }

    private func progressText(received: UInt64, expected: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let r = formatter.string(fromByteCount: Int64(received))
        let e = formatter.string(fromByteCount: Int64(expected))
        return "\(r) / \(e)"
    }
}

private struct ExtractingView: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preparing update…", comment: "Update popover: extracting / preparing")
                .font(.system(size: 13, weight: .semibold))
            ProgressView(value: progress)
        }
        .padding(16)
    }
}

private struct ReadyToInstallView: View {
    let item: SUAppcastItem
    let reply: OneShot<SPUUserUpdateChoice>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to install \(item.displayVersion)", comment: "Update popover: ready header")
                .font(.system(size: 13, weight: .semibold))
            Text(
                "Limpid will quit and relaunch to finish installing.",
                comment: "Update popover: ready-to-install explainer"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    reply.call(.dismiss)
                    dismiss()
                } label: {
                    Text("Later", comment: "Update popover: defer install")
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button {
                    reply.call(.install)
                } label: {
                    Text("Install and Restart", comment: "Update popover: install + relaunch")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

private struct InstallingView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Installing update…", comment: "Update popover: installing")
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Terminal "installed" state — single-row layout to match
/// `InstallingView` so the embedded Settings section doesn't jump
/// in height between phases. Auto-dismissal is owned by the driver
/// (5s timer); the view does no extra work, since the chrome
/// popover would otherwise need to coordinate timer vs. badge
/// visibility separately.
private struct InstalledView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13))
            Text("Update installed", comment: "Update popover: install complete")
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

private struct NotFoundView: View {
    let acknowledgement: OneShot<Void>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("You're up to date", comment: "Update popover: no update available")
                    .font(.system(size: 13, weight: .semibold))
            }
            HStack {
                Spacer(minLength: 0)
                Button("OK") {
                    acknowledgement.call()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct ErrorView: View {
    let error: any Error
    let acknowledgement: OneShot<Void>
    let retry: () -> Void
    let dismiss: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Update failed", comment: "Update popover: error header")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(error.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(showsDetails ? nil : 3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    showsDetails.toggle()
                } label: {
                    Text(
                        showsDetails ? "Hide details" : "Show details",
                        comment: "Update popover: expand error details"
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer(minLength: 0)
                Button {
                    acknowledgement.call()
                    dismiss()
                } label: {
                    Text("Close", comment: "Update popover: dismiss error")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    acknowledgement.call()
                    retry()
                } label: {
                    Text("Retry", comment: "Update popover: retry failed check")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
