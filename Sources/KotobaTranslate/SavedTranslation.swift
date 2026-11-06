import Foundation

struct SavedTranslation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var savedAt: Date
    let sourceText: String
    let translatedText: String
    let sourceLanguage: String
    let targetLanguage: String

    init(sourceText: String, translatedText: String, sourceLanguage: String, targetLanguage: String) {
        self.title = Self.makeTitle(translatedText.isEmpty ? sourceText : translatedText)
        self.savedAt = Date()
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    /// Prefer the first readable line (often a heading), then the first sentence.
    /// Bound the sample and truncate by Character to preserve CJK and emoji clusters.
    static func makeTitle(_ text: String) -> String {
        let sample = String(text.prefix(2000))
        for line in sample.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#>*-`_ "))
            guard !cleaned.isEmpty else { continue }
            let words = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let sentence = words.prefix { !"。！？!?".contains($0) }
            let title = sentence.isEmpty ? words : String(sentence)
            return String(title.prefix(48)) + (title.count > 48 ? "…" : "")
        }
        return "保存した翻訳"
    }
}
