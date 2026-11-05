import Foundation
import NaturalLanguage

enum InputLanguage {
    static func initialTarget(for text: String) -> String? {
        // Bound detection work even when an entire article is pasted.
        let sample = String(String.UnicodeScalarView(text.unicodeScalars.prefix(4096)))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: sample) == .japanese ? "en" : "ja"
    }
}
