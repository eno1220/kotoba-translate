import Foundation

enum TextFileImporter {
    static let extensions = ["txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml", "html", "htm", "log", "ini", "srt", "vtt"]
    static let byteLimit = 8 * 1024 * 1024

    enum ImportError: LocalizedError {
        case tooLarge, unsupported, empty
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "テキストファイルが大きすぎます。8MB・200万文字以内に分割してください。"
            case .unsupported: return "プレーンテキストとして読み取れません。UTF-8、BOM付きUTF-16／UTF-32、またはShift JISで保存してください。"
            case .empty: return "ファイルにテキストがありません。"
            }
        }
    }

    static func read(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= byteLimit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(65536, byteLimit + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= byteLimit else { throw ImportError.tooLarge }
        let text: String?
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        } else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            text = String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        } else if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
        }
        guard let text, !text.unicodeScalars.contains(where: {
            ($0.value < 0x20 && ![9, 10, 13].contains($0.value)) || (0x7F...0x9F).contains($0.value)
        }) else { throw ImportError.unsupported }
        guard text.count <= 2_000_000 else { throw ImportError.tooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.empty }
        try Task.checkCancellation()
        return text
    }
}
