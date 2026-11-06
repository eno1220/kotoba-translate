import Foundation
import NaturalLanguage

enum InputLanguage {
    static func detectedLanguage(for text: String) -> String? {
        // Bound detection work even when an entire article is pasted.
        let sample = String(String.UnicodeScalarView(text.unicodeScalars.prefix(4096)))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue.lowercased()
    }

    static func initialTarget(for text: String) -> String? {
        guard let language = detectedLanguage(for: text) else { return nil }
        return language == "ja" ? "en" : "ja"
    }
}
