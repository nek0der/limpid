// ConversationIdentityStore.swift
// Weir — each session container's identity colors, worked out from the app's stores only when what decides them changes.

import Foundation

/// The identity color of each conversation of a session container (a
/// project's folder or a worktree), as every surface that shows one reads
/// it: the changes panel, the right rail, the pane strip and Open Tabs, and
/// the review's conversations and file tags. One for the app
/// (`AppState.conversationIdentities`), so a conversation has the same
/// color on its tab as on its cards, in every window.
///
/// A read is worked out from the stores it is handed (`Sources`) and kept
/// per container under what decides it (`Key`): the worktree's top level,
/// the turn history's and the viewed lines' revisions, the conversations
/// the container's panes run, the turns a restore took back, and the path
/// spellings' generation. A read with the same key hands back what the
/// last one did, so the strip's body, drawn again on every word an agent
/// reports, neither walks the turn history nor moves a color. Only when
/// the key changes are the active conversations found again
/// (`ChangesPanelModel.activeConversations`) and handed their colors
/// (`ConversationIdentityRule.assign`), keeping what each held before.
///
/// Keyed by the container rather than its repository root because the
/// active conversations are read from the container's panes: two
/// containers at one root would otherwise feed different active sets into
/// one memory, and their surfaces would take each other's colors away.
///
/// Kept in memory only: after a relaunch the colors are handed out again in
/// the order the conversations were created. Not observed: a read registers
/// the stores it reads the key from, so a view redraws on the facts that
/// change the active set, not on this store.
@MainActor
final class ConversationIdentityStore {
    /// The app's stores the colors are read from.
    struct Sources {
        let session: WorkspaceSession
        /// Each session folder's Git top level.
        let repositoryRoots: RepositoryRoots
        let turnHistory: TurnHistory
        let viewedLines: ViewedLineStore
        /// The runtimes, for the conversation each pane runs.
        let attention: AttentionState
        /// The turns a restore took back, which no longer count as unviewed.
        let restoredTurnIDs: () -> Set<TurnID>
    }

    /// What decides a container's colors. Each part is cheap to read
    /// against the work it saves: the history and the lines by their
    /// revision rather than their turns.
    struct Key: Equatable {
        let root: String
        let historyRevision: Int
        let viewedLinesRevision: Int
        /// The conversations the container's panes run, in their order
        /// (`ConversationTabs.running`).
        let running: [ConversationKey]
        let restored: Set<TurnID>
        /// The path spellings' generation (`RepositoryRoots.pathGeneration`):
        /// which recorded roots are this worktree's (`isRoot`) can change
        /// with it while every other part stays the same.
        let pathGeneration: Int
    }

    /// One container's last read, under the key it was read for.
    private struct Read {
        let key: Key
        let identities: [ConversationKey: Int]
    }

    /// How many colors the palette has.
    let paletteCount: Int
    private let sources: Sources
    private var reads: [ContainerID: Read] = [:]
    /// What `ConversationIdentityRule.assign` last handed out in each container,
    /// including the one conversation left while fewer than two are active.
    private var assignments: [ContainerID: [ConversationKey: Int]] = [:]
    /// How many times a read worked the colors out rather than handing
    /// back the last. For tests, which read it to know a read with the same
    /// key did no work; nothing in the app reads it.
    private(set) var derivationCount = 0

    /// The containers something is kept for. For tests, which read it to
    /// know a closed container's memory went; nothing in the app reads it.
    var keptContainers: Set<ContainerID> {
        Set(reads.keys).union(assignments.keys)
    }

    init(paletteCount: Int, sources: Sources) {
        self.paletteCount = paletteCount
        self.sources = sources
    }

    /// The identity color of each active conversation of `container`'s worktree.
    /// Empty for a scratch tab's container, which has no worktree, until
    /// Git has named the worktree's top level, and while fewer than two
    /// conversations are active.
    func identities(in container: ContainerID) -> [ConversationKey: Int] {
        guard let folder = ReviewAgents.directory(for: container, in: sources.session),
              let answer = sources.repositoryRoots.answer(for: folder),
              case let .repository(root) = answer
        else { return [:] }
        let running = ConversationTabs(tabs: sources.session.tabs(in: container), runtimes: sources.attention.allRuntimes).running
        let restored = sources.restoredTurnIDs()
        let key = Key(
            root: root,
            historyRevision: sources.turnHistory.revision,
            viewedLinesRevision: sources.viewedLines.revision,
            running: running,
            restored: restored,
            pathGeneration: sources.repositoryRoots.pathGeneration
        )
        return identities(for: container, key: key) { [sources] in
            // Only when something moved, not on every read: a container
            // closed since keeps no memory here.
            forgetGoneContainers()
            let input = ChangesPanelModel.Input(
                agents: ChangesPanelModel.agents(
                    history: sources.turnHistory.conversations,
                    running: running,
                    root: root,
                    isRoot: { sources.repositoryRoots.isRoot($0, of: answer) }
                ),
                running: running,
                line: { sources.viewedLines.line(of: $0) },
                isRestored: { restored.contains($0.turnID) }
            )
            return ChangesPanelModel.activeConversations(input)
        }
    }

    /// Lets go of what was kept for containers the session no longer has
    /// (a worktree removed, a project closed), so the store holds no more
    /// than the session's containers.
    private func forgetGoneContainers() {
        let session = sources.session
        reads = reads.filter { session.containerExists($0.key) }
        assignments = assignments.filter { session.containerExists($0.key) }
    }

    /// `container`'s colors under `key`: the last read's while the key is
    /// the same, else handed out again over `active`, keeping what was
    /// handed out there before.
    ///
    /// While fewer than two are active nothing is shown, but the one left
    /// keeps its index in memory, so a conversation alone for a while is
    /// back in its own color when another starts beside it.
    func identities(for container: ContainerID, key: Key, active: () -> [ConversationKey]) -> [ConversationKey: Int] {
        if let read = reads[container], read.key == key {
            return read.identities
        }
        derivationCount += 1
        let active = active()
        let previous = assignments[container] ?? [:]
        let assigned = ConversationIdentityRule.assign(active: active, previous: previous, paletteCount: paletteCount)
        let activeSet = Set(active)
        let kept = assigned.isEmpty ? previous.filter { activeSet.contains($0.key) } : assigned
        assignments[container] = kept.isEmpty ? nil : kept
        reads[container] = Read(key: key, identities: assigned)
        return assigned
    }
}
