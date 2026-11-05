import AppKit
import CoreText
import PDFKit

@main
struct CheckPDF {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let styled = NSMutableAttributedString(string: "Document title\n", attributes: [.font: NSFont(name: "Helvetica", size: 24)!])
        styled.append(NSAttributedString(string: "First body line\nsecond body line.\n\n• First item\n• Second item", attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))
        let formatted = PDFImporter.format(styled)
        precondition(formatted.contains("# Document title"))
        precondition(formatted.contains("First body line second body line."))
        precondition(formatted.contains("- First item"))
        precondition(PDFImporter.format(NSAttributedString(string: "日本語の\n文章です。")) == "日本語の文章です。")

        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        context.beginPDFPage(nil)
        draw("Document title", size: 24, at: CGPoint(x: 50, y: 720), in: context)
        draw("Local PDF extraction works without a model.", size: 12, at: CGPoint(x: 50, y: 680), in: context)
        draw("Another paragraph follows after a gap.", size: 12, at: CGPoint(x: 50, y: 630), in: context)
        context.endPDFPage()
        context.closePDF()
        let nativeURL = directory.appendingPathComponent("native.pdf")
        try data.write(to: nativeURL)
        let start = Date()
        let native = try await PDFImporter.convert(nativeURL) { _, _ in }
        precondition(native.pages == 1 && native.ocrPages == 0)
        precondition(native.markdown.contains("# Document title"))
        precondition(native.markdown.contains("Local PDF extraction"))
        precondition(native.markdown.contains("\n\nAnother paragraph"))
        print("Native extraction: passed (\(String(format: "%.3f", Date().timeIntervalSince(start))) s)")

        let nativeDocument = PDFDocument(data: data as Data)!
        let page = nativeDocument.page(at: 0)!
        let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
        let scanned = PDFDocument()
        scanned.insert(PDFPage(image: image)!, at: 0)
        let scanURL = directory.appendingPathComponent("scan.pdf")
        precondition(scanned.write(to: scanURL))
        let scanStart = Date()
        let scan = try await PDFImporter.convert(scanURL) { _, _ in }
        precondition(scan.ocrPages == 1)
        precondition(scan.markdown.contains("Local PDF extraction"))
        print("Local OCR: passed (\(String(format: "%.3f", Date().timeIntervalSince(scanStart))) s)")

        let warmStart = Date()
        let warmScan = try await PDFImporter.convert(scanURL) { _, _ in }
        precondition(warmScan.markdown.contains("Local PDF extraction"))
        print("Local OCR (repeat): passed (\(String(format: "%.3f", Date().timeIntervalSince(warmStart))) s)")

        let emptyURL = directory.appendingPathComponent("empty.pdf")
        let empty = PDFDocument()
        empty.insert(PDFPage(), at: 0)
        precondition(empty.write(to: emptyURL))
        do {
            _ = try await PDFImporter.convert(emptyURL) { _, _ in }
            preconditionFailure("Empty PDF should fail")
        } catch PDFImporter.ImportError.empty { }

        let task = Task {
            try await PDFImporter.convert(nativeURL) { _, _ in }
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation should fail") }
        catch is CancellationError { }
        print("Formatting, blank PDF, cancellation: passed")
    }

    static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        context.textPosition = point
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: size)!]))
        CTLineDraw(line, context)
    }
}
