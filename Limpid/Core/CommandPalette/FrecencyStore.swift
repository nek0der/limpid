// FrecencyStore.swift
// Limpid — frequency + recency scoring for command palette items.
// Persisted to frecency.json with debounced writes following the
// same pattern as NotificationHistoryStore.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "frecency")

@MainActor
final class FrecencyStore {

    struct Entry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// Half-life of 3 days. An action used 3 days ago retains ~50%
    /// of its recency weight; after 2 weeks it's near zero.
    private static let halfLifeSeconds: Double = 259_200
    private static let decayFactor: Double = 0.693 / halfLifeSeconds

    private(set) var entries: [String: Entry] = [:]
    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "dev.limpid.frecency")

    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.fileURL = directory.appendingPathComponent("frecency.json")
        load()
    }

    // MARK: - Scoring

    func score(for itemID: String, now: Date = .now) -> Double {
        guard let entry = entries[itemID] else { return 0 }
        let age = now.timeIntervalSince(entry.lastUsed)
        let recency = exp(-Self.decayFactor * max(age, 0))
        return Double(entry.count) * recency
    }

    // MARK: - Recording

    func record(_ itemID: String) {
        if var existing = entries[itemID] {
            existing.count += 1
            existing.lastUsed = .now
            entries[itemID] = existing
        } else {
            entries[itemID] = Entry(count: 1, lastUsed: .now)
        }
        scheduleSave()
    }

    // MARK: - Persistence

    func flushSynchronously() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let url = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([String: Entry].self, from: data)
        } catch {
            log.error("failed to decode frecency.json: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem { [saveQueue] in
            saveQueue.async {
                Self.write(snapshot, to: url)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    private nonisolated static func write(_ entries: [String: Entry], to url: URL) {
        do {
            let encoder = JSONEncoder()
            #if DEBUG
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            #endif
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("failed to write frecency.json: \(String(describing: error), privacy: .public)")
        }
    }
}
