// CreateWorktreeSheet.swift
// Limpid — modal sheet for `git worktree add`. Branch + optional new
// branch + open-tab toggle; the path is derived automatically from the
// project's `worktreePlacement` and the branch name. Power users can
// reveal an "Advanced" section to override the parent directory for
// this single creation. Stays a terminal-app affordance: no remotes /
// fetch / advanced git switches — users who need those drop into the
// shell.

import AppKit
import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WindowSession.self) private var session

    let projectID: UUID

    // MARK: - Form state

    @State private var baseBranch: String = ""
    @State private var availableBranches: [String] = []
    @State private var createsNewBranch: Bool = true
    @State private var newBranchName: String = ""
    /// One-shot override for the parent directory. Empty = use the
    /// project's placement strategy. Power users can open the Advanced
    /// disclosure and point this somewhere else without disturbing the
    /// per-project default in Project Settings.
    @State private var customParentText: String = ""
    @State private var openTabAfterCreate: Bool = true
    @State private var showAdvanced: Bool = false

    // Async / error state
    @State private var isLoadingBranches = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var project: Project? {
        session.projects.first(where: { $0.id == projectID })
    }

    private var canCreate: Bool {
        guard !isCreating,
              !baseBranch.isEmpty,
              !effectiveBranchLeaf().isEmpty,
              resolvedPath != nil
        else { return false }
        if locationConflicts { return false }
        if createsNewBranch {
            return !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Final on-disk path. Either the Advanced override (when set) or
    /// the project's placement strategy resolved with the branch leaf.
    private var resolvedPath: URL? {
        guard let project else { return nil }
        let leaf = effectiveBranchLeaf()
        guard !leaf.isEmpty else { return nil }
        let trimmed = customParentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parent = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            return parent.appendingPathComponent(leaf)
        }
        return project.resolvedWorktreeURL(branchLeaf: leaf)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    branchPickerRow
                    Toggle("Create New Branch", isOn: $createsNewBranch)
                    if createsNewBranch {
                        TextField("Branch name", text: $newBranchName)
                    }
                } header: {
                    Text("Branch")
                } footer: {
                    if let project {
                        Text("Project: \(project.name)")
                            .foregroundStyle(.secondary)
                    }
                }

                pathPreviewSection

                Section {
                    Toggle("Open Tab in New Worktree", isOn: $openTabAfterCreate)
                }

                advancedSection

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label {
                        Text("New Worktree")
                            .font(.system(size: 14, weight: .semibold))
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!canCreate)
                }
            }
        }
        .frame(width: 520, height: 480)
        .task { await loadBranches() }
    }

    // MARK: - Branch picker

    @ViewBuilder
    private var branchPickerRow: some View {
        if isLoadingBranches {
            HStack {
                Text("Base branch")
                Spacer()
                ProgressView().controlSize(.small)
            }
        } else {
            Picker("Base branch", selection: $baseBranch) {
                ForEach(availableBranches, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
    }

    // MARK: - Path preview + advanced override

    private var pathPreviewSection: some View {
        Section {
            LabeledContent("Path preview") {
                if let preview = resolvedPath?.path {
                    Text(PathFormatting.abbreviateHome(preview))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            if locationConflicts {
                Label(
                    "A folder already exists at this path. Pick a different branch name or location.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Location")
        } footer: {
            placementFooter
        }
    }

    @ViewBuilder
    private var placementFooter: some View {
        if let project {
            switch project.worktreePlacement {
            case .siblingPrefixed:
                Text("Using project default: sibling folder prefixed with the repo name.")
            case .insideHidden:
                Text("Using project default: hidden subdirectory inside the project.")
            case let .custom(url):
                Text("Using project default: \(PathFormatting.abbreviateHome(url.path))")
            }
        }
    }

    private var advancedSection: some View {
        // Wrapping a DisclosureGroup inside Section { } loses the
        // form's per-row padding for the disclosure's children, so
        // the inner Override row reads as cramped. Promote the
        // disclosure trigger to a Toggle in the same Section and let
        // the conditional row sit beside it as a regular Form row —
        // that's the System Settings 2026 pattern.
        Section {
            Toggle("Override location", isOn: $showAdvanced)
            if showAdvanced {
                LabeledContent("Parent folder") {
                    HStack(spacing: 8) {
                        Button {
                            chooseCustomParent()
                        } label: {
                            Label {
                                Text(displayCustomParent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.regular)
                        if !customParentText.isEmpty {
                            Button("Clear") {
                                customParentText = ""
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Advanced")
        }
    }

    private var displayCustomParent: String {
        let trimmed = customParentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Choose…") }
        return PathFormatting.abbreviateHome(trimmed)
    }

    // MARK: - Branch loading

    private func loadBranches() async {
        guard let project else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        let head = await (try? GitProcess.currentBranch(repoRoot: project.rootURL)) ?? nil
        let branches = await (try? GitProcess.listLocalBranches(repoRoot: project.rootURL)) ?? []
        var list = branches
        if let head, !list.contains(head) {
            list.insert(head, at: 0)
        }
        if list.isEmpty {
            list = ["HEAD"]
        }
        availableBranches = list
        baseBranch = head ?? list.first ?? "HEAD"
    }

    // MARK: - Location helpers

    /// True when the resolved final path already exists on disk.
    /// Suppressed while a Create is in flight — once the git CLI
    /// succeeds the folder exists (we just made it), and otherwise
    /// the sheet would flash an "already exists" warning during its
    /// dismiss animation.
    private var locationConflicts: Bool {
        guard !isCreating, let url = resolvedPath else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func effectiveBranchLeaf() -> String {
        let raw: String
        if createsNewBranch {
            let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
            raw = trimmed.isEmpty ? baseBranch : trimmed
        } else {
            raw = baseBranch
        }
        return raw.replacingOccurrences(of: "/", with: "-")
    }

    private func chooseCustomParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        let trimmed = customParentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (trimmed as NSString).expandingTildeInPath
            )
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        customParentText = chosen.path
    }

    // MARK: - Create

    private func create() async {
        guard let project, let url = resolvedPath else { return }
        isCreating = true
        errorMessage = nil
        do {
            _ = try await session.createGitWorktree(
                projectID: project.id,
                path: url,
                baseBranch: baseBranch,
                newBranchName: createsNewBranch ? newBranchName : nil,
                openTab: openTabAfterCreate
            )
            // Keep `isCreating` true through the dismiss animation —
            // the folder now exists on disk, so flipping it back would
            // let `locationConflicts` evaluate true for the frames
            // between defer and view tear-down, flashing an orange
            // "folder already exists" warning. The view is about to
            // be destroyed; nothing else needs the flag reset.
            dismiss()
        } catch {
            isCreating = false
            errorMessage = error.localizedDescription
        }
    }
}
