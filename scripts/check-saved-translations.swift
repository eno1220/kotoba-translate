// swiftc -parse-as-library Sources/KotobaTranslate/SavedTranslation.swift Sources/KotobaTranslate/SavedTranslationStore.swift scripts/check-saved-translations.swift -o /tmp/check-saved-translations
import Foundation

@main
struct SavedTranslationChecks {
    @MainActor
    static func wait(_ store: SavedTranslationStore) async throws {
        for _ in 0..<500 {
            if !store.working { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Storage operation timed out")
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.json")
        let store = SavedTranslationStore(url: url)
        try await wait(store)
        precondition(store.ready && store.entries.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: url.path), "Opening the library must not write text")

        let entry = SavedTranslation(sourceText: "Original\n\nPreserve formatting.", translatedText: "\n# 翻訳の見出し\n本文です。",
                                     sourceLanguage: "en", targetLanguage: "ja")
        precondition(entry.title == "翻訳の見出し")
        precondition(SavedTranslation.makeTitle("\n\n") == "保存した翻訳")
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        precondition(SavedTranslation.makeTitle(emoji) == String(emoji.prefix(48)) + "…")
        store.save(entry)
        try await wait(store)
        precondition(store.entries.count == 1 && store.error == nil)
        let savedAt = store.entries[0].savedAt
        store.save(entry)
        precondition(store.entries.count == 1, "Repeated saving of a result must not duplicate it")
        store.rename(entry.id, title: "  Renamed  ")
        try await wait(store)
        let reopened = SavedTranslationStore(url: url)
        try await wait(reopened)
        precondition(reopened.entries[0].sourceText == entry.sourceText)
        precondition(reopened.entries[0].translatedText == entry.translatedText)
        precondition(reopened.entries[0].title == "Renamed" && reopened.entries[0].savedAt == savedAt)
        reopened.delete(entry.id)
        try await wait(reopened)
        let empty = SavedTranslationStore(url: url)
        try await wait(empty)
        precondition(empty.entries.isEmpty)

        let corrupted = Data("invalid saved data".utf8)
        try corrupted.write(to: url)
        let broken = SavedTranslationStore(url: url)
        try await wait(broken)
        precondition(!broken.ready && broken.error != nil)
        broken.save(entry)
        let preserved = try Data(contentsOf: url)
        precondition(preserved == corrupted, "A failed load must never overwrite saved data")

        let failureURL = directory.appendingPathComponent("failure.json")
        let failing = SavedTranslationStore(url: failureURL)
        try await wait(failing)
        try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: true)
        failing.save(entry)
        try await wait(failing)
        precondition(failing.entries.isEmpty && failing.error != nil, "A failed write must not report success")
        print("Saved translation checks passed")
    }
}
