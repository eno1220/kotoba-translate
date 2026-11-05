import Foundation

struct InputStatistics: Sendable {
    var characters = 0
    var estimatedTokens = 0

    /// A lightweight heuristic, not the model tokenizer. No Python or model loading.
    static func measure(_ text: String) throws -> InputStatistics {
        var weight = 0.0
        var scalars = 0
        for scalar in text.unicodeScalars {
            if scalars % 4096 == 0 { try Task.checkCancellation() }
            scalars += 1
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x323AF:
                weight += 1.5
            default:
                weight += Double(scalar.utf8.count) / 4
            }
        }
        return InputStatistics(characters: text.count, estimatedTokens: Int(ceil(weight)))
    }
}
