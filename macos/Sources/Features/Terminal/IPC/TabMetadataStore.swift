import Foundation
import Cocoa

/// Stores per-tab metadata (status entries) that can be set via IPC.
/// Each tab is identified by its surface UUID.
@MainActor
final class TabMetadataStore: ObservableObject {
    static let shared = TabMetadataStore()

    struct StatusEntry: Equatable, Codable {
        let key: String
        let value: String
        let icon: String?  // SF Symbol name, optional
        /// Optional semantic state that drives color + animation in the sidebar.
        /// One of: "working", "done", "error", "idle". nil = neutral (no color).
        let state: String?
    }

    /// Status entries keyed by tab UUID, then by status key
    @Published private(set) var entries: [UUID: [String: StatusEntry]] = [:]

    private init() {}

    func setStatus(tabId: UUID, key: String, value: String, icon: String? = nil, state: String? = nil) {
        if entries[tabId] == nil {
            entries[tabId] = [:]
        }
        entries[tabId]?[key] = StatusEntry(key: key, value: value, icon: icon, state: state)
    }

    func clearStatus(tabId: UUID, key: String) {
        entries[tabId]?.removeValue(forKey: key)
        if entries[tabId]?.isEmpty == true {
            entries.removeValue(forKey: tabId)
        }
    }

    func statusEntries(for tabId: UUID) -> [StatusEntry] {
        guard let tabEntries = entries[tabId] else { return [] }
        return tabEntries.values.sorted { $0.key < $1.key }
    }

    func removeAll(for tabId: UUID) {
        entries.removeValue(forKey: tabId)
    }
}
