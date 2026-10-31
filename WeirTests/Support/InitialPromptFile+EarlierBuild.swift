// InitialPromptFile+EarlierBuild.swift
// Weir — the first instruction files an earlier build wrote, made for the suites that check this build still delivers them.

import Foundation
@testable import Weir
@testable import WeirDomain

extension InitialPromptFile {
    /// Writes `prompt` to a new file in `directory` as an earlier build's
    /// sheet did, 0600 in a 0700 folder: this build writes none, and still
    /// reads them for one release.
    static func stagedByEarlierBuild(_ prompt: String, in directory: URL) throws -> URL {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        let url = directory.appendingPathComponent(UUID().uuidString)
        try SecureFileWrite.writeAtomic(Data(prompt.utf8), to: url)
        return url
    }

    /// A tab in `container` as an earlier build opened it behind, and this
    /// one restored it with its terminal not made yet: `agent` staged with
    /// `prompt`'s file. Returns the pane and the file.
    @MainActor
    static func restoredTab(
        in session: WorkspaceSession,
        container: ContainerID,
        agent: AgentKind,
        prompt: String,
        directory: URL
    ) throws -> (paneID: UUID, file: String) {
        let file = try stagedByEarlierBuild(prompt, in: directory)
        let tab = session.openTab(container: container)
        guard let paneID = tab.splitTree.allLeafIDs().first else { throw NoPane() }
        session.update(tab.id) {
            $0.initialCommands[paneID] = agent.launchCommand
            $0.initialPromptFiles[paneID] = file.path
        }
        return (paneID, file.path)
    }

    struct NoPane: Error {}
}
