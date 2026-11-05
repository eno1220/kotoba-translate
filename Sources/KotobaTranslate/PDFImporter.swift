import AppKit
import PDFKit
import Vision

/// Native extraction first; only image-only pages pay the cost of local OCR.
enum PDFImporter {
    struct Result {
        let markdown: String
        let pages: Int
        let ocrPages: Int
    }

    enum ImportError: LocalizedError {
        case unreadable, locked, tooLarge, empty, render(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "PDFを開けませんでした。ファイルを確認してください。"
            case .locked: return "パスワードで保護されたPDFです。保護を解除したPDFを選んでください。"
            case .tooLarge: return "PDFが大きすぎます。200MB・1,000ページ・抽出後200万文字以内に分割してください。"
            case .empty: return "PDFから文字を抽出できませんでした。"
            case .render(let page): return "\(page)ページ目をOCR用に描画できませんでした。"
            }
        }
    }

    static func convert(_ url: URL, progress: @escaping (Int, Int) async -> Void) async throws -> Result {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200 * 1024 * 1024 else { throw ImportError.tooLarge }
        guard let document = PDFDocument(url: url) else { throw ImportError.unreadable }
        guard !document.isLocked else { throw ImportError.locked }
        guard document.pageCount <= 1000 else { throw ImportError.tooLarge }
        var pages = [String]()
        var count = 0
        var ocrPages = 0
        await progress(0, document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw ImportError.unreadable }
            let native = autoreleasepool { page.attributedString }
            let markdown: String
            if let native, native.string.contains(where: { $0.isLetter || $0.isNumber }) {
                guard native.length <= 4_000_000 else { throw ImportError.tooLarge }
                markdown = format(native, paragraphBreaks: paragraphBreaks(in: page, text: native))
            } else {
                ocrPages += 1
                markdown = try await recognize(page, number: index + 1)
            }
            try Task.checkCancellation()
            count += markdown.count
            guard count <= 2_000_000 else { throw ImportError.tooLarge }
            if !markdown.isEmpty { pages.append(markdown) }
            await progress(index + 1, document.pageCount)
        }
        guard !pages.isEmpty else { throw ImportError.empty }
        return Result(markdown: pages.joined(separator: "\n\n"), pages: document.pageCount, ocrPages: ocrPages)
    }

    private static func recognize(_ page: PDFPage, number: Int) async throws -> String {
        // About 180–220 dpi on ordinary pages; bounded memory even for large scans.
        let image: CGImage = try autoreleasepool {
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { throw ImportError.render(number) }
            let scale = min(3, 2200 / max(bounds.width, bounds.height))
            let thumbnail = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ImportError.render(number)
            }
            return image
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
        } onCancel: { request.cancel() }
        // Vision supplies reading order. Preserve line breaks rather than inventing structure.
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return format(NSAttributedString(string: text))
    }

    private static func paragraphBreaks(in page: PDFPage, text: NSAttributedString) -> Set<Int> {
        let string = text.string as NSString
        var breaks = Set<Int>()
        var previous: CGRect?
        var offset = 0
        while offset < string.length {
            let range = string.lineRange(for: NSRange(location: offset, length: 0))
            if let bounds = page.selection(for: range)?.bounds(for: page), !bounds.isEmpty {
                if let previous {
                    let height = max(previous.height, bounds.height)
                    // Extra vertical space or the start of another column.
                    if previous.minY - bounds.maxY > height * 0.65 || bounds.minY > previous.maxY {
                        breaks.insert(offset)
                    }
                }
                previous = bounds
            }
            offset = NSMaxRange(range)
        }
        return breaks
    }

    /// Conservative font-size headings and paragraph reflow; no document model required.
    static func format(_ text: NSAttributedString, paragraphBreaks: Set<Int> = []) -> String {
        let string = text.string as NSString
        var lines: [(text: String, size: CGFloat, startsParagraph: Bool)] = []
        var offset = 0
        while offset < string.length {
            let range = string.lineRange(for: NSRange(location: offset, length: 0))
            let content = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            var size: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont { size = max(size, font.pointSize) }
            }
            lines.append((content, size, paragraphBreaks.contains(offset)))
            offset = NSMaxRange(range)
        }
        // Weight by text length so a short title cannot dominate the body size.
        var sizes: [Int: Int] = [:]
        for line in lines where line.size > 0 && !line.text.isEmpty {
            sizes[Int(line.size.rounded()), default: 0] += line.text.count
        }
        let body = CGFloat(sizes.max(by: { $0.value < $1.value })?.key ?? 0)
        var blocks = [String]()
        var paragraph = ""
        func flush() {
            if !paragraph.isEmpty { blocks.append(paragraph); paragraph = "" }
        }
        for line in lines {
            if line.startsParagraph { flush() }
            let value = line.text
            if value.isEmpty { flush(); continue }
            let heading = body > 0 && line.size >= body * 1.25 && value.count <= 160
            let bullet = value.range(of: "^[•●▪◦]\\s*", options: .regularExpression)
            let list = value.range(of: "^(?:[-*+]\\s+|[0-9]+[.)]\\s+)", options: .regularExpression) != nil
            if heading {
                flush()
                blocks.append((line.size >= body * 1.7 ? "# " : "## ") + value)
            } else if let bullet {
                flush(); blocks.append("- " + value[bullet.upperBound...])
            } else if list {
                flush(); blocks.append(value)
            } else {
                if !paragraph.isEmpty {
                    // CJK wraps do not need a synthetic space.
                    let last = paragraph.unicodeScalars.last
                    let first = value.unicodeScalars.first
                    if !(last.map(isCJK) == true && first.map(isCJK) == true) { paragraph += " " }
                }
                paragraph += value
            }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x9fff).contains(scalar.value) || (0xac00...0xd7af).contains(scalar.value) ||
        (0xf900...0xfaff).contains(scalar.value) || (0x20000...0x323af).contains(scalar.value)
    }
}
