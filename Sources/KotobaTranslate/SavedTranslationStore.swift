import Combine
import Foundation

/// File operations run off the main actor. A failed read never becomes an empty,
/// writable library: the user can retry without overwriting their saved entries.
private actor SavedTranslationFile {
    let url: URL

    init(url: URL) { self.url = url }

    func load() throws -> [SavedTranslation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedTranslation].self, from: Data(contentsOf: url))
    }

    func write(_ entries: [SavedTranslation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

@MainActor
final class SavedTranslationStore: ObservableObject {
    @Published private(set) var entries: [SavedTranslation] = []
    @Published private(set) var working = false
    @Published private(set) var ready = false
    @Published var error: String?
    private let file: SavedTranslationFile

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kotoba Translate/SavedTranslations.json")) {
        file = SavedTranslationFile(url: url)
        reload()
    }

    func reload() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                entries = try await file.load().sorted { $0.savedAt > $1.savedAt }
                ready = true
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func contains(_ entry: SavedTranslation) -> Bool { entries.contains { $0.id == entry.id } }

    func save(_ entry: SavedTranslation) {
        guard !contains(entry) else { return }
        var saved = entry
        saved.savedAt = Date()
        commit([saved] + entries)
    }

    func rename(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].title = String(title.prefix(200))
        commit(updated)
    }

    func delete(_ id: UUID) { commit(entries.filter { $0.id != id }) }

    private func commit(_ updated: [SavedTranslation]) {
        guard ready, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await file.write(updated)
                entries = updated
            } catch { self.error = error.localizedDescription }
        }
    }
}
