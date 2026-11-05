import Foundation
import CoreFoundation
import SwiftReadability
import HTMLToMarkdown

enum ArticleFetchError: LocalizedError {
    case invalidURL, http(Int), notHTML, tooLarge, decoding, empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "https:// で始まる記事のURLを入力してください。"
        case .http(let status): return "記事を取得できませんでした（HTTP \(status)）。"
        case .notHTML: return "HTMLの記事ページを指定してください。"
        case .tooLarge: return "ページが大きすぎます（上限5MB）。"
        case .decoding: return "ページの文字コードを読み取れませんでした。"
        case .empty: return "記事本文を抽出できませんでした。ログインやJavaScriptが必要なページには対応していません。"
        }
    }
}

enum ArticleFetcher {
    static func url(from text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { throw ArticleFetchError.invalidURL }
        return url
    }

    // Called from a detached task: HTML parsing and JavaScriptCore stay off the main actor.
    static func fetch(_ url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ArticleFetchError.notHTML }
        guard (200..<300).contains(response.statusCode) else { throw ArticleFetchError.http(response.statusCode) }
        if let mime = response.mimeType?.lowercased(), !["text/html", "application/xhtml+xml"].contains(mime) {
            throw ArticleFetchError.notHTML
        }
        let limit = 5 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw ArticleFetchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ArticleFetchError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try markdown(html: decode(data, charset: response.textEncodingName), baseURL: response.url ?? url)
    }

    static func markdown(html: String, baseURL: URL) throws -> String {
        try Task.checkCancellation()
        let article = try Readability(html: html, baseURL: baseURL).extractReadabilityData(includeComments: false)
        guard let text = article.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let content = article.content else { throw ArticleFetchError.empty }
        try Task.checkCancellation()
        let markdown = try HTMLToMarkdown().conversion(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { throw ArticleFetchError.empty }
        try Task.checkCancellation()
        return markdown
    }

    static func decode(_ data: Data, charset: String?) throws -> String {
        // Prefer the HTTP charset, then an HTML declaration, then UTF-8.
        var charsets = [charset].compactMap { $0 }
        let prefix = String(decoding: data.prefix(8192), as: UTF8.self)
        let pattern = #"(?i)<meta\b[^>]*\bcharset\s*=\s*["']?\s*([a-zA-Z0-9._-]+)"#
        if let range = prefix.range(of: pattern, options: .regularExpression),
           let charsetRange = prefix[range].range(of: #"[a-zA-Z0-9._-]+$"#, options: .regularExpression) {
            charsets.append(String(prefix[charsetRange]))
        }
        for name in charsets {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ArticleFetchError.decoding }
        return text
    }
}
