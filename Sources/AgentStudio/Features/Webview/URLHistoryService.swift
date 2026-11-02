import AgentStudioInfrastructure
import Foundation
import Observation
import os.log

private let historyLogger = Logger(subsystem: "com.agentstudio", category: "URLHistory")

// MARK: - URLHistoryStorage Protocol

/// Abstraction over persistence for testability.
protocol URLHistoryStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension UserDefaults: URLHistoryStorage {
    func set(_ data: Data?, forKey key: String) {
        set(data as Any?, forKey: key)
    }
}

// MARK: - URLHistoryService

/// Tracks visited URLs and user favorites across all webview panes.
/// Persists via injectable storage (UserDefaults by default).
/// History auto-prunes entries older than 2 weeks. Capped at 100 entries.
@Observable
@MainActor
final class URLHistoryService {

    static let shared = URLHistoryService()

    private static let historyKey = "com.agentstudio.urlHistory"
    private static let favoritesKey = "com.agentstudio.webviewFavorites"
    private static let maxEntries = 100
    private static let retentionDays = 14

    /// Default favorites seeded on first run.
    static let defaultFavorites: [URLHistoryEntry] = [
        URLHistoryEntry(url: URL(string: "https://github.com")!, title: "GitHub"),
        URLHistoryEntry(url: URL(string: "https://google.com")!, title: "Google"),
    ]

    private let storage: URLHistoryStorage

    private(set) var entries: [URLHistoryEntry] = []
    private(set) var favorites: [URLHistoryEntry] = []

    init(storage: URLHistoryStorage = AppStorageIdentity.current.userDefaults) {
        self.storage = storage
        loadHistory()
        loadFavorites()
    }

    // MARK: - Record History

    /// Record a visited URL. Deduplicates by URL string, updates title and timestamp.
    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else { return }
        guard let host = url.host(), !host.isEmpty else { return }

        let displayTitle = title.isEmpty ? host : title
        let key = url.absoluteString.lowercased()

        if let index = entries.firstIndex(where: { $0.url.absoluteString.lowercased() == key }) {
            entries[index].title = displayTitle
            entries[index].lastVisited = Date()
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
        } else {
            let entry = URLHistoryEntry(url: url, title: displayTitle)
            entries.insert(entry, at: 0)
        }

        pruneExpired()

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        saveHistory()
    }

    /// Remove all history entries.
    func clearHistory() {
        entries.removeAll()
        saveHistory()
    }

    // MARK: - Favorites

    /// Add a URL to favorites.
    func addFavorite(url: URL, title: String) {
        let key = url.absoluteString.lowercased()
        guard !favorites.contains(where: { $0.url.absoluteString.lowercased() == key }) else { return }
        let entry = URLHistoryEntry(url: url, title: title.isEmpty ? (url.host() ?? "Web") : title)
        favorites.append(entry)
        saveFavorites()
    }

    /// Remove a URL from favorites.
    func removeFavorite(url: URL) {
        let key = url.absoluteString.lowercased()
        favorites.removeAll { $0.url.absoluteString.lowercased() == key }
        saveFavorites()
    }

    /// Whether a URL is in favorites.
    func isFavorite(url: URL) -> Bool {
        let key = url.absoluteString.lowercased()
        return favorites.contains { $0.url.absoluteString.lowercased() == key }
    }

    // MARK: - Query Helpers

    /// Recent history entries excluding favorites, within retention window.
    func recentSites(limit: Int = 12) -> [URLHistoryEntry] {
        let favoriteKeys = Set(favorites.map { $0.url.absoluteString.lowercased() })
        let recent = entries.filter { !favoriteKeys.contains($0.url.absoluteString.lowercased()) }
        return Array(recent.prefix(limit))
    }

    /// All searchable entries: favorites first, then history (deduped).
    func allSearchable() -> [URLHistoryEntry] {
        var result = favorites
        let favoriteKeys = Set(favorites.map { $0.url.absoluteString.lowercased() })
        let historyOnly = entries.filter { !favoriteKeys.contains($0.url.absoluteString.lowercased()) }
        result.append(contentsOf: historyOnly)
        return result
    }

    /// Return suggestions matching the query. Favorites first, then recency.
    func suggestions(for query: String) -> [URLHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var results: [URLHistoryEntry] = favorites.filter { entry in
            trimmed.isEmpty
                || entry.url.absoluteString.lowercased().contains(trimmed)
                || entry.title.lowercased().contains(trimmed)
        }

        let favoriteKeys = Set(results.map { $0.url.absoluteString.lowercased() })

        let historyMatches = entries.filter { entry in
            let key = entry.url.absoluteString.lowercased()
            guard !favoriteKeys.contains(key) else { return false }
            if trimmed.isEmpty { return true }
            return key.contains(trimmed)
                || entry.title.lowercased().contains(trimmed)
        }

        results.append(contentsOf: historyMatches)
        return Array(results.prefix(8))
    }

    // MARK: - Retention

    private func pruneExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date())!
        entries.removeAll { $0.lastVisited < cutoff }
    }

    // MARK: - Persistence

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        storage.set(data, forKey: Self.historyKey)
    }

    private func loadHistory() {
        guard let data = storage.data(forKey: Self.historyKey),
            let decoded = try? JSONDecoder().decode([URLHistoryEntry].self, from: data)
        else {
            return
        }
        entries = decoded
        let countBefore = entries.count
        pruneExpired()
        if entries.count < countBefore {
            saveHistory()
        }
    }

    private func saveFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        storage.set(data, forKey: Self.favoritesKey)
    }

    private func loadFavorites() {
        if let data = storage.data(forKey: Self.favoritesKey),
            let decoded = try? JSONDecoder().decode([URLHistoryEntry].self, from: data)
        {
            favorites = decoded
        } else {
            // Seed defaults on first run
            favorites = Self.defaultFavorites
            saveFavorites()
        }
    }
}

// MARK: - URLHistoryEntry

struct URLHistoryEntry: Codable, Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    var title: String
    var lastVisited: Date

    init(url: URL, title: String, lastVisited: Date = Date()) {
        self.url = url
        self.title = title
        self.lastVisited = lastVisited
    }
}
