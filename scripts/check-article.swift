import Foundation

@main
struct ArticleFetcherChecks {
    static func main() async throws {
        let checks = ArticleFetcherChecks()
        try checks.testOnlyWebURLsAreAccepted()
        try checks.testExtractsArticleAsMarkdownWithAbsoluteLinks()
        checks.testEmptyArticleFails()
        try checks.testDecodesHTTPAndHTMLCharsets()
        if let value = CommandLine.arguments.dropFirst().first {
            let markdown = try await ArticleFetcher.fetch(ArticleFetcher.url(from: value))
            precondition(!markdown.isEmpty)
            print("Live article fetched and converted: \(markdown.count) characters")
        }
        print("Article checks passed")
    }
    func testOnlyWebURLsAreAccepted() throws {
        let url = try ArticleFetcher.url(from: " https://example.com/article\n")
        precondition(url.host == "example.com")
        for value in ["", "example.com", "file:///tmp/article.html", "ftp://example.com", "http://example.com", "https://"] {
            expectFailure { _ = try ArticleFetcher.url(from: value) }
        }
    }

    func testExtractsArticleAsMarkdownWithAbsoluteLinks() throws {
        let paragraph = "This article explains how to translate a web page while preserving its structure. It contains enough detail to identify the main content, with several sentences about reading, language, and useful formatting."
        let html = """
        <html><head><title>Translation guide</title></head><body>
        <nav><a href="/menu">Navigation menu</a></nav>
        <article><h1>Translation guide</h1>
        <p>\(paragraph)</p><h2>Getting started</h2>
        <p>\(paragraph) <strong>Preserve formatting</strong> and <a href="../guide">read the guide</a>.</p>
        <p>\(paragraph)</p></article>
        <script>window.unwanted = 'script content';</script></body></html>
        """
        let markdown = try ArticleFetcher.markdown(html: html, baseURL: URL(string: "https://example.com/posts/article")!)
        precondition(markdown.contains("## Getting started"), markdown)
        precondition(markdown.contains("**Preserve formatting**"), markdown)
        precondition(markdown.contains("[read the guide](https://example.com/guide)"), markdown)
        precondition(!markdown.contains("Navigation menu"), markdown)
        precondition(!markdown.contains("script content"), markdown)
        precondition(!markdown.contains("<p>"), markdown)
    }

    func testEmptyArticleFails() {
        expectFailure { _ = try ArticleFetcher.markdown(html: "<html><body></body></html>",
                                                       baseURL: URL(string: "https://example.com")!) }
    }

    func testDecodesHTTPAndHTMLCharsets() throws {
        let html = "<meta charset=\"shift_jis\"><p>日本語の記事</p>"
        let data = html.data(using: .shiftJIS)!
        let httpDecoded = try ArticleFetcher.decode(data, charset: "shift_jis")
        precondition(httpDecoded == html)
        let metaDecoded = try ArticleFetcher.decode(data, charset: nil)
        precondition(metaDecoded == html)
        let utf8Decoded = try ArticleFetcher.decode(Data("日本語".utf8), charset: nil)
        precondition(utf8Decoded == "日本語")
    }
}

private func expectFailure(_ operation: () throws -> Void) {
    do { try operation() } catch { return }
    preconditionFailure("Expected an error")
}
